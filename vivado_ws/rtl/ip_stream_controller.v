//Data format: 32-bit AXI stream (contains four 8-bit pixels).
//Stored in an Input BRAM.
module ip_stream_controller #( 
	IP_WIDTH = 8;
  DMA_WIDTH = 32;
  BRAM_ADDR_WIDTH = 10;
)(
  input clk,
  input rst,

  input tvaild, // DMA driven
  input [DMA_WIDTH-1:0] tdata, // DMA driven(32-bit).
  input tlast, // DMA driven
  output tready, //  FSM driven - tells DMA if BRAM is full.
  
  input im2col_busy, // im2Col asserts this while computing - drives tready low, preventing DMA from overwriting image being processed.
  output img_complete, // asserted when a valid handshake occurs with tlast high, indicating end of an image stream.
  
  //output bank_sel, //toggle bit to alternate bram storage
  output bram_we, // write enable, high when a valid handshake occurs.
  output reg [BRAM_ADDR_WIDTH-1:0] bram_addr, // counter value.
  output reg [DMA_WIDTH-1:0] bram_data // sliced/unpacked pixel data.
);
  localparam int unsigned K = DMA_WIDTH/IP_WIDTH;
  localparam IDLE = 2'b00, WRITE = 2'b01, WAIT = 2'b10;
  reg [1:0] state;
  reg [BRAM_ADDR_WIDTH-1:0] bram_addr_next;
  reg [DMA_WIDTH-IP_WIDTH-1:0] dma_ip_data;
  reg [$clog2(K):0] datactr; // how many pixels written to BRAM from current AXI stream word.
  
  assign tready = im2col_busy && (!reset) && (state != WRITE);

  always @(posedge clk) begin
    if(reset) begin
      state <= IDLE;
      bram_addr_next <= 0; //what should be the default value of this?
      dma_ip_data <= 0;
      bram_we <=0;
      datactr <= 0;
    end
    else begin
      case(state)
        IDLE: begin
          if(tready && tvaild) begin
          state <= WRITE;
          dma_ip_data = tdata >> IP_WIDTH; 
          bram_we <=1;
          bram_data <= tdata[IP_WIDTH-1:0]; 
          bram_addr <= bram_addr_next;
          bram_addr_next <= bram_addr + 1;
          datactr <= 1;
          end
          else begin
            state <= state;
          end
        end
        WRITE: begin
          if(datactr < K) begin
            bram_we <=1;
            bram_data <= dma_ip_data[IP_WIDTH-1:0];
            bram_addr <= bram_addr_next;
            bram_addr_next <= bram_addr + 1;
            dma_ip_data <= dma_ip_data >> IP_WIDTH;
            if(datactr == K-1) begin
              if(tlast) img_complete <= 1;
              state <= IDLE;
            end
            datactr <= datactr + 1;
          end
        end
        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

endmodule