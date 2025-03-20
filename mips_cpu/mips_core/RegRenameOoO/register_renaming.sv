//New Stage for handling register renaming

//TODO: Separate into: Reg rename, Mispredict Recovery, Writeback, Commit, Branch Stack
//for legibility

//Change of plans, no more OoO for now, just RegRename, which means no separate stages needed

`include "mips_core.svh"

/*
interface decoder_output_ifc ();
    logic valid;
    mips_core_pkg::AluCtl alu_ctl;
    logic is_branch_jump;
    logic is_jump;
    logic is_jump_reg;
    logic [`ADDR_WIDTH - 1 : 0] branch_target;

    logic is_mem_access;
    mips_core_pkg::MemAccessType mem_action;

    logic uses_rs;
    mips_core_pkg::MipsReg rs_addr;

    logic uses_rt;
    mips_core_pkg::MipsReg rt_addr;

    logic uses_immediate;
    logic [`DATA_WIDTH - 1 : 0] immediate;

    logic uses_rw;
    mips_core_pkg::MipsReg rw_addr;

    modport in  (input valid, alu_ctl, is_branch_jump, is_jump, is_jump_reg,
        branch_target, is_mem_access, mem_action, uses_rs, rs_addr, uses_rt,
        rt_addr, uses_immediate, immediate, uses_rw, rw_addr);
    modport out (output valid, alu_ctl, is_branch_jump, is_jump, is_jump_reg,
        branch_target, is_mem_access, mem_action, uses_rs, rs_addr, uses_rt,
        rt_addr, uses_immediate, immediate, uses_rw, rw_addr);
endinterface

interface alu_pass_through_ifc ();
	logic is_branch;
	mips_core_pkg::BranchOutcome prediction;
	logic [`ADDR_WIDTH - 1 : 0] recovery_target;

	logic is_mem_access;
	mips_core_pkg::MemAccessType mem_action;
	logic [`DATA_WIDTH - 1 : 0] sw_data;

	logic uses_rw;
	mips_core_pkg::MipsReg rw_addr;

	modport in  (input is_branch, prediction, recovery_target, is_mem_access,
		mem_action, sw_data, uses_rw, rw_addr);
	modport out (output is_branch, prediction, recovery_target, is_mem_access,
		mem_action, sw_data, uses_rw, rw_addr);
endinterface

interface alu_input_ifc ();
	logic valid;
	mips_core_pkg::AluCtl alu_ctl;
	logic signed [`DATA_WIDTH - 1 : 0] op1;
	logic signed [`DATA_WIDTH - 1 : 0] op2;

	modport in  (input valid, alu_ctl, op1, op2);
	modport out (output valid, alu_ctl, op1, op2);
endinterface
*/


interface reg_ren_ifc();
    Instr_Queue_Entry_t next_instr; //next instruction
    logic instr_wr; //allow the instruction to be written into the instruction queue
    logic busy_bits [5:0];

    modport in(next_instr, instr_wr, busy_bits);
    modport out (next_instr, instr_wr, busy_bits);
endinterface

//This needs work ^^ I will need to rewrite how the register file parses these instructions
//how do I pass the decoder outputs that I need(uses_rt, etc) through?

module register_renaming (
    input clk, rst_n,
    decoder_output_ifc.in decode_in,
    hazard_control_ifc.in i_hc,
    reg_ren_ifc.out out,   //Handle with HC stall logic
    reg_ren_ifc.in in,
    branch_decoded_ifc.hazard bdc,
    branch_result_ifc.in ex_branch_result,
   // output logic [`ADDR_WIDTH - 1 : 0] branch_stack_recovery,
    input logic commit_rw
);

    //Register Renaming stuff
    parameter int NUM_ARCH_REGS = 32;
    parameter int NUM_PHYS_REGS = 64;
    parameter int INSTR_QUEUE_SIZE = 16;

    mips_core_pkg::MipsReg rw_phys;

    mips_core_pkg::MipsReg fl_in;
    mips_core_pkg::MipsReg fl_out;
    logic fl_w_en;
    logic fl_r_en;
    logic fl_rev;
    logic fl_rev_size;

    mips_core_pkg::MipsReg al_in;
    mips_core_pkg::MipsReg al_out;
    logic al_w_en;
    logic al_r_en;
    logic al_rev;
    logic al_rev_size;

    mips_core_pkg::MipsReg arch_al_in;
    mips_core_pkg::MipsReg arch_al_out;

    logic [31:0] instr_ctr;

    mips_core_pkg::MipsReg rmt [5:0];

    circ_fifo free_list(
        .clk(clk),
        .rst_n(rst_n),
        .w_en(fl_w_en),
        .r_en(fl_r_en),
        .revert(fl_rev),
        .rev_size(fl_rev_size),
        .dat_in(fl_in),
        .dat_out(fl_out)
        );

    circ_fifo #(6, 32) active_list(
        .clk(clk),
        .rst_n(rst_n),
        .w_en(al_w_en),
        .r_en(al_r_en),
        .revert(al_rev),
        .rev_size(al_rev_size),
        .dat_in(al_in),
        .dat_out(al_out)
        );

    circ_fifo #(6, 32) arch_active_list(
        .clk(clk),
        .rst_n(rst_n),
        .w_en(al_w_en),
        .r_en(al_r_en),
        .revert(al_rev),
        .rev_size(al_rev_size),
        .dat_in(arch_al_in),
        .dat_out(arch_al_out)
        );

    //reset logic
    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            //reset free list
            for(int i = 0; i < 32; i++) begin
                fl_w_en <= 1;    //does this cause a race condition for the enable and actual write?
                fl_in <= i + 32;
            end
            fl_w_en <= 0;
            //reset active list
            for(int i = 0; i < 32; i++) begin
                al_w_en <= 1;
                al_in <= i;
                arch_al_in <= i;
            end
            al_w_en <= 0;
            //reset register map table
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rmt[i] = i;
            end
            //reset instr ctr
            instr_ctr <= 0;
            //Branch Stack reset
            BS_w_ptr   <= 0;
            BS_r_ptr   <= 0;
            Branch_Stack.rmt_backup <= '{default: 0};
            Branch_Stack.busy_table_backup <= '{default: 0};
            Branch_Stack.alt_addr <= '{default: 0};
            Branch_Stack.ctr <= '{default: 0};
        end
    end

    //combinational reset logic
    always_comb begin
        if(~rst_n) begin
            //reset busy bits
            for (int i = 0; i < NUM_PHYS_REGS; i++) begin
                out.busy_bits[i] = 0;
            end
        end
    end

    //Instruction Queue Entry
    typedef struct {
        mips_core_pkg::AluCtl instruction; //alu_ctl
        mips_core_pkg::MipsReg rw_phys;
        mips_core_pkg::MipsReg rt_phys;
        mips_core_pkg::MipsReg rs_phys;
        logic valid; //same as alu?
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
        logic uses_rw;
        logic [31:0] count;
    } Instr_Queue_Entry_t;

    //instr q: Squash: set Writeback bit to 0
    //clear instr queue and clear busy bit?

    //actual register renaming
    always_ff @(posedge clk) begin
        if(rst_n && !i_hc.stall) begin
            if (decode_in.valid && decode_in.uses_rw) begin

                // Save old mapping in active list
                al_w_en <= 1;
                arch_al_in <= decode_in.rw_addr;
                al_in <= rmt[decode_in.rw_addr];

                //fetch new phys reg from free list
                fl_r_en <= 1;
                rw_phys <= fl_out;
                rmt[decode_in.rw_addr] <= fl_out;


                //TODO: for writeback: use iw pointer
                //when decoding, the decode might have r2 + r3 => r1, but the writeback pointer will
                //want r4, so you cant use the decode pointer

                //update rmt with new mapping

                out.next_instr.rw_phys <= rmt[decode_in.rw_addr];

                //TODO: NEED TO ADD LOGIC FOR CHECKING IF REGISTER IS IN USE:
                //I do this in scheeduling stage/instr queue
                //How to do this async? but set sync?

            end
            out.next_instr.instruction <= decode_in.alu_ctl;

            //TODO: do I need to move this into the if statement?
            //I need to review this
            out.next_instr.rs_phys <= rmt[decode_in.rs_addr];
            out.next_instr.rt_phys <= rmt[decode_in.rt_addr];
            //are operands ready?
            out.next_instr.ready <=
                (in.busy_bits[rmt[decode_in.rs_addr]]
                & in.busy_bits[rmt[decode_in.rt_addr]]);
            out.next_instr.valid <= decode_in.valid;
            out.next_instr.is_branch_jump <= decode_in.is_branch_jump;
            out.next_instr.is_jump <= decode_in.is_jump;
            out.next_instr.is_jump_reg <= decode_in.is_jump_reg;
            out.next_instr.is_mem_access <= decode_in.is_mem_access;
            out.next_instr.mem_action <= decode_in.mem_action;
            out.next_instr.branch_target <= decode_in.branch_target;
            out.next_instr.uses_rs <= decode_in.uses_rs;
            out.next_instr.uses_rt <= decode_in.uses_rt;
            out.next_instr.uses_rw <= decode_in.uses_rw;
            out.next_instr.uses_immediate <= decode_in.uses_immediate;
            out.next_instr.immediate <= decode_in.immediate;
            out.instr_wr <= 1;
            //instr tagged with counter
            out.next_instr.count <= instr_ctr;
            fl_r_en <= 0;
            al_w_en <= 0;
            out.instr_wr <= 0;
            instr_ctr <= instr_ctr + 1;
        end
    end

    //BUSY BIT TABLE

    //TODO: reset bits on recovery
    //TODO: reset bits on memory writeback and commit
    //TODO: commit

    //reg is busy if bit is high
    //busy bit logic
    always_comb begin
        if(rst_n) begin
            //keep them the same, idk if this is necessary
            //for (int i = 0; i < NUM_PHYS_REGS; i++) begin
            //    out.busy_bits[i] = out.busy_bits[i];
            //end
            if(decode_in.valid && decode_in.uses_rw) begin
                out.busy_bits[rw_phys] = 1;   //set busy bit to high when removed from free list
            end
        end
    end

    //Mispredict/flush handling
    always_ff @(posedge clk) begin
        if (i_hc.flush) begin
            // Reset active list
            al_rev_size <= mispredict_diff;
            al_rev <= 1;
            fl_rev_size <= mispredict_diff;
            fl_rev <= 1;
        end
        al_rev <= 0;
        fl_rev <= 0;
        //does this cause issues
    end

    //Branch Stack Entry
    typedef struct {
        mips_core_pkg::MipsReg rmt_backup [5:0];
        logic busy_table_backup [5:0];
        logic [`ADDR_WIDTH - 1 : 0] alt_addr;
        logic [31:0] ctr;
    } Branch_Stack_Entry_t;

    logic [31:0] mispredict_diff;

    Branch_Stack_Entry_t Branch_Stack [1:0];
    logic [1:0] BS_w_ptr;
    logic [1:0] BS_r_ptr;

    always_ff @(posedge clk) begin
        if (rst_n) begin
            //Branch Stack logic
            if (decode_in.is_branch ) begin
                Branch_Stack[BS_w_ptr].alt_addr <= bdc.recovery_target;
                Branch_Stack[BS_w_ptr].busy_table_backup <= in.busy_bits;
                Branch_Stack[BS_w_ptr].rmt_backup <= rmt;
                Branch_Stack[BS_w_ptr].ctr <= instr_ctr;
                BS_w_ptr <= (BS_w_ptr + 1);
            end else if (ex_branch_result.valid
            & (ex_branch_result.prediction != ex_branch_result.outcome)) begin
                rmt <= Branch_Stack[BS_r_ptr].rmt_backup;
                mispredict_diff <= instr_ctr - Branch_Stack[BS_r_ptr].ctr;
                //instr_ctr <= Branch_Stack[BS_r_ptr].ctr;
                //i am avoiding the race condition entirely by not resetting the instruction counter
                branch_stack_recovery <= Branch_Stack[BS_r_ptr].alt_addr;
                BS_w_ptr <= BS_r_ptr;
                //revert busy bits
                for(int i = 0; i < NUM_PHYS_REGS; i++) begin
                    out.busy_bits[i] = Branch_Stack[BS_r_ptr].busy_table_backup[i];
                end
            end else if(ex_branch_result.valid
            & (ex_branch_result.prediction == ex_branch_result.outcome)) begin
                BS_r_ptr <= (BS_r_ptr + 1);
            end
        end
    end


    //graduation
    always_ff @(posedge clk) begin
        if(!i_hc.flush) begin
            if(commit_rw) begin
                al_r_en <= 1;
                fl_w_en <= 1;
                fl_in <= al_out; // Move old physical register back to free list
            end
            al_r_en <= 0;
            fl_w_en <= 0;
        end
    end

    /*
        TODO: WB and Commit:
        1. Reset busy bit table
        2. commit instructions in order -> use active list as order for commit
        Other:
        1. connections for stages
        2. ROB/Instr Queue implementation and instr ordering
    */






/*      COMMIT AND MISPREDICT LOGIC TO FINISH LATER

WRITEBACK STAGE?

always_ff @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        al_r_en <= 0;
    end else if (commit_condition) begin
        // Free old physical register
        fl_w_en <= 1;
        al_r_en <= 1;
        fl_in <= al_out; // Move old physical register back to free list

    end
    al_r_en <= 0;
end

HAZARD CONTROLLER?



*/


endmodule

