// Shift register with parameterized width and depth
module shiftreg #(
  parameter IP_WIDTH = 8,
  parameter DEPTH = 8
)(
  input clk,
  input rst,
  input wr_en,
  input [IP_WIDTH-1:0] wr_data,
  output [IP_WIDTH-1:0] rd_data
);
  localparam FIFO_DEPTH = IP_WIDTH * DEPTH;
  genvar i;
  generate
    if(DEPTH ==0) begin
      assign rd_data = wr_data;
    end else begin
      reg [FIFO_DEPTH-1:0] shiftreg = '{default:0};
      always @(posedge clk) begin
        if (rst) begin
          for (int i = 0; i < DEPTH; i++) shiftreg[i*IP_WIDTH +: IP_WIDTH] <= '0;
        end else if (wr_en) begin
          shiftreg[0 +: IP_WIDTH] <= wr_data;
          for (int i = 1; i < DEPTH; i++) begin
            shiftreg[i*IP_WIDTH +: IP_WIDTH] <= shiftreg[(i-1)*IP_WIDTH +: IP_WIDTH];
          end
        end
      end
      assign rd_data = shiftreg[DEPTH*IP_WIDTH-1: (DEPTH-1)*IP_WIDTH];
    end
  endgenerate

endmodule