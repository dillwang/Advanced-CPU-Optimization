`include "RegRenameOoO/register_renaming.sv"

module InstrQueue (
    input clk, rst_n,
    input Instr_Queue_Entry_t next_instr,
    hazard_control_ifc.in i_hc,

	// Pipelined interfaces
	pc_ifc.in  i_pc,
	pc_ifc.out o_pc,

	alu_input_ifc.in  i_alu_input,
	alu_input_ifc.out o_alu_input,
	alu_pass_through_ifc.in  i_alu_pass_through,
	alu_pass_through_ifc.out o_alu_pass_through

);

//do I want to connect this to ex unit for setting valid bit?

Instr_Queue_Entry_t instr_queue[INSTR_QUEUE_SIZE];

logic valid_entry[INSTR_QUEUE_SIZE];

always_ff@(posedge clk or ~rst_n) begin
    if(~rst_n) begin
        for(int i = 0; i < INSTR_QUEUE_SIZE; i++) begin
            valid_entry[i] = 0;
        end
    end
    else begin
        
    end
end




endmodule
