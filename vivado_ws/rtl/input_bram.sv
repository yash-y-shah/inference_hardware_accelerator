module input_bram #(
  WIDTH = 8;
  DEPTH = 784;
  SIZE = $clog2(DEPTH);
)(
  input clk,
  input rst,

  input we, // write enable, high when a valid handshake occurs.
  input w_bank_sel, //toggle bit to alternate bram storage
  input [SIZE-1:0] w_addr, // address.
  input [WIDTH-1:0] w_data, // input pixel data to be written

  input re, // read enable, high when a valid handshake occurs.
  input r_bank_sel, //toggle bit to alternate bram storage
  input reg [SIZE-1:0] r_addr, // address.
  output reg [WIDTH-1:0] r_data, // output pixel data to be read.
)
  localparam int unsigned K = WIDTH/IP_WIDTH;
  reg [WIDTH-1:0] bram0 [0:(1<<SIZE)-1];
  reg [WIDTH-1:0] bram1 [0:(1<<SIZE)-1];

  always @(posedge clk) begin
    if(rst) begin
      r_data <= 0;
    end
    else begin
      if(re) begin //read
        r_data <= (r_bank_sel) ? bram1[r_addr] : bram0[r_addr];
      end
      if(we) begin //write
        if(w_bank_sel) begin
          bram1[w_addr] <= w_data;
        end
        else begin
          bram0[w_addr] <= w_data;
        end
      end
    end
  end
endmodule