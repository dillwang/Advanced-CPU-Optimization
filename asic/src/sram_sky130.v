/*
 * sram_sky130.v
 *
 * The design's cache banks instantiate a generic `sram` with one write port
 * and one read port (see mips_core/cache_bank.sv). Under `SIMULATION that name
 * resolves to a behavioural model; for synthesis it is a black box that has to
 * land on a real macro.
 *
 * sky130A ships exactly three OpenRAM macros:
 *
 *   sky130_sram_1kbyte_1rw1r_32x256_8    32 bits x 256 words
 *   sky130_sram_2kbyte_1rw1r_32x512_8    32 bits x 512 words
 *   sky130_sram_1kbyte_1rw1r_8x1024_8     8 bits x 1024 words
 *
 * Every bank this core asks for fits inside the first one:
 *
 *   i_cache  16 data banks  32 x 128     (2 ways x 8 words, INDEX_WIDTH 7)
 *   i_cache   2 tag  banks  14 x 128
 *   d_cache  32 data banks  32 x 256     (4 ways x 8 words, INDEX_WIDTH 8)
 *   d_cache   4 tag  banks  13 x 256
 *
 * so all 54 instances map to the 32x256 macro. The 128-deep and the narrow tag
 * banks waste part of the array; there is no smaller macro to spend instead,
 * and splitting tags across a shared macro would cost a port the design does
 * not have.
 *
 * Port mapping. The macro is 1RW + 1R, the design wants 1W + 1R:
 *   - port 0 is write only, so web0 follows csb0: selecting the port at all
 *     means writing. wmask0 is all ones because banks are written whole.
 *   - port 1 is read only and always enabled, which is what cache_bank drives.
 *   - dout0 is unused. Address and data are zero extended by assignment.
 */
module sram #(
	parameter DATA_WIDTH = 32,
	parameter ADDR_WIDTH = 4
) (
	// Port 0: W
	input  wire                    clk0,
	input  wire                    csb0,	// active low chip select
	input  wire [ADDR_WIDTH-1 : 0] addr0,
	input  wire [DATA_WIDTH-1 : 0] din0,
	// Port 1: R
	input  wire                    clk1,
	input  wire                    csb1,
	input  wire [ADDR_WIDTH-1 : 0] addr1,
	output wire [DATA_WIDTH-1 : 0] dout1
);

	localparam MACRO_ADDR_WIDTH = 8;
	localparam MACRO_DATA_WIDTH = 32;

	// Plain assignment zero extends, which also keeps the equal width case
	// legal -- a zero count replication inside a concatenation does not
	// survive every Verilog-2005 frontend.
	wire [MACRO_ADDR_WIDTH-1 : 0] macro_addr0;
	wire [MACRO_ADDR_WIDTH-1 : 0] macro_addr1;
	wire [MACRO_DATA_WIDTH-1 : 0] macro_din0;
	wire [MACRO_DATA_WIDTH-1 : 0] macro_dout1;

	assign macro_addr0 = addr0;
	assign macro_addr1 = addr1;
	assign macro_din0  = din0;
	assign dout1       = macro_dout1[DATA_WIDTH-1 : 0];

	sky130_sram_1kbyte_1rw1r_32x256_8 CORE (
		.clk0   (clk0),
		.csb0   (csb0),
		.web0   (csb0),
		.wmask0 (4'hF),
		.addr0  (macro_addr0),
		.din0   (macro_din0),
		.dout0  (),

		.clk1   (clk1),
		.csb1   (csb1),
		.addr1  (macro_addr1),
		.dout1  (macro_dout1)
	);

`ifdef SRAM_WIDTH_CHECK
	initial begin
		if (ADDR_WIDTH > MACRO_ADDR_WIDTH || DATA_WIDTH > MACRO_DATA_WIDTH) begin
			$display("sram: %0dx%0d does not fit the 32x256 macro", DATA_WIDTH, 1 << ADDR_WIDTH);
			$finish;
		end
	end
`endif

endmodule
