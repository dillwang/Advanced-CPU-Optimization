//New Stage for handling register renaming

`include "mips_core.svh"

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



interface reg_ren_ifc();
	Instr_Queue_Entry_t next_instr; //next instruction
    logic instr_wr; //allow the instruction to be written into the instruction queue
    logic busy_bits [64];

    modport in(next_instr, instr_wr, busy_bits);
    modport out (next_instr, instr_wr, busy_bits);
endinterface

//This needs work ^^ I will need to rewrite how the register file parses these instructions
//how do I pass the decoder outputs that I need(uses_rt, etc) through?

module register_renaming (
	//need input from hazard controller to revert pointers and adjust busy bit table
    input clk, rst_n,
    decoder_output_ifc.in decode_in,
    reg_ren_ifc.out out   //Handle with HC stall logic
);


//SEND EVERYTHING THROUGH DECODER OUT? THEN DO STRUCT STUFF IN INSTR QUEUE?

    //Register Renaming stuff
    parameter int NUM_ARCH_REGS = 32;
    parameter int NUM_PHYS_REGS = 64;
    parameter int INSTR_QUEUE_SIZE = 16;

    logic [5:0] rw_phys;


    logic [5:0] fl_in;
    logic [5:0] fl_out;
    logic fl_w_en;
    logic fl_r_en;
    logic fl_rev;
    logic fl_rev_size;

    logic [5:0] al_in;
    logic [5:0] al_out;
    logic al_w_en;
    logic al_r_en;
    logic al_rev;
    logic al_rev_size;

    

    logic [5:0] rmt [NUM_ARCH_REGS];
    logic [5:0] rmt_backup [NUM_ARCH_REGS];

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin //reset logic
            for (int i = 0; i < NUM_ARCH_REGS; i++) begin
                rmt[i] = i;
                rmt_backup[i] = i;
            end
        end
    end

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

    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            for(int i = 0; i < 64; i++) begin
                fl_w_en = 1;
                fl_in = i;
            end
            fl_w_en <= 0;
        end
    end

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

        always_ff @(posedge clk or negedge rst_n) begin
            if(~rst_n) begin
                for(int i = 0; i < 64; i++) begin
                    al_w_en = 1;
                    al_in = i;
                end
                al_w_en <= 0;
            end
        end



    typedef struct {
        mips_core_pkg::AluCtl instruction; //alu_ctl
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
    } Instr_Queue_Entry_t;

	//instr q: Squash: set Writeback bit to 0
	//clear instr queue and clear busy bit?
    

    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
                instr_head <= 0;
        end
        else if (decode_in.valid) begin //does this work the way I'm using it? It seems to only be
        // high if theres a memory access. How do I correctly do this?
            //fetch new phys reg from free list
            fl_r_en <= 1;
            rw_phys <= fl_out;
            busy_table[rw_phys] <= 1;   //set busy bit to high when removed from free list

            // Save old mapping in active list
            al_w_en <= 1;
            al_in <= rmt[decode_in.rw_addr];

            //update rmt with new mapping
            rmt[decode_in.rw_addr] <= rw_phys;

            //put instr in instr queue do we do this here or pass through? I think pass through to scheduling stage
            //TODO: NEED TO ADD LOGIC FOR CHECKING IF REGISTER IS IN USE
			
            //alu_ctl
			out.next_instr.instruction <= decode_in.alu_ctl;
            //rw phys address
            out.next_instr.rw_phys <= rmt[decode_in.rw_addr];
            //rs phys
            out.next_instr.rs_phys <= rmt[decode_in.rs_addr];
            //rt phys
            out.next_instr.rt_phys <= rmt[decode_in.rt_addr];
            //are operands ready?
            out.next_instr.ready <=
                !(busy_table[rmt[decode_in.rs_addr]
                & busy_table[rmt[decode_in.rt_addr]]]);
            //valid from decode
            out.next_instr.valid <= decode_in.valid;
            //is branch jump
           out.next_instr.is_branch_jump <= decode_in.is_branch_jump;
            //is jump
            out.next_instr.is_jump <= decode_in.is_jump;
            //is jump reg
            out.next_instr.is_jump_reg <= decode_in.is_jump_reg;
            //is mem access
            out.next_instr.is_mem_access <= decode_in.is_mem_access;
            //mem action
            out.next_instr.mem_action <= decode_in.mem_action;
            //branch target
            out.next_instr.branch_target <= decode_in.branch_target;
            //uses rs
            out.next_instr.uses_rs <= decode_in.uses_rs;
            //uses rt
            out.next_instr.uses_rt <= decode_in.uses_rt;
            //uses rw
            out.next_instr.uses_rw <= decode_in.uses_rw;
            //uses immediate
            out.next_instr.uses_immediate <= decode_in.uses_immediate;
            //instruction write set to high
            out.instr_wr <= 1;
        end
        fl_r_en <= 0;
        al_w_en <= 0;
        out.instr_wr <= 0;
    end

    //BUSY BIT TABLE

    logic busy_table [64];

    //reg is busy if bit is high
	//make bit high when moving to active list(?)
    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            for(int i = 0; i < 64; i++) begin
                busy_table[i] = 0;
            end
        end
        out.next_instr.busy_bits <= busy_table;
        //TODO: ADD LOGIC TO HANDLE SETTING BUSY BITS TO LOW AND TO RECOVER + COMMIT
        //TODO: ADD LOGIC FOR INHIBITING EXECUTION OF INSTRS WHOSE OPERANDS ARE BUSY
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

always_ff @(posedge clk) begin
    if (branch_mispredict) begin
        // Restore RMT from backup
        for (int i = 0; i < NUM_ARCH_REGS; i++) begin
            rmt[i] <= rmt_backup[i];
        end

        // Reset active list (rollback speculative writes)
        al_rev <= 1;
        al_rev_size <= al_head - mispredict_point;
    end
end

*/





endmodule

