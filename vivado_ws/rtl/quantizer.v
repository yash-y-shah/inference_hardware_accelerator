module quantizer #(
	parameter ACC_WIDTH = 32,
	parameter OP_WIDTH = 8,
	parameter SHIFT = 8
)(
	input signed [ACC_WIDTH-1:0] acc_result, // accumulated results
	output reg signed [OP_WIDTH-1:0] op_feature 
);
	// keep everything parameterized
	localparam signed [ACC_WIDTH-1:0] MAX_VAL = (1<<(OP_WIDTH-1))-1;
	localparam signed [ACC_WIDTH-1:0] MIN_VAL = -(1<<(OP_WIDTH-1));
	
	wire signed [ACC_WIDTH-1:0] scaled;
	assign scaled = acc_result >>> SHIFT;

	always @(*) begin
		if (scaled > MAX_VAL) op_feature = MAX_VAL;
		else if (scaled < MIN_VAL) op_feature = MIN_VAL;
		else op_feature = scaled[OP_WIDTH-1:0];
	end
endmodule