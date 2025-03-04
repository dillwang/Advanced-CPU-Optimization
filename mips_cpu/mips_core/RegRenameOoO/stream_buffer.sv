/*
 * stream_buffer.sv
 */
`include "mips_core.svh"

module stream_buffer #(
    parameter INDEX_WIDTH = 6, // 1 KB Cahe size
    parameter BLOCK_OFFSET_WIDTH = 2
    )(
    // General signals
    input clk,    // Clock
    input rst_n,  // Synchronous reset active low

    // Request
    pc_ifc.in i_pc_current,
    pc_ifc.in i_pc_next,

    // Response
    cache_output_ifc.out out, // wrong

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);





endmodule