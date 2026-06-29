module col2im #(
  IP_WIDTH = 8,
	WT_WIDTH = 8,
	PS_WIDTH = 32,
  GRID_DIM = 8
)(
  input clk,
  input rst,
  input [IP_WIDTH-1:0] partsum [GRID_DIM-1:0]
);
  
endmodule