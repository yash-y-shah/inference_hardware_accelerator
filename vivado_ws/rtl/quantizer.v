module quantizer #(
	ACC_WIDTH = 32,
	OP_WIDTH = 8
)(
	input [ACC_WIDTH-1:0] acc_result, // accumulated results
	output [OP_WIDTH-1:0] op_feature 
)
	// assign op_feature = acc_result[ACC_WIDTH-1:ACC_WIDTH-OP_WIDTH]; // take the most significant bits as output feature
endmodule