module relu #(
	parameter WIDTH = 8
)(
	input wire signed [WIDTH-1:0] ip,
	output wire signed [WIDTH-1:0] op
);
	assign op = ip[WIDTH-1]? 0 : ip; //if sign bit 1, output 0, else output = input
endmodule