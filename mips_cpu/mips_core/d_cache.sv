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
    parameter INDEX_WIDTH = 8,  // 4 ways x 256 sets x 4 words = 16 KB
    parameter BLOCK_OFFSET_WIDTH = 2,
    parameter ASSOCIATIVITY = 4,
    // Prefetch degree: how far ahead of the detected stride to fetch.
    parameter PREFETCH_DEGREE = 1,
    // Set to 1 to build the stride prefetcher in. It is off by default because
    // it was measured to be worth nothing on these benchmarks: 0.09% on
    // quickSort and 245 cycles on esift2 even at 8 KB, where capacity pressure
    // is at its worst, and 13 issued prefetches across the whole of coin. The
    // logic is correct and stays here so the ablation reproduces.
    parameter ENABLE_PREFETCH = 0
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Asserted by the load/store queue when it is not setting up an access
    // this cycle. The prefetcher borrows the tag array to probe with, so it
    // may only do so when no demand access needs it.
    input logic i_pf_allow,

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
    localparam WAY_W = $clog2(ASSOCIATIVITY);
    localparam LINE_BYTES = LINE_SIZE * 4;

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
        STATE_REFILL_DATA,      // Loads a cache line from memory
        STATE_PF_PROBE          // Looking up a prefetch candidate in the tags
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

    logic [WAY_W - 1 : 0] select_way;
    logic [WAY_W - 1 : 0] r_select_way;
    // True LRU. lru_age holds a permutation of 0..ASSOCIATIVITY-1 per set: 0 is
    // most recently used and ASSOCIATIVITY-1 is the victim. The single bit per
    // set that the two-way version used is only correct for two ways.
    logic [WAY_W - 1 : 0] lru_age [ASSOCIATIVITY][DEPTH];

    // ---- prefetcher ----
    // Stride is detected on the miss stream rather than per load PC, which
    // needs no extra plumbing and still tracks an array walk: successive misses
    // of a strided traversal are a constant distance apart.
    logic [`ADDR_WIDTH - 1 : 0] pf_last_miss;
    logic signed [`ADDR_WIDTH : 0] pf_last_delta;
    logic pf_seen_miss;
    logic pf_stride_ok;

    logic pf_req;                               // a candidate is waiting
    logic [TAG_WIDTH - 1 : 0] pf_tag;
    logic [INDEX_WIDTH - 1 : 0] pf_index;
    logic is_prefetch;                          // current refill is a prefetch

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

    logic [WAY_W - 1 : 0] hit_way;
    logic [WAY_W - 1 : 0] victim_way;

    always_comb
    begin
        tag_hit = 1'b0;
        hit_way = '0;
        for (int w = 0; w < ASSOCIATIVITY; w++)
        begin
            if ((i_tag == tagbank_rdata[w]) && valid_bits[w][i_index])
            begin
                tag_hit = 1'b1;
                hit_way = WAY_W'(w);
            end
        end

        // An invalid way is always the best victim; otherwise take the way the
        // recency permutation marks as oldest.
        victim_way = '0;
        begin
            automatic logic found_invalid = 1'b0;
            for (int w = ASSOCIATIVITY - 1; w >= 0; w--)
            begin
                if (!valid_bits[w][i_index])
                begin
                    found_invalid = 1'b1;
                    victim_way = WAY_W'(w);
                end
            end
            if (!found_invalid)
            begin
                for (int w = 0; w < ASSOCIATIVITY; w++)
                begin
                    if (lru_age[w][i_index] == WAY_W'(ASSOCIATIVITY - 1))
                        victim_way = WAY_W'(w);
                end
            end
        end

        hit = in.valid & tag_hit & (state == STATE_READY);
        miss = in.valid & ~hit;
        last_flush_word = databank_select[LINE_SIZE - 1] & mem_write_data.WVALID;
        last_refill_word = databank_select[LINE_SIZE - 1] & mem_read_data.RVALID;

        if (hit)
            select_way = hit_way;
        else if (miss)
            select_way = victim_way;
        else
            select_way = '0;
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
        else if (state == STATE_PF_PROBE)
        begin
            databank_wdata = in.data;
            databank_waddr = i_index;
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
        for (int w = 0; w < ASSOCIATIVITY; w++)
            tagbank_we[w] = 1'b0;
        tagbank_we[r_select_way] = last_refill_word;
        tagbank_wdata = r_tag;
        tagbank_waddr = r_index;
        // While idle the tag array is lent to the prefetcher so it can find out
        // whether its candidate line is already cached. It is handed straight
        // back in the probe cycle, so a demand access loses at most one cycle.
        if ((state == STATE_READY) && pf_probe_start)
            tagbank_raddr = pf_index;
        else
            tagbank_raddr = i_index_next;
    end

    always_comb
    begin
        out.valid = hit;
        out.data = databank_rdata[select_way][i_block_offset];
    end

    // A prefetch may only borrow the tag array when the load/store queue says
    // it is not setting an access up, and only when one is actually waiting.
    logic pf_probe_start;
    assign pf_probe_start = (ENABLE_PREFETCH != 0) & pf_req & i_pf_allow & ~in.valid;

    // Evaluated in STATE_PF_PROBE, against the tags read during STATE_READY.
    logic pf_present;
    logic [WAY_W - 1 : 0] pf_victim;
    logic pf_victim_dirty;

    always_comb
    begin
        pf_present = 1'b0;
        for (int w = 0; w < ASSOCIATIVITY; w++)
        begin
            if ((pf_tag == tagbank_rdata[w]) && valid_bits[w][pf_index])
                pf_present = 1'b1;
        end

        pf_victim = '0;
        begin
            automatic logic found_invalid = 1'b0;
            for (int w = ASSOCIATIVITY - 1; w >= 0; w--)
            begin
                if (!valid_bits[w][pf_index])
                begin
                    found_invalid = 1'b1;
                    pf_victim = WAY_W'(w);
                end
            end
            if (!found_invalid)
            begin
                for (int w = 0; w < ASSOCIATIVITY; w++)
                begin
                    if (lru_age[w][pf_index] == WAY_W'(ASSOCIATIVITY - 1))
                        pf_victim = WAY_W'(w);
                end
            end
        end
        pf_victim_dirty = valid_bits[pf_victim][pf_index]
            & dirty_bits[pf_victim][pf_index];
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
                else if (pf_probe_start)
                    next_state = STATE_PF_PROBE;

            STATE_PF_PROBE:
                // Take the candidate only if it is absent and would not evict a
                // dirty line. Writing back on behalf of a guess is not worth a
                // second memory transaction.
                if (!pf_present && !pf_victim_dirty)
                    next_state = STATE_REFILL_REQUEST;
                else
                    next_state = STATE_READY;

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

            default: ;
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
    `ifdef SIMULATION
        always_ff @(posedge clk)
        begin
            if(hit) stats_event("D-Cache_hit");
            if(miss) stats_event("D-Cache_miss");
            if(in.valid) stats_event("D-Cache_access");
        end
    `endif
    always_ff @(posedge clk)
    begin
        if(~rst_n)
        begin
            state <= STATE_READY;
            databank_select <= 1;
            for (int i=0; i<ASSOCIATIVITY;i++)
                valid_bits[i] <= '0;
            // Blocking: large arrays, and nothing else writes them on this edge.
            // Seeding with the identity gives a valid starting permutation.
            for (int w = 0; w < ASSOCIATIVITY; w++)
                for (int i = 0; i < DEPTH; i++)
                    lru_age[w][i] = WAY_W'(w);
            pf_req <= 1'b0;
            is_prefetch <= 1'b0;
            pf_seen_miss <= 1'b0;
            pf_stride_ok <= 1'b0;
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
                        is_prefetch <= 1'b0;

                        // ---- stride detection on the miss stream ----
                        begin
                            automatic logic signed [`ADDR_WIDTH : 0] delta =
                                $signed({1'b0, in.addr}) - $signed({1'b0, pf_last_miss});
                            automatic logic use_stride = pf_seen_miss && pf_stride_ok
                                && (delta == pf_last_delta) && (delta != 0);
                            automatic logic [`ADDR_WIDTH - 1 : 0] target =
                                use_stride
                                ? (in.addr + delta[`ADDR_WIDTH - 1 : 0])
                                : (in.addr + `ADDR_WIDTH'(LINE_BYTES));

                            pf_stride_ok <= pf_seen_miss && (delta == pf_last_delta) && (delta != 0);
                            pf_last_delta <= delta;
                            pf_last_miss <= in.addr;
                            pf_seen_miss <= 1'b1;

                            // Only worth chasing if it lands on a different line.
                            if (target[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2]
                                != in.addr[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2])
                            begin
                                pf_req <= 1'b1;
                                {pf_tag, pf_index} <=
                                    target[`ADDR_WIDTH - 1 : BLOCK_OFFSET_WIDTH + 2];
                            end
                        end
                    end
                    else if (hit && (in.mem_action == WRITE))
                        dirty_bits[select_way][i_index] <= 1'b1;

                    // Promote the accessed way to most recently used.
                    if (in.valid)
                    begin
                        for (int w = 0; w < ASSOCIATIVITY; w++)
                        begin
                            if (lru_age[w][i_index] < lru_age[select_way][i_index])
                                lru_age[w][i_index] <= lru_age[w][i_index] + WAY_W'(1);
                        end
                        lru_age[select_way][i_index] <= '0;
                    end
                end

                STATE_PF_PROBE:
                begin
                    // The candidate is consumed either way: taken, or dropped
                    // because it is already cached or would evict dirty data.
                    pf_req <= 1'b0;
                    if (!pf_present && !pf_victim_dirty)
                    begin
                        r_tag <= pf_tag;
                        r_index <= pf_index;
                        r_select_way <= pf_victim;
                        is_prefetch <= 1'b1;
                    `ifdef SIMULATION
                        stats_event("D-Prefetch_issued");
                    `endif
                    end
                `ifdef SIMULATION
                    else if (pf_present) stats_event("D-Prefetch_already_cached");
                    else stats_event("D-Prefetch_dropped_dirty");
                `endif
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
                        is_prefetch <= 1'b0;
                        // A prefetched line is inserted as least recently used
                        // rather than most: it is a guess, and inserting it at
                        // MRU would let a wrong guess evict live data.
                        if (is_prefetch)
                        begin
                            for (int w = 0; w < ASSOCIATIVITY; w++)
                            begin
                                if (lru_age[w][r_index] > lru_age[r_select_way][r_index])
                                    lru_age[w][r_index] <= lru_age[w][r_index] - WAY_W'(1);
                            end
                            lru_age[r_select_way][r_index] <= WAY_W'(ASSOCIATIVITY - 1);
                        end
                    end
                end
            endcase
        end
    end
endmodule
