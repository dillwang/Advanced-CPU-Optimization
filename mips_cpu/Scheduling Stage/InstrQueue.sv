`include "RegRenameOoO/register_renaming.sv"

module InstrQueue (
    input clk, rst_n,
    reg_ren_ifc.out rr_ifc,
    hazard_control_ifc.in i_hc,

	// Pipelined interfaces
	pc_ifc.in  i_pc,
	pc_ifc.out o_pc,

	alu_input_ifc.in  i_alu_input,
	alu_input_ifc.out o_alu_input,
	alu_pass_through_ifc.in  i_alu_pass_through,
	alu_pass_through_ifc.out o_alu_pass_through,

    //Also need register read stage stuff
    //need to pass decoder information through

    output Instr_Queue_Entry_t next_instr,
    output logic[32] instr_count

);

interface IQ_ifc ();
    logic [5:0] rw_phys;
    logic [5:0] rt_phys;
    logic [5:0] rs_phys;
    logic valid;
    logic ready;
    logic is_branch_jump;
    logic is_jump;
    logic is_jump_reg;
    logic [`ADDR_WIDTH - 1 : 0] branch_target;
    logic is_mem_access;
    mips_core_pkg::MemAccessType mem_action;
    logic uses_rs;
    logic uses_rt;
    logic uses_immediate;
    logic [`DATA_WIDTH - 1 : 0] immediate;
    logic uses_rw; //uses rw
    logic [31:0] instr_count;

    modport in(rw_phys, rt_phys, rs_phys, valid, ready, is_branch_jump, is_jump, is_jump_reg,
               branch_target, is_mem_access, mem_action, uses_rs, uses_rt, uses_immediate,
               immediate, uses_rw, instr_count);
    modport out(rw_phys, rt_phys, rs_phys, valid, ready, is_branch_jump, is_jump, is_jump_reg,
               branch_target, is_mem_access, mem_action, uses_rs, uses_rt, uses_immediate,
               immediate, uses_rw, instr_count);

endinterface

//do I want to connect this to ex unit for setting valid bit?

Instr_Queue_Entry_t instr_queue[INSTR_QUEUE_SIZE];

logic valid_entry[INSTR_QUEUE_SIZE];

logic send_instr;   //false if ex stage sends stall

logic instr_head;

logic[32] count;

//figure out how to handle stalls

always_ff@(posedge clk or ~rst_n) begin
    if(~rst_n) begin
        rr_ifc.instr_wr <= 0;
        instr_head <= 0;
        count <= 0;
        for(int i = 0; i < INSTR_QUEUE_SIZE; i++) begin
            valid_entry[i] = 1; //valid entry position to put an instr in
        end
    end
    else begin
        if(rr_ifc.instr_wr) begin
            for(int i = 0; i < INSTR_QUEUE_SIZE; i++) begin
                if(valid_entry[i] == 1) begin
                    instr_queue[i] <= rr_ifc.next_instr;
                    valid_entry[i] <= 0;
                    break;
                end
            end
        end
        if(send_instr) begin
            while((instr_queue[instr_head].valid != 1) | instr_queue[instr_head].ready != 1) begin
                //if the instruction isnt valid or ready, skip instr
                instr_head <= (instr_head + 1)%INSTR_QUEUE_SIZE;
            end
            next_instr <= instr_queue[instr_head];
            instr_queue[instr_head].valid_entry <= 1;
            instr_head <= (instr_head + 1) % INSTR_QUEUE_SIZE;

        end

    end
end




endmodule
