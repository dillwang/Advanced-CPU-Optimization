/*
 * reg_file.sv
 * Author: Zinsser Zhang
 * Last Revision: 04/09/2018
 *
 * A 32-bit wide, 32-word deep register file with two asynchronous read port
 * and one synchronous write port.
 *
 * Register file needs to output '0 if uses_r* signal is low. In this case,
 * either reg zero is requested for read or the register is unused.
 *
 * See wiki page "Branch and Jump" for details.
 */
`include "mips_core.svh"

interface reg_file_output_ifc ();
	logic [`DATA_WIDTH - 1 : 0] rs_data;
	logic [`DATA_WIDTH - 1 : 0] rt_data;

	modport in  (input rs_data, rt_data);
	modport out (output rs_data, rt_data);
endinterface

module reg_file (
	input clk,    // Clock

	// Input from decoder
	decoder_output_ifc.in i_decoded,

	// Input from write back stage
	write_back_ifc.in i_wb,

	// Output data
	reg_file_output_ifc.out out
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

	logic [`DATA_WIDTH - 1 : 0] rmt [NUM_ARCH_REGS];

	circ_fifo_t f_list = '{32, 0, NUM_PHYS_REGS - NUM_ARCH_REGS};
	logic [5:0] free_list [NUM_PHYS_REGS - NUM_ARCH_REGS];

	circ_fifo_t a_list = '{64, 0, NUM_PHYS_REGS};
	logic [5 : 0] active_list [NUM_PHYS_REGS];


	//TODO: these functions dont have logic to prevent ouroboros condition

	function void enqueue(input logic [5:0] element, input circ_fifo_t circ,
		 input logic [5:0] list [NUM_PHYS_REGS - NUM_ARCH_REGS])
		list[circ.tail] = element;
		circ.tail = (circ.tail + 1) % circ.capacity;
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

	//TODO: I need to adjust logic to make the reg fetched from free list be the one assigned for rename and then the old one gets added to 

    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            for(int i = 0, i < NUM_ARCH_REGS,  i++) begin
                free_list[i] = i;
            end
        end
        else begin
			if(decoder_output_ifc.isvalid) begin
				//TODO: phys_rd = fetch_free()
				//TODO: put arch_rd data in phys rd
				//TODO: enqueue(phys_rd, a_list)
		
		end
	end


	logic [`DATA_WIDTH - 1 : 0] regs [32];

	assign out.rs_data = i_decoded.uses_rs ? regs[i_decoded.rs_addr] : '0;
	assign out.rt_data = i_decoded.uses_rt ? regs[i_decoded.rt_addr] : '0;

	always_ff @(posedge clk) begin
		if(i_wb.uses_rw)
		begin
			regs[i_wb.rw_addr] = i_wb.rw_data;
		end
	end



endmodule
