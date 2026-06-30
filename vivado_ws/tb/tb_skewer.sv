module tb_skewer;
    // parameters
    localparam IP_WIDTH = 8;
    localparam VECTOR_DEPTH = $clog2(8);
    
    logic clk;
    logic rst;
    logic start;
    logic done;
    logic ip_valid; // vector is ready to input
    logic [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] ip_vector;
    logic [(1 << VECTOR_DEPTH)-1:0] op_valid;
    logic [(IP_WIDTH * (1 << VECTOR_DEPTH))-1:0] op_vector;
    
    // Global Control
    initial clk = 0;
    always #5ns clk = !clk;
    
    //call module
    skewer #(
          .IP_WIDTH(IP_WIDTH),
          .VECTOR_DEPTH(VECTOR_DEPTH)
          ) dut (
          .clk(clk),
          .rst(rst),
          //.start(start),
          .ip_valid(ip_valid),
          .ip_vector(ip_vector),
          .op_valid(op_valid),
          .op_vector(op_vector)
      );
    
    // Scoreboard and Checker
    // queue so that test cases can be dynamically added
    logic [IP_WIDTH-1:0] expected_vector [$]; 
    logic check_flag = 0;
    //logic [IP_WIDTH-1:0] expected_vector [0:47] = '{0, 0, 0, 0, 0, 1, 0, 28, 0, 0, 0, 0, 1, 2, 28, 29, 0, 0, 0, 1, 2, 3, 29, 30, 0, 0, 0, 2, 3, 4, 30, 31, 0, 0, 0, 3, 4, 5, 31, 32, 0, 0, 0, 4, 5, 6, 32, 33}; 
    logic [4:0] win_count = 0;
    // task to push a 64-bit expected vector into the queue
    task automatic push_expected(input logic [63:0] exp_vec);
        for (int i=7; i>=0; i--) begin
            expected_vector.push_back(exp_vec[i*8 +: 8]);
        end
    endtask

    // checker logic - negedge clk to fix delta-cycle race condition
    // always @(negedge clk) begin 
    //     if (op_valid) begin
    //         $display("Time: %0t | DUT Vector: %h", $time, op_vector);          
    //         check_flag = 1;
            
    //         if(check_flag == 1)begin
    //             $display("[PASS] Vector validated successfully.");
    //         end else begin
    //             $display("[FAIL] Vector does not match");
    //             $stop; // Stop simulation on first failure to make debugging easier
    //         end
    //     end
    // end

    // waveform displayer
    logic wave_display;
    always @(negedge clk) begin
      if(wave_display) begin
        $display("Time: %0t | | VALID: %b | OP Vector: %h", $time, op_valid, op_vector);
      end
    end
    
    // task to give input vector to skewer
    task automatic ip_skew (input logic [63:0] ip_vec);
      @(posedge clk);
      ip_vector <= ip_vec;
      ip_valid <= 1;
      @(posedge clk);
      ip_valid  <= 1'b0;
      ip_vector <= 64'h0;
      repeat(7) @(posedge clk);
    endtask

    // test sequence
    initial begin
        rst = 1;
        #10 rst = 0; #10;
        wave_display <= 1;
        
        $display("\n--- Starting Test Case 1 ---");
        @(posedge clk);
        ip_skew(64'h0807060504030201);
        ip_skew(64'h1817161514131211);
        ip_skew(64'h2827262524232221);
        
        repeat(10) @(posedge clk);
    
        wave_display <= 0;
        $display("\n--- All Tests Complete ---");
        $finish; 
    end
    
endmodule
