/*
 * i_cache.sv
 * Author: Zinsser Zhang 
 * Revision : Sankara           
 * Last Revision: 04/04/2023
 *
 * This is a direct-mapped instruction cache. Line size and depth (number of
 * lines) are set via INDEX_WIDTH and BLOCK_OFFSET_WIDTH parameters. Notice that
 * line size means number of words (each consist of 32 bit) in a line. Because
 * all addresses in mips_core are 26 byte addresses, so the sum of TAG_WIDTH,
 * INDEX_WIDTH and BLOCK_OFFSET_WIDTH is `ADDR_WIDTH - 2.
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

module i_cache #(
    parameter INDEX_WIDTH = 6, // 1 KB Cahe size
    parameter BLOCK_OFFSET_WIDTH = 2,
    parameter ASSOCIATIVITY = 2
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    pc_ifc.in i_pc_current,
    pc_ifc.in i_pc_next,

    // Response
    cache_output_ifc.out out,

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data,

    //sb_ifc
    sb_ifc.in sb_in
);

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
            INVALID_I_CACHE_PARAM invalid_i_cache_param ();
        end
    endgenerate

    // Parsing
    logic [TAG_WIDTH - 1 : 0] i_tag;
    logic [INDEX_WIDTH - 1 : 0] i_index;
    logic [BLOCK_OFFSET_WIDTH - 1 : 0] i_block_offset;

    logic [INDEX_WIDTH - 1 : 0] i_index_next;

    assign {i_tag, i_index, i_block_offset} = i_pc_current.pc[`ADDR_WIDTH - 1 : 2];
    assign i_index_next = i_pc_next.pc[BLOCK_OFFSET_WIDTH + 2 +: INDEX_WIDTH];
    // Above line uses +: slice, a feature of SystemVerilog
    // See https://stackoverflow.com/questions/18067571

    // States
    enum logic[1:0] {
        STATE_READY,            // Ready for incoming requests
        STATE_REFILL_REQUEST,   // Sending out a memory read request
        STATE_REFILL_DATA       // Missing on a read
    } state, next_state;

    // Registers for refilling
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

    // Intermediate signals
    logic hit, miss, tag_hit;
    logic last_refill_word;


    always_comb
    begin
        tag_hit = ( ((i_tag == tagbank_rdata[0]) & valid_bits[0][i_index])
                  | ((i_tag == tagbank_rdata[1]) & valid_bits[1][i_index]));
        hit = (tag_hit) & (state == STATE_READY);
        miss = ~hit;
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
        // Modify here for stream buffer
        else if (sb_in.sb_hit)
        begin
            select_way = 1'b0;
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
        mem_read_address.ARADDR = {r_tag, r_index,
            {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_read_address.ARLEN = LINE_SIZE;
        mem_read_address.ARVALID = state == STATE_REFILL_REQUEST;
        mem_read_address.ARID = 4'd0;

        // Always ready to consume data
        mem_read_data.RREADY = 1'b1;
    end


    always_comb
    begin
        for (int i=0; i<ASSOCIATIVITY;i++)
            databank_we[i] = '0;
        if (state == STATE_REFILL_DATA && mem_read_data.RVALID) begin
            databank_we[r_select_way] = databank_select; // Only during refill

            databank_wdata = mem_read_data.RDATA;
        end
        else if (state == STATE_STREAM_REFILL && sb_in.valid) begin
            databank_we[r_select_way] = {LINE_SIZE{1'b1}};
            databank_wdata = sb_in.data;
        end
        else begin
            databank_wdata = mem_read_data.RDATA;
        end

        databank_waddr = r_index;
        if (next_state == STATE_READY)
                databank_raddr = i_index_next;
            else
                databank_raddr = r_index;
    end

    always_comb
    begin
        for (int i = 0; i < ASSOCIATIVITY; i++)
            tagbank_we[i] = 1'b0;

        if (last_refill_word)
            tagbank_we[r_select_way] = 1'b1;
    
        tagbank_wdata = r_tag;
        tagbank_waddr = r_index;
        tagbank_raddr = i_index_next;
    end

    always_comb
    begin
        out.valid = (hit || sb_in.sb_hit);
        if (sb_in.sb_hit)
            out.data = sb_in.data;
        else
            out.data = databank_rdata[select_way][i_block_offset];
    end

    always_comb
    begin
        next_state = state;
        unique case (state)
            STATE_READY:
                if (miss && !sb_in.valid)
                    next_state = STATE_REFILL_REQUEST;
                else if (miss && sb_in.valid)
                    next_state = STATE_STREAM_REFILL;
            STATE_REFILL_REQUEST:
                if (mem_read_address.ARREADY)
                    next_state = STATE_REFILL_DATA;
            STATE_REFILL_DATA:
                if (last_refill_word)
                    next_state = STATE_READY;
            STATE_STREAM_REFILL:
                next_state = STATE_READY;
        endcase
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
                end
                STATE_REFILL_REQUEST:
                begin
                end
                STATE_REFILL_DATA:
                begin
                    if (mem_read_data.RVALID)
                        databank_select <= {databank_select[LINE_SIZE - 2 : 0],
                            databank_select[LINE_SIZE - 1]};

                    if (last_refill_word)
                    begin
                        valid_bits[r_select_way][r_index] <= 1'b1;
                        valid_bits[~r_select_way][r_index] <= valid_bits[~r_select_way][r_index]; // Retain the other way's valid bit
                    end
                end
                STATE_STREAM_REFILL: begin
                    // Here we use stream buffer data to update the cache banks.
                    // In this example, we assume the stream buffer delivers a full line.
                    // The write-enable for all words is already asserted in combinational logic.
                    // You may need additional logic if your cache_bank instances require separate data handling.
                    valid_bits[r_select_way][r_index] <= 1'b1;
                    valid_bits[~r_select_way][r_index] <= valid_bits[~r_select_way][r_index]; // Retain the other way's valid bit
                end
            endcase
        end
    end

    always_ff @(posedge clk)
    begin
        if (~rst_n)
        begin
            for (int i=0; i<DEPTH; i++)
                lru_rp[i] <= 0; // Initialize LRU bit
        end
        else
        begin
            case (state)
                STATE_READY:
                begin
                    if (hit)
                    begin
                        lru_rp[i_index] <= (select_way == 1'b0) ? 1'b1 : 1'b0; // Mark recently used way
                    end
                    else if (miss)
                    begin
                        lru_rp[i_index] <= r_select_way; // Store the replaced way as recently used
                    end
                end
            endcase
        end
    end


    always_ff @(posedge clk)
    begin
        if(hit) stats_event("I-Cache_hit");
        if(miss) stats_event("I-Cache_miss");
    end
endmodule
