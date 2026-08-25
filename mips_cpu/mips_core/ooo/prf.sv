/*
 * prf.sv
 *
 * The unified physical register file for the out of order back end. It replaces
 * the architectural reg_file of the in-order pipeline: there is no separate
 * architectural copy, the register map table decides which physical register
 * currently holds each architectural value.
 *
 * Reads are asynchronous so that an instruction selected by the issue queue can
 * read its operands and execute in the same cycle. Writes are synchronous, and
 * because a result written at the end of cycle N is visible to an asynchronous
 * read in cycle N + 1, dependent instructions can issue back to back with no
 * bypass network at all.
 *
 * Physical register PREG_ZERO is never allocated by the free list and is never
 * written, so it reads as a constant zero for every unused operand.
 */
`include "mips_core.svh"

module prf #(
	parameter int READ_PORTS = 2 * ISSUE_WIDTH,
	parameter int WRITE_PORTS = ISSUE_WIDTH + 1
	)(
	input clk,

	// Asynchronous read ports
	input  preg_t r_addr [READ_PORTS],
	output logic [`DATA_WIDTH - 1 : 0] r_data [READ_PORTS],

	// Synchronous write ports
	input  logic  w_en   [WRITE_PORTS],
	input  preg_t w_addr [WRITE_PORTS],
	input  logic [`DATA_WIDTH - 1 : 0] w_data [WRITE_PORTS]
);

	logic [`DATA_WIDTH - 1 : 0] regs [PHYS_REGS];

	always_comb
	begin
		for (int i = 0; i < READ_PORTS; i++)
			r_data[i] = (r_addr[i] == PREG_ZERO) ? '0 : regs[r_addr[i]];
	end

	always_ff @(posedge clk)
	begin
		for (int i = 0; i < WRITE_PORTS; i++)
		begin
			// PREG_ZERO must stay zero. Instructions whose destination is
			// architectural register zero rename to it and are dropped here.
			if (w_en[i] && (w_addr[i] != PREG_ZERO))
				regs[w_addr[i]] <= w_data[i];
		end
	end

endmodule
