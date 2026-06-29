// BRAM FIFO

module fifo1 #(
  parameter IP_WIDTH = 32,
  parameter DEPTH = 16
)(
  input clk,
  input rst,
  input wr_en,
  input [IP_WIDTH-1:0] wr_data,
  output rd_en,
  output [IP_WIDTH-1:0] rd_data
);

endmodule