`include "shiftreg.sv"
    
module skewer #(
  parameter IP_WIDTH = 8,
  parameter VECTOR_DEPTH = $clog2(8)
)(
  input clk,
  input rst,
  input ip_valid, // vector is ready to input
  input wire [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] ip_vector,
  output wire [(1 << VECTOR_DEPTH)-1:0] op_valid,
  output reg [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] op_vector
);
  //local variables
  localparam VECTOR_SIZE = 1<<VECTOR_DEPTH;

  //initialize 8 sr
  genvar i;
  generate
    for (i = 0; i < VECTOR_SIZE; i = i + 1) begin
      // fifo module
      shiftreg #(
        .IP_WIDTH(IP_WIDTH),
        .DEPTH(i)
      ) shift_reg_inst (
        .clk(clk),
        .rst(rst),
        .wr_en(1'b1), // shift only when input vector is valid
        .wr_data(ip_valid ? ip_vector[i*IP_WIDTH +: IP_WIDTH] : {IP_WIDTH{1'b0}}), // write data from input vector
        .rd_data(op_vector[i*IP_WIDTH +: IP_WIDTH]) // read data to output vector
      );

      shiftreg #(
        .IP_WIDTH(1),
        .DEPTH(i)
      ) op_valid_inst (
        .clk(clk),
        .rst(rst),
        .wr_en(1'b1),
        .wr_data(ip_valid),
        .rd_data(op_valid[i])
      );
    end
  endgenerate

  
endmodule