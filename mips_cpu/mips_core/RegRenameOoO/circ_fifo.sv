module circ_fifo $(parameter int WIDTH = 6, parameter int DEPTH = 64)(
    input clk, rst_n,
    input logic wr_en, rd_en,
    input logic capacity,
    input [5:0] logic element,
    output [5:0] logic element
);



int size = 0;
int head = 0;
int tail = 0;









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



endmodule




















/*

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

*/