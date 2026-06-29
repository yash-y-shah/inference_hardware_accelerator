//Data format: 32-bit AXI stream (contains four 8-bit pixels).
//Stored in an Input BRAM.
module ip_stream_controller #( 
  parameter IP_WIDTH = 8,
  parameter DMA_WIDTH = 32,
  parameter BRAM_ADDR_WIDTH = 10
)(
  input clk,
  input rst,

  input tvalid, // DMA driven
  input [DMA_WIDTH-1:0] tdata, // DMA driven(32-bit).
  input tlast, // DMA driven
  output wire tready, 
  
  input im2col_busy, // im2Col asserts this while computing - drives tready low, preventing DMA from overwriting image being processed.
  output reg img_complete, // asserted when a valid handshake occurs with tlast high, indicating end of an image stream.
  
  output wire [$clog2(DMA_WIDTH/IP_WIDTH):0] debug_datactr,
  
  //output bank_sel, //toggle bit to alternate bram storage
  output reg bram_we, // write enable, high when a valid handshake occurs.
  output reg [BRAM_ADDR_WIDTH-1:0] bram_addr, // counter value.
  output reg [IP_WIDTH-1:0] bram_data // sliced/unpacked pixel data.
);
  localparam int unsigned K = DMA_WIDTH/IP_WIDTH;
  reg [$clog2(K):0] datactr; // how many pixels written to BRAM from current AXI stream word.
  reg [DMA_WIDTH-IP_WIDTH-1:0] tdata_buffer;
  reg tlast_buffer;

  assign debug_datactr = datactr;
  assign tready = (!im2col_busy) && (datactr == 0) && (!rst); 

  always @(posedge clk) begin
    if(rst) begin
      bram_addr <= 0;
      tdata_buffer <= 0;
      bram_we <=0;
      bram_data <= 0;
      datactr <= 0;
      img_complete <= 0;
      tlast_buffer <= 0; 
    end
    else begin
      bram_we <= 0;
      img_complete <= 0;
      if(tready && tvalid) begin
        tlast_buffer <= tlast;
        tdata_buffer <= tdata[DMA_WIDTH-1:IP_WIDTH]; 
        bram_we <=1;
        bram_data <= tdata[IP_WIDTH-1:0];
        //bram_addr <= (bram_addr==0)? bram_addr : bram_addr + 1;
        datactr <= 1;
      end else if(datactr > 0) begin
        bram_we <=1;
        bram_data <= tdata_buffer[IP_WIDTH-1:0];
        //bram_addr <= bram_addr + 1;
        tdata_buffer <= tdata_buffer >> IP_WIDTH;
        if(datactr == K-1) begin
          if(tlast_buffer) img_complete <= 1;
          datactr <= 0;
        end else datactr <= datactr + 1;
      end
    end
  end
  
  // Dedicated Address Counter
    always @(posedge clk) begin
      if (rst || img_complete) begin
        bram_addr <= 0;
      end else if (bram_we) begin
        bram_addr <= bram_addr + 1;
      end
    end
endmodule