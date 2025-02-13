//New Stage for handling register renaming

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



module register_renaming (
    input clk, rst_n,
    input decoder_output_ifc.

);


	//Register Renaming stuff
	parameter int NUM_ARCH_REGS = 32;
	parameter int NUM_PHYS_REGS = 64;
	parameter int INTR_QUEUE_SIZE = 16;

	typedef struct {
		logic size;
		logic head;
		logic capacity;
		logic tail = ((head + size) % capacity);
	} circ_fifo_t;

	logic [5:0] rmt [NUM_ARCH_REGS];

	circ_fifo_t f_list = '{32, 0, NUM_PHYS_REGS - NUM_ARCH_REGS};
	logic [5:0] free_list [NUM_PHYS_REGS - NUM_ARCH_REGS];


	//TODO: these functions dont have logic to prevent ouroboros condition

	function enqueue(input logic [5:0] element, input circ_fifo_t circ,
		 input logic [5:0] list [NUM_PHYS_REGS - NUM_ARCH_REGS])
		list[circ.tail] = element;
		circ.size++;
	endfunction

	function logic dequeue( input circ_fifo_t circ,
		 input logic [5:0] list [NUM_PHYS_REGS - NUM_ARCH_REGS])
		 logic int temp = list[circ.head];
		 circ.head = (circ.head + 1) % circ.capacity;
		 circ.size--;
		return temp;
	endfunction



	typedef struct {
		logic [31:0] instruction;
		logic [5:0] rd_phys;
		logic [5:0] rt_phys;
		logic [5:0] rs_phys;
		logic valid;
	} Instr_Queue_Entry_t;

	Instr_Queue_Entry_t instr_queue[INTR_QUEUE_SIZE];
	instr_head = 0;


	function logic [5:0] fetch_free()
		logic [5:0] new_reg = dequeue(f_list, free_list);
		return new_reg;
	endfunction

	
    //allocate new free physreg

    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            for(int i = 0, i < NUM_ARCH_REGS i++) begin
                free_list[i] = i;
            end
        end
        else begin






endmodule

