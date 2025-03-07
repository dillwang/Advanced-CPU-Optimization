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
    cache_output_ifc.out out, // Change this output

    // Memory interface
    axi_read_address.master mem_read_address,
    axi_read_data.master mem_read_data
);

    `ifdef SIMULATION
        import "DPI-C" function void stats_event(input string e);
    `endif


    // These are not right
    localparam TAG_WIDTH = `ADDR_WIDTH - INDEX_WIDTH - BLOCK_OFFSET_WIDTH - 2;
    localparam LINE_SIZE = 1 << BLOCK_OFFSET_WIDTH;
    localparam DEPTH = 1 << INDEX_WIDTH;

    // Parsing
    logic [TAG_WIDTH - 1 : 0] sb_tag;
    
    assign {sb_tag} = i_pc_current.pc[`ADDR_WIDTH - 1 : 2];

    //databank signals
    logic [LINE_SIZE - 1 : 0] databank_we;
    logic [`DATA_WIDTH - 1 : 0] databank_wdata;
    logic [INDEX_WIDTH - 1 : 0] databank_waddr;
    logic [INDEX_WIDTH - 1 : 0] databank_raddr;
    logic [`DATA_WIDTH - 1 : 0] databank_rdata[LINE_SIZE];


    // tagbank signals
    logic tagbank_we;
    logic [TAG_WIDTH - 1 : 0] tagbank_wdata;
    logic [INDEX_WIDTH - 1 : 0] tagbank_waddr;
    logic [INDEX_WIDTH - 1 : 0] tagbank_raddr;
    logic [TAG_WIDTH - 1 : 0] tagbank_rdata;


    always_ff @(posedge clk)
    begin
        if(hit) stats_event("Stream_Buffer_hit");
        if(miss) stats_event("Stream_Buffer_miss");
    end
endmodule