//the main function of this module is to find out which button was pressed
//on the keypad

//the point of this module is to check the row pins (5, 6, 7, 8) 
//to see if any voltage is detected on the row

//the column_driver drives the columns one at a time. if the user presses
//a particular button, that pushes down the row copper line onto the column copper
//line, acting as an electrical bridge. 

//if that happens, we know which column we are currently driving, and which row
//we detect a new signal from. If we know the column and row, we know which button
//was pressed. 

//simultaneous input from the user (pressing multiple buttons at the same time)
//doesn't make sense for our application, so we're moving forward with the
//assumption that the user only presses one button at a time. Otherwise, valid trigger goes low 
//if no button is pressed valid trigger goes low


module row_reader(
	input wire clk,
	input wire rst,

	input wire row_0, //wire 8 on the keypad
	input wire row_1, //wire 7 on the keypad
	input wire row_2, //wire 6 on the keypad
	input wire row_3, //wire 5 on the keypad

	input wire c_0_ff,
	input wire c_1_ff,
	input wire c_2_ff,
	input wire c_3_ff,
	//we need to read the flop outputs from the column_driver
	//module to determine which column is currently being driven


	output reg [3:0] button_ff,
	//16 buttons, so 4 bits
	//we neeed a decoder down the line to
	//convert this number to the actual button value
	//with a keypad map

	output reg button_valid_ff,
	//used to determine whether or not the button output is useful/valid

	//the two button related outputs are ff because they both should 
	//be clean and synchronous.
	//during the clock cycle, the module makes a decion: whether a button
	//was pressed and if so what button

	//At the end of the cycle, it needs to present the decision
	//made on a silver platter

	output reg freeze_out

);

	//================================
	//REGISTERS, PARAMETERS, AND WIRES
	//================================

	reg [3:0] button_next; //signal to be flopped to the output
	reg	  button_valid_next;

	wire [3:0] rows;
	assign rows = {row_0, row_1, row_2, row_3};
	//all this does is bundle the four input row wires
	//into a four bit wire bus.
	//this helps us make our case statement in the comb logic


	wire [3:0] columns;
	assign columns = {c_0_ff, c_1_ff, c_2_ff, c_3_ff};
	//same thing for the columns. Make a bundle 

	//=====================
	//COMBINATIONAL BLOCK
	//=====================

	always @(*) begin
		//defaults to prevent inferred latches

		button_next = button_ff; //this could be anything since the valid trigger is off by default
		button_valid_next = 1'b0; //turn the valid trigger off if you're confused

		if (rst) begin //reset handler
			button_next = 4'b0;
			button_valid_next = 1'b0; //not valid if under reset
		end else begin //if we're not under reset...
			
			freeze_out = row_0 | row_1 | row_2 | row_3;
			
			//check the rows with a case statement
			case (rows)

			//the valid trigger is set high for all valid row and col possibilities

			//valid row possibilities represent one button being pressed
			//invalid row possibilities (no button press or multiple
			//button presses) are taken care of in the default case in the first
			//case layer

			//valid col possibilities only one column is driven high, which
			//based on our working column_driver module should always be the case.
			//just in case though, our defaults in the second case layer for the
			//column checking takes care of that by setting the valid trigger low

				4'b1000: begin //the first row is high
					button_valid_next = 1'b1;
					case (columns) //check the columns
						4'b1000: button_next = 4'h1; //first column
						4'b0100: button_next = 4'h2; //second column
						4'b0010: button_next = 4'h3; //third column
						4'b0001: button_next = 4'hA; //fourth column
						default: button_valid_next = 1'b0; //invalid
					endcase
				end

				4'b0100: begin //the second row is high
					button_valid_next = 1'b1;
					case (columns) //check the columns
						4'b1000: button_next = 4'h4; //first column
						4'b0100: button_next = 4'h5; //second column
						4'b0010: button_next = 4'h6; //third column
						4'b0001: button_next = 4'hB; //fourth column
						default: button_valid_next = 1'b0; //invalid
					endcase
				end

				4'b0010: begin //the third row is high
					button_valid_next = 1'b1;
					case (columns) //check the columns
						4'b1000: button_next = 4'h7; //first column
						4'b0100: button_next = 4'h8; //second column
						4'b0010: button_next = 4'h9; //third column
						4'b0001: button_next = 4'hC; //fourth column
						default: button_valid_next = 1'b0; //invalid
					endcase
				end

				4'b0001: begin //the fourth row is high
					button_valid_next = 1'b1;
					case (columns) //check the columns
						4'b1000: button_next = 4'hE; //first column E = *
						4'b0100: button_next = 4'h0; //second column
						4'b0010: button_next = 4'hF; //third column F = #
						4'b0001: button_next = 4'hD; //fourth column
						default: button_valid_next = 1'b0; //invalid
					endcase
				end

				default: button_valid_next = 1'b0;

			endcase

		end		

	end


	//=====================
	//SEQUENTIAL BLOCK
	//=====================

	always @(posedge clk) begin
		button_ff <= button_next;
		button_valid_ff <= button_valid_next;
	end


endmodule