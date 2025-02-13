module circ_fifo $(parameter int WIDTH = 6, parameter int DEPTH = 64)(
    input clk, rst_n,
    input w_en, r_en,
    input revert,
    input logic rev_size,
    input [WIDTH-1:0] logic dat_in,
    output [WIDTH-1:0] logic dat_out
);


reg [$clog2(DEPTH)-1 : 0] w_ptr, r_ptr;
reg [WIDTH-1:0] fifo[DEPTH];


//Reset values
always@(posedge clk) begin
    if(~rst_n) begin
        w_ptr <=0; r_ptr <= 0;
        dat_out <= 0;
    end
end

//write data to fifo
always@(posedge clk) begin
    if(w_en) begin
        fifo[w_ptr] <= dat_in;
        w_ptr <= (w_ptr + 1) % DEPTH;
    end
end


//read data from fifo

always@(posedge clk) begin
    if(r_en) begin
        dat_out <= fif0[r_ptr];
        r_ptr <= (r_ptr + 1) % DEPTH;
    end
end

always@(posedge clk) begin
    if(revert) begin
        r_ptr < abs(r_ptr - rev_size) % DEPTH;
    end
end


function logic abs(input logic num)
    if(abs < 0) return -abs;
    else begin
        return abs;
    end
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