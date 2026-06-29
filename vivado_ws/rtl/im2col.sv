//Reads from Input BRAM using sliding window address pointers.
//Writes flattened vectors to the Skewing FIFOs.
//Bandwidth constraint: Must output one 8-element vector per 8 clock cycles to keep the array fed.

module im2col #( 
  parameter IP_WIDTH = 8,
  parameter WT_WIDTH = 8,
  parameter KERNEL_SIZE = 3,
  parameter ROW = 28,
  parameter COL = 28,
  parameter PADDING = 1,
  parameter STRIDE = 1,
  parameter OP_ROW = (ROW + 2 * PADDING - KERNEL_SIZE)/STRIDE +1,
  parameter OP_COL = (COL + 2 * PADDING - KERNEL_SIZE)/STRIDE +1,
  parameter GRID_DIM = $clog2(8),
  parameter VECTOR_DEPTH = $clog2(8),
  parameter BRAM_SIZE = $clog2(ROW*COL) 
)(
  input wire clk,
  input wire rst,

  // tiling control inputs
  input wire [$clog2(KERNEL_SIZE)-1:0] k_row_start, // row of the kernel to start fetching
  input wire [$clog2(KERNEL_SIZE)-1:0] k_col_start, // col of the kernel to start fetching
  input wire [VECTOR_DEPTH:0] pass_length,          // no of elements to fetch
	
  input wire start, // indicating a new image is loaded and ready
  input wire [$clog2(OP_ROW)-1:0] start_row_idx, // start row address
  input wire [$clog2(OP_COL)-1:0] start_col_idx, // start column address
  input wire [$clog2(OP_ROW)-1:0] end_row_idx,   // end row address
  input wire [$clog2(OP_COL)-1:0] end_col_idx,   // end column address
  input wire [KERNEL_SIZE*KERNEL_SIZE-1:0] window_select, // indicates weights present in array  
  input wire img_bank, // bram bank containing img
  output reg done, // high when entire portion has been sent

  output reg bram_re, // read enable for bram
  output reg bank_sel, //toggle bit to alternate bram storage
  output reg [BRAM_SIZE-1:0] r_addr, // address
  input [IP_WIDTH-1:0] r_data, // pixel data to be read from bram (1 cycle latecny)

  input wire [GRID_DIM-1:0] fifo_ready, // from fifo
  output reg op_valid, // vector is ready 
  output reg [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] op_vector

);
  // local variables
  localparam K = KERNEL_SIZE * KERNEL_SIZE;
  localparam integer JUMP_NEXT_KERNEL_ROW = COL - KERNEL_SIZE + 1;
  localparam integer JUMP_NEXT_WINDOW_ROW = COL * STRIDE;
  
  // dynamic padding calculation based on the current pass length
  wire [$clog2(1<<VECTOR_DEPTH):0] pad_words = (1 << VECTOR_DEPTH) - pass_length;

  reg [VECTOR_DEPTH-1:0] vec_ctr;       // vector counter
  reg [$clog2(K)-1:0] win_ctr;          // window counter (0 to K-1)
  reg [$clog2(KERNEL_SIZE)-1:0] win_row_ctr, win_col_ctr; // position within kernel
  
  reg [$clog2(ROW)-1:0] row_idx;
  reg [$clog2(COL)-1:0] col_idx;
  reg [$clog2(OP_ROW)-1:0] op_row_idx;
  reg [$clog2(OP_COL)-1:0] op_col_idx;
  
  // pipeline stage 1 (follows the bram request)
  reg valid_p1;
  reg zero_inj_p1;
  reg [$clog2(K)-1:0] win_ctr_p1;

  // pipeline stage 2 (aligns with r_data arrival)
  reg valid_p2;
  reg zero_inj_p2;
  reg [$clog2(K)-1:0] win_ctr_p2;

  // nested signed counters
  reg signed [$clog2(ROW*COL)+1:0] row_base_addr;
  reg signed [$clog2(ROW*COL)+1:0] win_base_addr;
  reg signed [$clog2(ROW*COL)+1:0] curr_addr;

  logic pad_region_next; // padding region
  logic inc_kernel_next; // kernel is to be included
  logic zero_inj_next; // inject zero in the vector
  reg zero_inj; // current zero injection register
  
  wire [$clog2(K)-1:0] global_k_idx = (win_row_ctr * KERNEL_SIZE) + win_col_ctr;
  assign inc_kernel_next = window_select[global_k_idx]; 
  assign zero_inj_next = pad_region_next || !inc_kernel_next;
  
  reg [1:0] state;
  localparam IDLE = 2'b00, PROCESS = 2'b01, DONE = 2'b10, UNUSED_STATE = 2'b11; 

  // intermediate integers for address calculation
  integer init_row, init_col;
  assign init_row = (start_row_idx * STRIDE) - PADDING;
  assign init_col = (start_col_idx * STRIDE) - PADDING;
  
  wire signed [$clog2(ROW*COL)+1:0] initial_addr = (init_row * COL) + init_col;
  
  integer k_row_int, k_col_int;
  assign k_row_int = k_row_start;
  assign k_col_int = k_col_start;
  wire signed [$clog2(ROW*COL)+1:0] k_offset = (k_row_int * COL) + k_col_int;
                                 
  // pure unsigned integer math to prevent underflow logic truncation
  integer current_padded_row_abs;
  integer current_padded_col_abs;
                                 
  always @(*) begin
    if(state == PROCESS) begin
      current_padded_row_abs = (op_row_idx * STRIDE) + win_row_ctr;
      current_padded_col_abs = (op_col_idx * STRIDE) + win_col_ctr;

      if ( (current_padded_row_abs >= PADDING) && (current_padded_row_abs < ROW + PADDING) &&
           (current_padded_col_abs >= PADDING) && (current_padded_col_abs < COL + PADDING) ) begin
          pad_region_next = 1'b0; // inside image boundary
      end else begin
          pad_region_next = 1'b1; // outside boundary
      end
    end else begin
      pad_region_next = 1'b0;
    end
  end

  // generic next vector combinatorial logic
  logic [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] next_vector;
  always @(*) begin
    next_vector = {op_vector[(IP_WIDTH * ((1<<VECTOR_DEPTH)-1))-1 : 0], (zero_inj_p2) ? {IP_WIDTH{1'b0}} : r_data};
  end

  always @(posedge clk) begin
    if(rst) begin
      bram_re <= 0; bank_sel <= 0; r_addr <= 0;
      op_valid <= 0; op_vector <= 0; done <= 0;
      vec_ctr <= 0; win_ctr <= 0; win_row_ctr <= 0; win_col_ctr <= 0;
      op_row_idx <= 0; op_col_idx <= 0; 
      row_base_addr <= 0; win_base_addr <= 0; curr_addr <= 0;
      valid_p1 <= 0; valid_p2 <= 0;
      state <= IDLE;
    end
    else begin
      case(state)
        IDLE: begin
          op_valid <= 0; done <= 0; vec_ctr <= 0;
          win_ctr <= 0; win_row_ctr <= 0; win_col_ctr <= 0;
          valid_p1 <= 0; valid_p2 <= 0; bram_re <= 0;

          if(start) begin
            state <= PROCESS;
            bank_sel <= img_bank;
            op_row_idx <= start_row_idx;
            op_col_idx <= start_col_idx;
            
            row_base_addr <= initial_addr;
            win_base_addr <= initial_addr;
            
            // apply pass offsets
            curr_addr   <= initial_addr + k_offset;
            win_row_ctr <= k_row_start;
            win_col_ctr <= k_col_start;
          end
        end
        
        PROCESS: begin
          if (valid_p2) begin
            // flush when we reach the specific length of this pass
            if (win_ctr_p2 == pass_length - 1) begin
                op_vector <= next_vector << (pad_words * IP_WIDTH);
                op_valid <= 1;
                vec_ctr <= 0;
            end else if (win_ctr_p2 == 0) begin
                // First element of a new vector: LOAD, don't shift.
                // This prevents stale data from the previous window's flush.
                op_vector <= next_vector;
                op_valid <= 0;
                vec_ctr <= 1;
            end else begin
                op_vector <= next_vector;
                if(vec_ctr == {VECTOR_DEPTH{1'b1}}) begin
                  op_valid <= 1;
                  vec_ctr <= 0;
                end else begin
                  op_valid <= 0;
                  if (valid_p2) begin // Only increment if data is valid
                    vec_ctr <= vec_ctr + 1;
                  end
                end
            end
          end else begin
            op_valid <= 0;
          end
          // 2. request pipeline logic (stage 1 -> stage 2)
          valid_p2 <= valid_p1;
          zero_inj_p2 <= zero_inj_p1;
          win_ctr_p2 <= win_ctr_p1;

          r_addr <= BRAM_SIZE'(curr_addr);
          bram_re <= !zero_inj_next; 
          zero_inj_p1 <= zero_inj_next;
          win_ctr_p1 <= win_ctr;
          valid_p1 <= 1; // always requesting during process

          // 3. state update logic (calculates next coordinates)
          if(win_ctr == pass_length - 1) begin
            win_ctr <= 0;
            // reset to the start of the current pass, not 0
            win_col_ctr <= k_col_start;
            win_row_ctr <= k_row_start;

            if(op_col_idx >= end_col_idx) begin
              if(op_row_idx >= end_row_idx) begin
                state <= DONE;
                //valid_p1 <= 0; // stop issuing requests
                //bram_re <= 0;
              end else begin
                op_row_idx <= op_row_idx + 1;
                op_col_idx <= start_col_idx;
                row_base_addr <= row_base_addr + JUMP_NEXT_WINDOW_ROW;
                win_base_addr <= row_base_addr + JUMP_NEXT_WINDOW_ROW;
                curr_addr     <= row_base_addr + JUMP_NEXT_WINDOW_ROW + k_offset;
              end 
            end else begin
              op_col_idx <= op_col_idx + 1;
              win_base_addr <= win_base_addr + STRIDE;
              curr_addr     <= win_base_addr + STRIDE + k_offset;
            end
          end else begin 
            win_ctr <= win_ctr + 1;
            if (win_col_ctr == KERNEL_SIZE - 1) begin
              win_col_ctr <= 0;
              win_row_ctr <= win_row_ctr + 1;
              curr_addr <= curr_addr + JUMP_NEXT_KERNEL_ROW; 
            end else begin
              win_col_ctr <= win_col_ctr + 1;
              curr_addr <= curr_addr + 1; 
            end
          end
        end

        DONE: begin
          // Flush the final remaining vectors in the pipeline
          valid_p2 <= valid_p1;
          zero_inj_p2 <= zero_inj_p1;
          win_ctr_p2 <= win_ctr_p1;
          valid_p1 <= 0; 
          bram_re <= 0;

          if (valid_p2) begin
            if (win_ctr_p2 == pass_length - 1) begin
                op_vector <= next_vector << (pad_words * IP_WIDTH);
                op_valid <= 1;
                vec_ctr <= 0;
            end else begin
                op_vector <= next_vector;
                if(vec_ctr == {VECTOR_DEPTH{1'b1}}) begin
                  op_valid <= 1;
                  vec_ctr <= 0;
                end else begin
                  op_valid <= 0;
                  vec_ctr <= vec_ctr + 1;
                end
            end
          end else if (!valid_p1 && !valid_p2) begin
            // wait until pipeline is completely empty before asserting done
            op_valid <= 0;
            done <= 1;
            state <= IDLE;
          end
        end
        default: begin
          bram_re <= 0; bank_sel <= 0; r_addr <= 0;
          op_valid <= 0; op_vector <= 0; done <= 0;
          vec_ctr <= 0; state <= IDLE;
        end
      endcase
    end
  end
endmodule