//The point of this module is to have a counter that keeps track of which column of the matrix 
//membrane keypad we want to turn on for the particular 4 clock cycle period

module column_driver (
	input wire clk, //outside of the keyboard_top should be a pll to give you desired clk for keypad
	input wire rst,
	input wire freeze,
	output reg c_0, //column 0 (far left)
	output reg c_1, //column 1
	output reg c_2, //column 2
	output reg c_3 //column 3 (far right)
);

	//====================
	//PARAMETERS, REGISTERS
	//====================
	
	//we're going to have a register to store
	//which column we're on and use a case
	//statement to assign the individual output regs
	reg [1:0] col_ff, col_next;


	//have a counter to keep the four clock cycle logic intact
	reg [20:0] count_ff, count_next;

	//we'll assign values to these internal registers
	//with the case statement and flop it for the module outputs
	reg c_0_next, c_1_next, c_2_next, c_3_next;

	//====================
	//COMBINATIONAL BLOCK
	//====================
	always @(*) begin

		// 1. Defaults (Prevent inferred latches)
	        c_0_next  = 1'b0;
	        c_1_next  = 1'b0;
	        c_2_next  = 1'b0;
	        c_3_next  = 1'b0;
	        count_next = count_ff;
	        col_next  = col_ff;

		//reset handler
		if (rst) begin
			//if we are reset all signals are zero
			c_0_next = 1'b0;
			c_1_next = 1'b0;
			c_2_next = 1'b0;
			c_3_next = 1'b0;
			count_next = 21'd2000000;
			col_next = 2'd3;
		end else if (freeze) begin
		    count_next = count_ff;
		    col_next = col_ff;
		end else begin
			//if we are not reset then do the loop
			//keep each column on for four clocks
			if (count_ff == 21'd2000000) begin //we are at our fourth clock cycle
				count_next = 2'd0;  //start counting from 0 again
				col_next = col_ff + 2'd1; //iterate the column we're driving
			end else begin
				count_next = count_ff + 2'd1;
				//count_ff changes every clock so every clock count_next iterates
				col_next = col_ff; //keep the column driven until the counter hits 3
			end
			case (col_next)
				//depending on what value the col_next reg takes, we drive one out of the
				//four output regs for the PMOD

				2'd0: c_0_next = 1'b1;
				2'd1: c_1_next = 1'b1;
				2'd2: c_2_next = 1'b1;
				2'd3: c_3_next = 1'b1;
				default: begin
					c_0_next = 1'b0;
					c_1_next = 1'b0;
					c_2_next = 1'b0;
					c_3_next = 1'b0;
				end
			endcase
		end
	end

	//====================
	//SEQUENTIAL BLOCK
	//====================

	always @(posedge clk) begin
		c_0     <= c_0_next;
	        c_1     <= c_1_next;
	        c_2     <= c_2_next;
	        c_3     <= c_3_next;
	        count_ff <= count_next;
	        col_ff  <= col_next;	
	end

endmodule