/*
 * d_cache.sv
 * Author: Zinsser Zhang
 * Revision : Sankara           
 * Last Revision: 04/04/2023
 *
 * This is a 2-way set associative data cache. Line size and depth (number of lines) are
 * set via INDEX_WIDTH and BLOCK_OFFSET_WIDTH parameters. Notice that line size
 * means number of words (each consist of 32 bit) in a line. Because all
 * addresses in mips_core are 26 byte addresses, so the sum of TAG_WIDTH,
 * INDEX_WIDTH and BLOCK_OFFSET_WIDTH is `ADDR_WIDTH - 2.
 * The ASSOCIATIVITY is fixed at 2 because of the replacement policy. The replacement
 * policy also needs changes when changing the ASSOCIATIVITY
 *
 * Typical line sizes are from 2 words to 8 words. The memory interfaces only
 * support up to 8 words line size.
 *
 * Because we need a hit latency of 1 cycle, we need an asynchronous read port,
 * i.e. data is ready during the same cycle when address is calculated. However,
 * SRAMs only support synchronous read, i.e. data is ready the cycle after the
 * address is calculated. Due to this conflict, we need to read from the banks
 * on the clock edge at the beginning of the cycle. As a result, we need both
 * the registered version of address and a non-registered version of address
 * (which will effectively be registered in SRAM).
 *
 * See wiki page "Synchronous Caches" for details.
 */
`include "mips_core.svh"

interface d_cache_input_ifc ();
    logic valid;
    mips_core_pkg::MemAccessType mem_action;
    logic [`ADDR_WIDTH - 1 : 0] addr;
    logic [`ADDR_WIDTH - 1 : 0] addr_next;
    logic [`DATA_WIDTH - 1 : 0] data;

    modport in  (input valid, mem_action, addr, addr_next, data);
    modport out (output valid, mem_action, addr, addr_next, data);
endinterface

