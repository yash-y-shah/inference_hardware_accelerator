//Reads from Input BRAM using sliding window address pointers.
//Writes flattened vectors to the Skewing FIFOs.
//Bandwidth constraint: Must output one 8-element vector per 8 clock cycles to keep the array fed.

module im2col #(
  IP_WIDTH = 8;
	WT_WIDTH = 8;
  KERNEL_SIZE = 3;
  ROW = 28;
  COL = 28;
  PADDING = 1;
  STRIDE = 1;
  OP_ROW = (ROW + 2 * PADDING - 1)/STRIDE;
  OP_COL = (COL + 2 * PADDING - 1)/STRIDE;
  GRID_DIM = $clog2(8);
  VECTOR_DEPTH = $clog2(8);
  BRAM_SIZE = $clog2(28);
)(
  input clk,
  input rst,

  input start, // indicating a new image is loaded and ready
  input [$clog2(OP_ROW)-1:0] start_row_idx, // start row address
  input [$clog2(OP_COL)-1:0] start_col_idx, // start column address
  input [$clog2(OP_ROW)-1:0] end_row_idx,   // end row address
  input [$clog2(OP_COL)-1:0] end_col_idx,   // end column address
  input [KERNEL_SIZE*KERNEL_SIZE-1:0] window_select, // indicates which weights are present in the systolic array  
  input img_bank, // bram bank containing img
  output done, // high when entire portion has been sent

  output bram_re, // read enable for bram
  output bank_sel, //toggle bit to alternate bram storage
  output reg [BRAM_SIZE-1:0] r_addr, // address
  input [IP_WIDTH-1:0] r_data, // pixel data to be read from bram (1 cycle latecny)

  input [GRID_DIM-1:0]fifo_ready, // from fifo
  output op_valid, // vector is ready
  output reg [IP_WIDTH+VECTOR_DEPTH-1:0] op_vector,

  // output [IP_WIDTH+GRID_DIM-1:0] ip_act, // activation
  // output [WT_WIDTH+GRID_DIM-1:0] ip_wgt, // weight
);
  // Local Variables
  reg [VECTOR_DEPTH-1:0] vec_ctr; //vector counter
  reg [$clog2(KERNEL_SIZE)-1:0] win_ctr; //window counter
  // current address
  reg [BRAM_SIZE-1:0] next_addr;
  // current indexes
  reg [$clog2(ROW)-1:0] row_idx;
  reg [$clog2(COL)-1:0] col_idx;
  reg [$clog2(OP_ROW)-1:0] op_row_idx;
  reg [$clog2(OP_COL)-1:0] op_col_idx;

  wire pad_region_next; // padding region
  wire inc_kernel_next; // kernel is to be included
  wire zero_inj_next; // inject zero in the vector
  reg zero_inj; // current zero injection register
  
  reg [1:0] state;
  localparam IDLE = 2'b00, PROCESS = 2'b01, DONE = 2'b10, I = 2'b11;
  localparam K = KERNEL_SIZE*KERNEL_SIZE;

  always @(*) begin //combinatorial calculation for the next index
    if(state==PROCESS) begin
      if(op_row_idx*STRIDE >= PADDING && op_col_idx*STRIDE >= PADDING && op_row_idx*STRIDE < ROW - PADDING && op_col_idx*STRIDE < COL - PADDING) begin
          pad_region_next = 0; // every element inside
      end
      else begin //on the boundary
        if(win_ctr == (K-1){2'b1}) begin
          if(((op_row_idx+1)*STRIDE >= PADDING) || ((op_row_idx+1)*STRIDE <= ROW + PADDING))
            if(((op_col_idx+1)*STRIDE >= PADDING) || ((op_col_idx+1)*STRIDE <= COL + PADDING))
              pad_region_next = 0;
          else pad_region_next = 1;
        end else begin
          if((op_row_idx*STRIDE + (win_ctr+1)/KERNEL_SIZE >= PADDING) || (op_row_idx*STRIDE + (win_ctr+1)/KERNEL_SIZE <= ROW + PADDING))
            if((op_col_idx*STRIDE + (win_ctr+1)%KERNEL_SIZE >= PADDING) || (op_col_idx*STRIDE + (win_ctr+1)%KERNEL_SIZE <= COL + PADDING))
              pad_region_next = 0;
          else pad_region_next = 1;
        end
      end
    end
  end
  assign inc_kernel_next = (2'b1<<win_ctr) & window_select;
  assign zero_inj_next = pad_region_next || !inc_kernel_next;

  always @(posegde clk) begin
    if(rst) begin
      bram_re <=0; bank_sel <=0; r_addr <=0;
      ip_act <=0; ip_wgt <=0;
      op_valid <=0; op_vector <=0;
      done <=0;
      vec_ctr <=0;
      state <= IDLE;
    end
    else begin
      case(state)
        IDLE: begin
          bram_re <=0; bank_sel <=0; r_addr <=0;
          ip_act <=0; ip_wgt <=0;
          op_valid <=0; op_vector <=0;
          done <=0;
          vec_ctr <=0;
          if(start) begin
            state <= PROCESS;
            bank_sel <= img_bank;
            op_row_idx <= start_row_idx;
            op_col_idx <= start_col_idx;
            if(((op_row_idx+1)*STRIDE >= PADDING) || ((op_row_idx+1)*STRIDE <= ROW + PADDING)&&((op_col_idx+1)*STRIDE >= PADDING) || ((op_col_idx+1)*STRIDE <= COL + PADDING)&& (window_select==1)) begin
              bram_re <= 1;
              r_addr <= ROW * (start_row_idx) + start_cow_idx;
            else begin
              bram_re <= 0;
          end
        end
        
        PROCESS: begin
          // update vector with data or zero
          op_vector << IP_WIDTH;
          op_vector[IP_WIDTH-1:0] <= (zero_inj)? r_data: (IP_WIDTH){2'b0};
          // if vector is finished
          if(vec_ctr == VECTOR_DEPTH{2'b1}) begin
            op_valid <= 1;
            vec_ctr <= 0;
          end else begin
            op_valid <= 0;
            vec_ctr <= vec_ctr + 1;
          end
          
          //check if next one is zero
          if(zero_inj_next)
            bram_re <= 2'b0;
          else begin
            bram_re <= 2'b1;
            next_addr <= ROW * (op_row_idx + win_ctr/K) + op_col_idx + win_ctr%K;
            r_addr <= next_addr;
          end

          // check if window is done, if yes then move on to next window
          if(win_ctr == (K-1){2'b1}) begin
            win_ctr <= (K-1){2'b0};
            // is this is the last address then proceed state and finish process
            if(op_row_idx == end_row_idx && op_col_idx == end_col_idx) begin
              state <= DONE;
              done <= 1;
              bram_re <=0;
              op_row_idx <= 0; op_col_idx <= 0;
              op_valid <= 1; vec_ctr <= 0;
            end else begin
              op_row_idx <= op_row_idx + 1;
              op_col_idx <= op_col_idx + 1;
            end
          end else begin // otherwise increment window counter
            win_ctr <= win_ctr +1;
          end
        end

        DONE: begin

        end
        default: begin
          bram_re <=0; bank_sel <=0; r_addr <=0;
          ip_act <=0; ip_wgt <=0;
          op_valid <=0; op_vector <=0;
          done <=0;
          vec_ctr <=0;
        end

      endcase
    end

  end
endmodule