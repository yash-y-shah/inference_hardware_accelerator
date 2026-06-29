module tb_im2col;
    // parameters
    localparam IP_WIDTH = 8;
    localparam KERNEL_SIZE = 3;
    localparam ROW = 28;
    localparam COL = 28;
    localparam PADDING = 1;
    localparam STRIDE = 1;
    localparam OP_ROW = (ROW + 2 * PADDING - KERNEL_SIZE)/STRIDE + 1;
    localparam OP_COL = (COL + 2 * PADDING - KERNEL_SIZE)/STRIDE + 1;
    localparam VECTOR_DEPTH = $clog2(8);
    localparam BRAM_SIZE = $clog2(ROW*COL);
    
    logic clk;
    logic rst;
    logic [$clog2(KERNEL_SIZE)-1:0] k_row_start;
    logic [$clog2(KERNEL_SIZE)-1:0] k_col_start;
    logic [VECTOR_DEPTH:0] pass_length;
    logic start;
    logic [$clog2(OP_ROW)-1:0] start_row_idx;
    logic [$clog2(OP_COL)-1:0] start_col_idx;
    logic [$clog2(OP_ROW)-1:0] end_row_idx;   
    logic [$clog2(OP_COL)-1:0] end_col_idx;   
    logic [KERNEL_SIZE*KERNEL_SIZE-1:0] window_select;
    logic img_bank;
    
    logic done;
    logic bram_re;
    logic bank_sel;
    logic [BRAM_SIZE-1:0] r_addr;
    logic [IP_WIDTH-1:0] r_data;
    logic [2:0] fifo_ready;
    logic op_valid;
    logic [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] op_vector;
    
    // Global Control
    
	initial clk = 0;
	always #5ns clk = !clk;
    // BRAM Model
    logic [IP_WIDTH-1:0] sim_bram [0:(ROW*COL)-1];
    always_ff @(posedge clk) begin // 1-cycle latency
            if (bram_re) begin
                    r_data <= sim_bram[r_addr];
            end
    end
    
    //call module
    im2col #(
          .IP_WIDTH(IP_WIDTH),
          .KERNEL_SIZE(KERNEL_SIZE),
          .ROW(ROW),
          .COL(COL),
          .PADDING(PADDING),
          .STRIDE(STRIDE)
      ) dut (
          .clk(clk),
          .rst(rst),
          .start(start),
          .k_row_start(k_row_start),
          .k_col_start(k_col_start),
          .pass_length(pass_length),
          .start_row_idx(start_row_idx),
          .start_col_idx(start_col_idx),
          .end_row_idx(end_row_idx),
          .end_col_idx(end_col_idx),
          .window_select(window_select),
          .img_bank(img_bank),
          .done(done),
          .bram_re(bram_re),
          .bank_sel(bank_sel),
          .r_addr(r_addr),
          .r_data(r_data),
          .fifo_ready(fifo_ready),
          .op_valid(op_valid),
          .op_vector(op_vector)
      );
    
    // Scoreboard and Checker
    // queue so that test cases can be dynamically added
    logic [IP_WIDTH-1:0] expected_pixels [$]; 
    logic check_flag = 0;
    //logic [IP_WIDTH-1:0] expected_pixels [0:47] = '{0, 0, 0, 0, 0, 1, 0, 28, 0, 0, 0, 0, 1, 2, 28, 29, 0, 0, 0, 1, 2, 3, 29, 30, 0, 0, 0, 2, 3, 4, 30, 31, 0, 0, 0, 3, 4, 5, 31, 32, 0, 0, 0, 4, 5, 6, 32, 33}; 
    logic [4:0] win_count = 0;
    // task to push a 64-bit expected vector into the queue
    task automatic push_expected(input logic [63:0] exp_vec);
        for (int i=7; i>=0; i--) begin
            expected_pixels.push_back(exp_vec[i*8 +: 8]);
        end
    endtask

    // checker logic - negedge clk to fix delta-cycle race condition
    always @(negedge clk) begin 
        if (op_valid) begin
            $display("Time: %0t | DUT Vector: %h", $time, op_vector);          
            check_flag = 1;
            for (int i=0; i<8; i++) begin
                logic [7:0] pixel;
                logic [7:0] expected_pixel;
                
                pixel = op_vector[(7-i)*8 +: 8];
                expected_pixel = expected_pixels.pop_front(); // Automatically grabs the next expected byte
                
                if (pixel !== expected_pixel) begin
                    $display("Mismatch at element %d - Expected: %h, Got: %h", i, expected_pixel, pixel);
                    check_flag = 0;
                end else begin
                    $display("GotMatch at element %d - Expected: %h, Got: %h", i, expected_pixel, pixel);
                end
            end
            if(check_flag == 1)begin
                $display("[PASS] Vector validated successfully.");
            end else begin
                $display("[FAIL] Vector does not match");
                $stop; // Stop simulation on first failure to make debugging easier
            end
        end
    end
    
    // test sequence
    initial begin
        // initialize BRAM
        for (int i = 0; i < (ROW*COL); i++) begin
                sim_bram[i] = i % 255;
        end
        // display the bram first 5 rows and columns
        $display("Initial BRAM State (first 5 rows and columns):");
        for (int i = 0; i < 5; i++) begin
            for (int j = 0; j < 5; j++) begin
                    $write("%2h", sim_bram[i*ROW + j]);
                    if (j < 4) $write(" ");
            end
            $write("\n");
        end
        rst = 1; start = 0; img_bank = 0; fifo_ready = 3'b111;
        window_select = 9'b111111111;
        #10 rst = 0; #10;
        
        $display("\n--- Starting Test Case 1 (Top-Left, Pass 1) ---");
        // Push expected results for windows 0, 1, and 2
        push_expected(64'h000000000001001c); // Win 0
        push_expected(64'h0000000001021c1d); // Win 1
        push_expected(64'h0000000102031d1e); // Win 2
        k_row_start = 0; k_col_start = 0; pass_length = 8;
        start_row_idx = 0; start_col_idx = 0; end_row_idx = 0; end_col_idx = 2;

        start = 1; #10 start = 0;
        @(posedge done); #20;

        $display("\n--- Starting Test Case 2 (Top-Left, Pass 2 Remainder) ---");
        // Element 8 of Win 0 is coordinate (1,1) -> index 29 (1D in hex). Shifted left by padding.
        expected_pixels.delete();
        push_expected(64'h1d00000000000000); // Win 0 
        push_expected(64'h1e00000000000000); // Win 1
        push_expected(64'h1f00000000000000); // Win 2        
        k_row_start = 2; k_col_start = 2; pass_length = 1;
        start_row_idx = 0; start_col_idx = 0; end_row_idx = 0; end_col_idx = 2;
        
        start = 1; #10 start = 0;
        @(posedge done); #20;
        
        $display("\n--- Starting Test Case 3 (Center Image, No Padding) ---");
        // Test Window at coordinate (5,5). 
        // Elements: (4,4) to (6,5).
        // 4*28+4=116(0x74), 117(0x75), 118(0x76), 5*28+4=144(0x90), 145(0x91), 146(0x92), 6*28+4=172(0xac), 173(0xad)
        expected_pixels.delete();
        push_expected(64'h747576909192acad);
        k_row_start = 0; k_col_start = 0; pass_length = 8;
        start_row_idx = 5; start_col_idx = 5; end_row_idx = 5; end_col_idx = 5;
        
        start = 1; #10 start = 0;
        @(posedge done); #20;

        $display("\n--- All Tests Complete ---");
        $finish; 
    end
    
endmodule
