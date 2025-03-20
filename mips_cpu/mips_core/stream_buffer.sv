/*
 * stream_buffer.sv
 * Auther: Diyou Wang
 * This is a next-line Hardware Prefetching Stream Buffer.
 */
`include "mips_core.svh"

module stream_buffer #(
    parameter DEPTH = 8,
    parameter BLOCK_OFFSET_WIDTH = 2
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    pc_ifc.in sb_pc_current,
    pc_ifc.in sb_pc_next,

    // Response
    sb_ifc.out out,

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);

    `ifdef SIMULATION
        import "DPI-C" function void stats_event(input string e);
    `endif

    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
    localparam TAG_WIDTH = `ADDR_WIDTH - BLOCK_OFFSET_WIDTH - 2;

    // Extract tag bits from the current and next PC.
    // (In i_cache, the PC is split as {tag, index, block_offset}; here we only need the tag.)
    logic [TAG_WIDTH - 1 : 0] sb_tag;
    logic [TAG_WIDTH -1 :0] sb_next_tag;
    logic [BLOCK_OFFSET_WIDTH - 1 : 0] sb_block_offset;
    
    assign {sb_tag, sb_block_offset} = sb_pc_current.pc[`ADDR_WIDTH - 1 : 2];
    assign {sb_next_tag} = sb_pc_next.pc[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2];

    // Head and Tail for FIFO
    logic [$clog2(DEPTH)-1 : 0] head_ptr;
    logic [$clog2(DEPTH)-1 : 0] tail_ptr;
    logic full, empty;

    logic out_valid;

    assign empty = (head_ptr == tail_ptr);
    assign full  = (tail_ptr + 1 == head_ptr);

    // Tag definition
    logic [TAG_WIDTH - 1 : 0] r_tag; // tag of for refilling
    logic [1:0] hit_count; // cout 3 times after getting a hit

    // States
    enum logic[1:0] {
        STATE_READY,            // Ready for incoming requests
        STATE_PREFETCH_REQUEST,   // Sending out a memory read request
        STATE_FILL_DATA,       // Missing on a read
        STATE_WAIT
    } state, next_state;


    //databank signals
    logic [LINE_SIZE - 1 : 0] databank_select;
    logic [LINE_SIZE - 1 :0 ] databank_we;
    logic [`DATA_WIDTH - 1 : 0] databank_wdata;
    logic [$clog2(DEPTH)-1 : 0] databank_waddr;
    logic [$clog2(DEPTH)-1 : 0] databank_raddr;
    logic [`DATA_WIDTH - 1 : 0] databank_rdata[LINE_SIZE];
    
    genvar g;
    generate
        for (g = 0; g < LINE_SIZE; g++) begin : databanks
            cache_bank #(
                .DATA_WIDTH (`DATA_WIDTH),
                .ADDR_WIDTH ($clog2(DEPTH))
            ) databank (
                .clk,
                .i_we (databank_we[g]),
                .i_wdata(databank_wdata),
                .i_waddr(databank_waddr),
                .i_raddr(databank_raddr),
                .o_rdata(databank_rdata[g])
            );
        end
    endgenerate

    // tagbank signals
    logic tagbank_we;
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [$clog2(DEPTH)-1 : 0] tagbank_waddr;
    logic [$clog2(DEPTH)-1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata;

    cache_bank #(
        .DATA_WIDTH (TAG_WIDTH),
        .ADDR_WIDTH ($clog2(DEPTH))
    ) tagbank (
        .clk,
        .i_we (tagbank_we),
        .i_wdata(tagbank_wdata),
        .i_waddr(tagbank_waddr),
        .i_raddr(tagbank_raddr),
        .o_rdata(tagbank_rdata)
    );

    logic last_refill_word;

    logic [DEPTH - 1 : 0] valid_bits;

    // Intermediate signals
    logic hit, miss, tag_hit;

    logic tag_reserve;

    logic r_tag_hit;

    // Define tag hits
    always_comb
    begin
        tag_hit = (sb_tag == tagbank_rdata) & valid_bits[head_ptr]; //& valid_bits[head_ptr]
        r_tag_hit = (sb_tag == r_tag) & (state == STATE_FILL_DATA || state == STATE_PREFETCH_REQUEST);
        tag_reserve = (sb_tag == tagbank_rdata);
        hit = tag_hit & (state == STATE_READY);
        miss = ~hit;
        last_refill_word = databank_select[4-1] & mem_read_data.RVALID;
    end

    //Wiring memory logics
    always_comb
    begin
        mem_read_address.ARADDR = {r_tag, {BLOCK_OFFSET_WIDTH+2{1'b0}}};
        mem_read_address.ARLEN = 4;
        mem_read_address.ARVALID = state == STATE_PREFETCH_REQUEST;
        mem_read_address.ARID = 4'd2;
        // Always ready to consume data
        mem_read_data.RREADY = 1'b1;
    end

    //Wiring Data Bank Signals
    always_comb
    begin
        if (mem_read_data.RVALID)
			databank_we = databank_select;
		else
			databank_we = '0;

        databank_wdata = mem_read_data.RDATA;
		databank_waddr = tail_ptr; //Check this(Timing)
		//databank_raddr = (head_ptr+1)%DEPTH;
        // if (state == STATE_FILL_DATA && mem_read_data.RVALID)
        //     databank_we = databank_select; // Only during refill

        // // Write the incoming data to all banks; only the one with enabled write will store it.
        // for (int i = 0; i < LINE_SIZE; i++) begin
        //     databank_wdata[i] = mem_read_data.RDATA;
        // end
        if (sb_block_offset == 3)
                databank_raddr = head_ptr+1;
            else
                databank_raddr = head_ptr;
    end

    //Wiring Tag Bank Signals
    always_comb
    begin
        tagbank_we = last_refill_word;
		tagbank_wdata = r_tag;
		tagbank_waddr = tail_ptr;
        if (sb_block_offset == 3)
            tagbank_raddr = head_ptr+1;
        else
		    tagbank_raddr = head_ptr;
    end

    //Wiring output data
    always_comb
    begin
        out.valid = out_valid;
        out.sb_hit = hit;
        out.data = databank_rdata[sb_block_offset];
        //out.valid = 0;
        //out.sb_hit = 0;
        // for (int i = 0; i < LINE_SIZE; i = i + 1) begin
        //     out.data[i] = databank_rdata[i];
        // end
        
    end

    // Finite State Machine transition
    always_comb
    begin
        next_state = state;
        unique case (state)
            STATE_READY:
                if (sb_block_offset == 3)
                    next_state = STATE_PREFETCH_REQUEST;
            STATE_PREFETCH_REQUEST:
                if (mem_read_address.ARREADY)
                    next_state = STATE_FILL_DATA;
            STATE_FILL_DATA:
                if (last_refill_word)
                    next_state = STATE_READY;
            STATE_WAIT:
                if (!full)
                    next_state = STATE_READY;
        endcase
    end

    // What happens in each stage
    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            state <= STATE_READY;
            head_ptr <= 0;
            tail_ptr <= 0;
            databank_select <= 1;
            for (int i=0; i<DEPTH; i++)
                valid_bits[i] <= '0;
        end
        else
        begin
            state <= next_state;

            case (state)
                STATE_READY:
                begin
                    if (miss)
                    begin
                        tail_ptr <= 0 ;
                        head_ptr <= 0 ;
                        r_tag <= sb_next_tag;
                        databank_select <= 1;
                        for (int i=0; i<DEPTH; i++)
                            valid_bits[i] <= '0;
                    end
                    else if (hit)
                    begin
                        if (sb_block_offset == 3) begin
                            r_tag <= r_tag + 1;
                            head_ptr <= head_ptr + 1;
                            valid_bits[head_ptr] <= 0;
                        end
                        else begin
                            r_tag <= r_tag;
                        end
                    end
                    else
                    begin
                    end
                end
                STATE_PREFETCH_REQUEST:
                begin
                end
                STATE_FILL_DATA:
                begin
                    if (mem_read_data.RVALID) begin
                        // Shift the one-hot databank_select to indicate progress in the burst.
                        databank_select <= {databank_select[4-2:0],
                                            databank_select[4-1]};
                    end
                    if (last_refill_word)
                    begin;
                        //Update Tail pointer
                        tail_ptr <= tail_ptr + 1;
                        valid_bits[tail_ptr] <= 1'b1;
                    end
                end
                STATE_WAIT:
                begin
                end
            endcase
        end
    end


    always_ff @(posedge clk)
    begin
        if(tag_hit) stats_event("Stream_Buffer_tag_hit");
        if(r_tag_hit) stats_event("R_tag_hit");
    end

    // `ifdef SIMULATION
    //     always_ff @(posedge clk)
    //     begin
    //         $display("tag reserve is %x", tag_reserve);
    //         if(hit) begin
    //             $display("Stream buffer hits data is %x for pc = %x", databank_rdata[sb_block_offset], sb_pc_current.pc);
    //             $display("Blockoffset is %x", sb_block_offset);
    //         end
    //     end
    // `endif
endmodule
