/*
 * btb.sv
 *
 * Branch target buffer: a small tagged table mapping a pc to the target of the
 * control instruction living there.
 *
 * This is the structure that makes prediction possible in fetch rather than in
 * decode. Decode-time prediction is always a cycle late: by the time a taken
 * branch is recognised, the sequential instructions behind it have already been
 * fetched and have to be thrown away, and the fetch buffer refills from empty.
 * The BTB answers the two questions fetch needs -- is this a branch, and where
 * does it go -- from the pc alone, so the next fetch address can already be the
 * target and nothing wrong path is ever fetched.
 *
 * It is written from decode, which is the first place the answers are actually
 * known. A given static branch therefore misses once, is filled, and hits from
 * then on. Direct branch and jump targets are a fixed function of the pc, so an
 * entry never goes stale and a filled entry is always right.
 *
 * jr and jalr deliberately never allocate. Their target lives in a register and
 * changes from one execution to the next, so a BTB entry would be a guess that
 * this design has no way to check in fetch; they keep taking the redirect from
 * execute exactly as before.
 *
 * FE_WIDTH read ports, because fetch probes every instruction in the line it is
 * fetching, and one write port.
 */
`include "mips_core.svh"

module btb (
	input clk,    // Clock
	input rst_n,  // Synchronous reset active low

	// ---- lookup, in fetch ----
	input  logic [`ADDR_WIDTH - 1 : 0] i_rd_pc [FE_WIDTH],
	output logic o_hit [FE_WIDTH],
	output logic o_uncond [FE_WIDTH],
	output logic [`ADDR_WIDTH - 1 : 0] o_target [FE_WIDTH],

	// ---- fill, from decode ----
	input  logic i_wr_valid,
	input  logic [`ADDR_WIDTH - 1 : 0] i_wr_pc,
	input  logic [`ADDR_WIDTH - 1 : 0] i_wr_target,
	input  logic i_wr_uncond
);

	logic [BTB_ENTRIES - 1 : 0] ent_valid;
	logic [BTB_ENTRIES - 1 : 0] ent_uncond;
	logic [BTB_TAG_W - 1 : 0] ent_tag [BTB_ENTRIES];
	logic [`ADDR_WIDTH - 1 : 0] ent_target [BTB_ENTRIES];

	// pc[1:0] is always zero, so the index starts at bit 2. The tag is the
	// remaining address folded down to BTB_TAG_W bits; the programs here live
	// in a small enough image that the fold never collides, and a collision
	// would only cost a decode redirect anyway.
	function automatic logic [BTB_IDX_W - 1 : 0] btb_index (
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return pc[BTB_IDX_W + 1 : 2];
	endfunction

	function automatic logic [BTB_TAG_W - 1 : 0] btb_tag (
		input logic [`ADDR_WIDTH - 1 : 0] pc);
		return BTB_TAG_W'(pc[`ADDR_WIDTH - 1 : BTB_IDX_W + 2]);
	endfunction

	genvar g;
	generate
		for (g = 0; g < FE_WIDTH; g++)
		begin : lookup
			logic [BTB_IDX_W - 1 : 0] rd_idx;
			assign rd_idx = btb_index(i_rd_pc[g]);

			assign o_hit[g] = ent_valid[rd_idx]
				&& (ent_tag[rd_idx] == btb_tag(i_rd_pc[g]));
			assign o_uncond[g] = ent_uncond[rd_idx];
			assign o_target[g] = ent_target[rd_idx];
		end
	endgenerate

	logic [BTB_IDX_W - 1 : 0] wr_idx;
	assign wr_idx = btb_index(i_wr_pc);

	always_ff @(posedge clk)
	begin
		if (~rst_n)
		begin
			ent_valid <= '0;
			ent_uncond <= '0;
		end
		else if (i_wr_valid)
		begin
			ent_valid[wr_idx] <= 1'b1;
			ent_uncond[wr_idx] <= i_wr_uncond;
			ent_tag[wr_idx] <= btb_tag(i_wr_pc);
			ent_target[wr_idx] <= i_wr_target;
		end
	end

endmodule