module d_cache #(
    parameter INDEX_WIDTH = 6,  // 2 * 1 KB Cache Size
    parameter BLOCK_OFFSET_WIDTH = 2,
    parameter ASSOCIATIVITY = 4
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low



    // Request
    d_cache_input_ifc.in in,

    // Response
    cache_output_ifc.out out,

    // AXI interfaces
    axi_write_address.master mem_write_address,
    axi_write_data.master mem_write_data,
    axi_write_response.master mem_write_response,
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);
    //code for counting stats
    `ifdef SIMULATION
        import "DPI-C" function void stats_event(input string e);
    `endif

    localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
    localparam DEPTH = 1 << INDEX_WIDTH;

    // Check if the parameters are set correctly
    generate
        if(TAG_WIDTH <= 0 || LINE_SIZE > 16)
        begin
            INVALID_D_CACHE_PARAM invalid_d_cache_param ();
        end
    endgenerate

    // Parsing
    logic [TAG_WIDTH - 1 : 0] i_tag;
    logic [INDEX_WIDTH - 1 : 0] i_index;
    logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

    logic [INDEX_WIDTH - 1 : 0] i_index_next;

    assign {i_tag, i_index, i_block_offset} = in.addr[`ADDR_WIDTH - 1 : 2];
    assign i_index_next = in.addr_next[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
    // Above line uses +: slice, a feature of SystemVerilog
    // See https://stackoverflow.com/questions/18067571

    // States
    enum logic [2:0] {
        STATE_READY,            // Ready for incoming requests
        STATE_FLUSH_REQUEST,    // Sending out memory write request
        STATE_FLUSH_DATA,       // Writes out a dirty cache line
        STATE_REFILL_REQUEST,   // Sending out memory read request
        STATE_REFILL_DATA       // Loads a cache line from memory
    } state, next_state;
    logic pending_write_response;

    // Registers for flushing and refilling
    logic [INDEX_WIDTH - 1:0] r_index;
    logic [TAG_WIDTH - 1:0] r_tag;

    // databank signals
    logic [LINE_SIZE - 1 : 0] databank_select;
    logic [LINE_SIZE - 1 : 0] databank_we[ASSOCIATIVITY];
    logic [`DATA_WIDTH - 1 : 0] databank_wdata;
    logic [INDEX_WIDTH - 1 : 0] databank_waddr;
    logic [INDEX_WIDTH - 1 : 0] databank_raddr;
    logic [`DATA_WIDTH - 1 : 0] databank_rdata [ASSOCIATIVITY][LINE_SIZE];

    logic select_way;
    logic r_select_way;
    logic [DEPTH - 1 : 0] lru_rp;

    // databanks
    genvar g,w;
    generate
        for (g = 0; g < LINE_SIZE; g++)
        begin : datasets
            for (w=0; w< ASSOCIATIVITY; w++)
            begin : databanks
                cache_bank #(
                    .DATA_WIDTH (`DATA_WIDTH),
                    .ADDR_WIDTH (INDEX_WIDTH)
                ) databank (
                    .clk,
                    .i_we (databank_we[w][g]),
                    .i_wdata(databank_wdata),
                    .i_waddr(databank_waddr),
                    .i_raddr(databank_raddr),

                    .o_rdata(databank_rdata[w][g])
                );
            end
        end
    endgenerate

    // tagbank signals
    logic tagbank_we[ASSOCIATIVITY];
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
    logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata[ASSOCIATIVITY];

    generate
        for (w=0; w< ASSOCIATIVITY; w++)
        begin: tagbanks
            cache_bank #(
                .DATA_WIDTH (TAG_WIDTH),
                .ADDR_WIDTH (INDEX_WIDTH)
            ) tagbank (
                .clk,
                .i_we    (tagbank_we[w]),
                .i_wdata (tagbank_wdata),
                .i_waddr (tagbank_waddr),
                .i_raddr (tagbank_raddr),

                .o_rdata (tagbank_rdata[w])
            );
        end
    endgenerate

    // Valid bits
    logic [DEPTH - 1 : 0] valid_bits[ASSOCIATIVITY];
    // Dirty bits
    logic [DEPTH - 1 : 0] dirty_bits[ASSOCIATIVITY];

    // Shift registers for flushing
    logic [`DATA_WIDTH - 1 : 0] shift_rdata[LINE_SIZE];

    // Intermediate signals
    logic hit, miss, tag_hit;
    logic last_flush_word;
    logic last_refill_word;

    always_comb
    begin
        tag_hit = ( ((i_tag == tagbank_rdata[0]) & valid_bits[0][i_index])
                  | ((i_tag == tagbank_rdata[1]) & valid_bits[1][i_index]));
        hit = in.valid
            & (tag_hit)
            & (state == STATE_READY);
        miss = in.valid & ~hit;
        last_flush_word = databank_select[LINE_SIZE - 1] & mem_write_data.WVALID;
        last_refill_word = databank_select[LINE_SIZE - 1] & mem_read_data.RVALID;

        if (hit)
        begin
            if (i_tag == tagbank_rdata[0])
            begin
                select_way = 'b0;
            end
            else
            begin
                select_way = 'b1;
            end
        end
        else if (miss)
        begin
            select_way = lru_rp[i_index];
        end
        else
        begin
            select_way = 'b0;
        end

    end

    always_comb
    begin
        mem_write_address.AWVALID = state == STATE_FLUSH_REQUEST;
        mem_write_address.AWID = 0;
        mem_write_address.AWLEN = LINE_SIZE;
        mem_write_address.AWADDR = {tagbank_rdata[r_select_way], i_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_write_data.WVALID = state == STATE_FLUSH_DATA;
        mem_write_data.WID = 0;
        mem_write_data.WDATA = shift_rdata[0];
        mem_write_data.WLAST = last_flush_word;

        // Always ready to consume write response
        mem_write_response.BREADY = 1'b1;
    end

    always_comb begin
        mem_read_address.ARADDR = {r_tag, r_index, {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_read_address.ARLEN = LINE_SIZE;
        mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
        mem_read_address.ARID = 4'd1;

        // Always ready to consume data
        mem_read_data.RREADY = 1'b1;
    end

    always_comb
    begin
        for (int i=0; i<ASSOCIATIVITY;i++)
            databank_we[i] = '0;
        if (mem_read_data.RVALID)               // We are refilling data
            databank_we[r_select_way] = databank_select;
        else if (hit & (in.mem_action == WRITE))    // We are storing a word
            databank_we[select_way][i_block_offset] = 1'b1;
    end

    always_comb
    begin
        if (state == STATE_READY)
        begin
            databank_wdata = in.data;
            databank_waddr = i_index;
            if (next_state == STATE_FLUSH_REQUEST)
                databank_raddr = i_index;
            else
                databank_raddr = i_index_next;
        end
        else
        begin
            databank_wdata = mem_read_data.RDATA;
            databank_waddr = r_index;
            if (next_state == STATE_READY)
                databank_raddr = i_index_next;
            else
                databank_raddr = r_index;
        end
    end

    always_comb
    begin
        tagbank_we[r_select_way] = last_refill_word;
        tagbank_we[~r_select_way] = '0;
        tagbank_wdata = r_tag;
        tagbank_waddr = r_index;
        tagbank_raddr = i_index_next;
    end

    always_comb
    begin
        out.valid = hit;
        out.data = databank_rdata[select_way][i_block_offset];
    end

    always_comb
    begin
        next_state = state;
        unique case (state)
            STATE_READY:
                if (miss)
                    if (valid_bits[select_way][i_index] & dirty_bits[select_way][i_index])
                        next_state = STATE_FLUSH_REQUEST;
                    else
                        next_state = STATE_REFILL_REQUEST;

            STATE_FLUSH_REQUEST:
                if (mem_write_address.AWREADY)
                    next_state = STATE_FLUSH_DATA;

            STATE_FLUSH_DATA:
                if (last_flush_word && mem_write_data.WREADY)
                    next_state = STATE_REFILL_REQUEST;

            STATE_REFILL_REQUEST:
                if (mem_read_address.ARREADY)
                    next_state = STATE_REFILL_DATA;

            STATE_REFILL_DATA:
                if (last_refill_word)
                    next_state = STATE_READY;
        endcase
    end

    always_ff @(posedge clk) begin
        if (~rst_n)
            pending_write_response <= 1'b0;
        else if (mem_write_address.AWVALID && mem_write_address.AWREADY)
            pending_write_response <= 1'b1;
        else if (mem_write_response.BVALID && mem_write_response.BREADY)
            pending_write_response <= 1'b0;
    end

    always_ff @(posedge clk)
    begin
        if (state == STATE_FLUSH_DATA && mem_write_data.WREADY)
            for (int i = 0; i < LINE_SIZE - 1; i++)
                shift_rdata[i] <= shift_rdata[i+1];

        if (state == STATE_FLUSH_REQUEST && next_state == STATE_FLUSH_DATA)
            for (int i = 0; i < LINE_SIZE; i++)
                shift_rdata[i] <= databank_rdata[r_select_way][i];
    end



    //HIT AND MISS COUNTERS
    always_ff @(posedge clk)
    begin
        if(hit) stats_event("D-Cache_hit");
        if(miss) stats_event("D-Cache_miss");
        if(in.valid) stats_event("D-Cache_access");
    end

    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            state <= STATE_READY;
            databank_select <= 1;
            for (int i=0; i<ASSOCIATIVITY;i++)
                valid_bits[i] <= '0;
            for (int i=0; i<DEPTH;i++)
                lru_rp[i] <= 0;
        end
        else
        begin
            state <= next_state;

            case (state)
                STATE_READY:
                begin
                    if (miss)
                    begin
                        r_tag <= i_tag;
                        r_index <= i_index;
                        r_select_way <= select_way;
                    end
                    else if (in.mem_action == WRITE)
                        dirty_bits[select_way][i_index] <= 1'b1;
                    if (in.valid)
                    begin
                        lru_rp[i_index] <= ~select_way;
                    end
                end

                STATE_FLUSH_DATA:
                begin
                    if (mem_write_data.WREADY)
                        databank_select <= {databank_select[LINE_SIZE - 2 : 0],
                            databank_select[LINE_SIZE - 1]};
                end

                STATE_REFILL_DATA:
                begin
                    if (mem_read_data.RVALID)
                        databank_select <= {databank_select[LINE_SIZE - 2 : 0],
                            databank_select[LINE_SIZE - 1]};

                    if (last_refill_word)
                    begin
                        valid_bits[r_select_way][r_index] <= 1'b1;
                        dirty_bits[r_select_way][r_index] <= 1'b0;
                    end
                end
            endcase
        end
    end
endmodule
