module accum #(
  parameter PS_WIDTH = 32,
  parameter DEPTH = 8,
  parameter IP_WIDTH = 8,
  parameter VECTOR_DEPTH = $clog2(8),
  parameter BRAM_SIZE = $clog2(784)
)(
  input clk,
  input rst,

  //from deskwere
  input ip_valid,
  input [(PS_WIDTH * (1 << VECTOR_DEPTH))-1:0] ip_partsum,

  //from topmodule
  input wire is_first_pass, 
  input wire is_last_pass,  
  input wire start_new_image, // Resets the address counter

  // for input_bram module
  output we, // write enable
  output bram_bank_sel, //toggle bit to alternate bram storage
  output reg [BRAM_SIZE-1:0] w_addr, // address
  output reg [PS_WIDTH-1:0] w_data, // pixel data to be written
  output re, // read enable, high when a valid handshake occurs.
  output r_bank_sel, //toggle bit to alternate bram storage
  output reg [BRAM_SIZE-1:0] r_addr, // address.
  input [PS_WIDTH-1:0] r_data // output pixel data to be read.

  output op_valid,
  output reg [(PS_WIDTH * (1 << VECTOR_DEPTH))-1:0] op_accum //accumulated output

)
  localparam VECTOR_SIZE = 1<<VECTOR_DEPTH;
  localparam TOTAL_WIDTH = PS_WIDTH * VECTOR_SIZE;
  reg [BRAM_SIZE-1:0] counter;
  
  // shiftreg pipeline
  logic [TOTAL_WIDTH-1:0] psum_delay_1, psum_delay_2;
  logic valid_delay_1, valid_delay_2;
  logic first_pass_delay_1, first_pass_delay_2;
  logic last_pass_delay_1, last_pass_delay_2;
  logic [BRAM_SIZE-1:0] addr_delay_1, addr_delay_2;
  always_ff @(posedge clk) begin
    if (rst) begin
        valid_delay_1 <= 0; valid_delay_2 <= 0;
    end else begin
        // shift stage 1
        valid_delay_1      <= ip_valid;
        psum_delay_1       <= ip_partsum;
        first_pass_delay_1 <= is_first_pass;
        last_pass_delay_1  <= is_last_pass;
        addr_delay_1       <= counter; // Keep track of where this data goes
        // shift stage 2
        valid_delay_2      <= valid_delay_1;
        psum_delay_2       <= psum_delay_1;
        first_pass_delay_2 <= first_pass_delay_1;
        last_pass_delay_2  <= last_pass_delay_1;
        addr_delay_2       <= addr_delay_1;
    end
  end
  
  always @(posedge clk) begin
    if (rst) begin
      counter <= 0;
      re <= 0;
      r_addr <= 0;
    end else begin
      if (start_new_image) begin
          counter <= 0;
      end
      
      if (ip_valid) begin
        re <= 1;
        r_addr <= counter;
        counter <= counter + 1;
      end else begin
        re <= 0;
      end
    end
  end

  // parallel vector addition and write back stage
  logic [TOTAL_WIDTH-1:0] computed_accum;
  always @(*) begin
    for (int i = 0; i < VECTOR_SIZE; i = i + 1) begin
      if (first_pass_delay_2) begin
        computed_accum[i*PS_WIDTH +: PS_WIDTH] = psum_delay_2[i*PS_WIDTH +: PS_WIDTH];
      end else begin
        // slice arrays dynamically
        computed_accum[i*PS_WIDTH +: PS_WIDTH] = 
            r_data[i*PS_WIDTH +: PS_WIDTH] + psum_delay_2[i*PS_WIDTH +: PS_WIDTH];
      end
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      we <= 0;
      w_addr <= 0;
      w_data <= 0;
      op_valid <= 0;
      op_accum <= 0;
    end else begin
      if (valid_delay_2) begin
        we <= 1;
        w_addr <= addr_delay_2;
        w_data <= computed_accum;

        // If this is the final pass, forward the completed convolution to Bias/ReLU
        if (last_pass_delay_2) begin
            op_valid <= 1;
            op_accum <= computed_accum;
        end else begin
            op_valid <= 0;
        end
      end else begin
        we <= 0;
        op_valid <= 0;
      end
    end
  end
endmodule