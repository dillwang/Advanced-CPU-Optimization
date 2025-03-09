/*
 * stream_buffer.sv
 */
`include "mips_core.svh"

module stream_buffer #(
    parameter DEPTH = 8 //
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    //sb_hit
    output sb_hit,


    // Request
    pc_ifc.in sb_pc_current,
    pc_ifc.in sb_pc_next,

    // Response
    cache_output_ifc.out out, // Change this output

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);

    `ifdef SIMULATION
        import "DPI-C" function void stats_event(input string e);
    `endif

    localparam TAG_WIDTH = `ADDR_WIDTH - 2;

    // Parsing
    logic [TAG_WIDTH - 1 : 0] sb_tag;
    logic [TAG_WIDTH - 1 : 0] sb_next_tag;

    // Head and Tail for FIFO
    logic [$clog2(DEPTH)-1] head_ptr;
    logic [$clog2(DEPTH)-1] tail_ptr;
    logic full, empty;

    assign empty = (head == tail);
    assign full  = ((tail + 1) % 8 == head);
    

    assign sb_tag = sb_pc_current.pc[`ADDR_WIDTH - 1 : 2];
    assign sb_next_tag = sb_pc_next.pc[`ADDR_WIDTH - 1 : 2];


    // States
    enum logic[1:0] {
        STATE_READY,            // Ready for incoming requests
        STATE_PREFETCH_REQUEST,   // Sending out a memory read request
        STATE_FILL_DATA       // Missing on a read
    } state, next_state;


    //databank signals
    logic [DEPTH - 1 : 0] databank_we;
    logic [`DATA_WIDTH - 1 : 0] databank_wdata;
    logic [DEPTH - 1 : 0] databank_waddr;
    logic [DEPTH - 1 : 0] databank_raddr;
    logic [`DATA_WIDTH - 1 : 0] databank_rdata;

    genvar g,w;
    generate
        for (g=0, g < DEPTH; g++)
        begin : databanks
            cache_bank #(
                .DATA_WIDTH (`DATA_WIDTH),
                .ADDR_WIDTH (DEPTH)
            ) databank (
                .clk,
                .i_we (databank_we[g]),
                .i_wdata(databank_wdata),
                .i_waddr(databank_waddr),
                .i_raddr(databank_raddr),
                .o_rdata(databank_rdata)
            );
        end
    endgenerate

    // tagbank signals
    logic tagbank_we;
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [DEPTH - 1 : 0] tagbank_waddr;
    logic [DEPTH - 1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata;

    generate
        for (w=0, w < DEPTH; w++)
        begin : databanks
            cache_bank #(
                .DATA_WIDTH (`TAG_WIDTH),
                .ADDR_WIDTH (DEPTH)
            ) databank (
                .clk,
                .i_we (tagbank_we[w]),
                .i_wdata(tagbank_wdata),
                .i_waddr(tagbank_waddr),
                .i_raddr(tagbank_raddr),
                .o_rdata(tagbank_rdata)
            );
        end
    endgenerate

    always_comb
    begin
        tag_hit = (sb_tag == tagbank_rdata[head_ptr]);
        hit = tag_hit & (state == STATE_READY);
        miss = ~hit;

        //last_refill_word = databank_select[LINE_SIZE - 1] & mem_read_data.RVALID;

        if (hit)
        begin
            out = databank_rdata[head_ptr];
            sb_hit = 1;
        end
        else if (miss)
        begin
            sb_hit = 0;
        end
        else
        begin

        end
    end

    always_comb
    begin
        mem_read_address.ARADDR = {r_tag, r_index,
            {BLOCK_OFFSET_WIDTH + 2{1'b0}}};
        mem_read_address.ARLEN = LINE_SIZE;
        mem_read_address.ARVALID = state == STATE_PREFETCH_REQUEST;
        mem_read_address.ARID = 4'd0;

        // Always ready to consume data
        mem_read_data.RREADY = 1'b1;
    end

    always_comb
    begin
        next_state = state;
        unique case (state)
            STATE_READY:
                if (miss)
                    next_state = STATE_PREFETCH_REQUEST;
            STATE_PREFETCH_REQUEST:
                if (mem_read_address.ARREADY)
                    next_state = STATE_FILL_DATA;
            STATE_FILL_DATA:
                if (last_refill_word)
                    next_state = STATE_READY;
        endcase
    end


    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            state <= STATE_READY;
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
                STATE_PREFETCH_REQUEST:
                begin
                end
                STATE_FILL_DATA:
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
            endcase
        end
    end


    always_ff @(posedge clk)
    begin
        if(hit) stats_event("Stream_Buffer_hit");
        if(miss) stats_event("Stream_Buffer_miss");
    end
endmodule