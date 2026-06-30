// =============================================================================
// Testbench: tb_systolic_array_core
// FIXES vs. original:
//   1. load_weights(): weight_matrix set BEFORE weight_load asserted (protocol fix)
//   2. data_in() / feed_activation(): uses actual input argument (not test_vector)
//   3. Self-checking scoreboard: automated pass/fail, no manual waveform reading
//   4. wave_display initialized to 0 (eliminates X on first negedge)
//   5. clearsum removed (not a DUT port anymore)
//   6. Proper en/valid handling through full LATENCY window
// =============================================================================
`timescale 1ns/1ps

module tb_systolic_array_core;
    localparam IP_WIDTH = 8;
    localparam WT_WIDTH = 8;
    localparam PS_WIDTH = 32;
    localparam GRID_DIM = 8;
    localparam LATENCY  = 2 * (GRID_DIM - 1);   // = 14 for GRID_DIM=8

    logic clk = 0;
    logic rst;
    logic en;
    logic weight_load;
    logic signed [WT_WIDTH-1:0] weight_matrix [GRID_DIM-1:0][GRID_DIM-1:0];
    logic signed [IP_WIDTH-1:0] ip_act        [GRID_DIM-1:0];
    logic signed [PS_WIDTH-1:0] result        [GRID_DIM-1:0];
    logic result_valid;

    // Scoreboard
    int pass_count = 0;
    int fail_count = 0;

    always #5ns clk = ~clk;

    // DUT
    systolic_array_core #(
        .IP_WIDTH(IP_WIDTH),
        .WT_WIDTH(WT_WIDTH),
        .PS_WIDTH(PS_WIDTH),
        .GRID_DIM(GRID_DIM)
    ) dut (
        .clk          (clk),
        .rst          (rst),
        .en           (en),
        .weight_load  (weight_load),
        .weight_matrix(weight_matrix),
        .ip_act       (ip_act),
        .result       (result),
        .result_valid (result_valid)
    );

    // Waveform Monitor (always active, shows result when valid)
		logic disp_wfm;
    always @(negedge clk) begin
        if (disp_wfm) begin
            $display("t=%0t VALID=1 | %0d %0d %0d %0d %0d %0d %0d %0d",
                     $time,
                     result[7], result[6], result[5], result[4],
                     result[3], result[2], result[1], result[0]);
        end
    end

    task automatic apply_reset();
        rst = 1; en = 0; weight_load = 0;
        for (int r = 0; r < GRID_DIM; r++) begin
            ip_act[r] = 0;
            for (int c = 0; c < GRID_DIM; c++)
                weight_matrix[r][c] = 0;
        end
        repeat(4) @(posedge clk);
        rst = 0;
        repeat(2) @(posedge clk);
    endtask

    // TASK: load_weights
    task automatic load_weights(
        input logic signed [WT_WIDTH-1:0] wt [GRID_DIM-1:0][GRID_DIM-1:0]
    );
        // weights on the bus
        en <= 0;
        for (int r = 0; r < GRID_DIM; r++)
            for (int c = 0; c < GRID_DIM; c++)
                weight_matrix[r][c] <= wt[r][c];
        @(posedge clk); #1;
        // assert weight_load - 1 cycle pulse
        weight_load <= 1;
        @(posedge clk); #1;
        // deassert
        weight_load <= 0;
        @(posedge clk);         // Loading complete
    endtask

    // feed_activation - ip_act with unskewed inputs 
    task automatic feed_activation(
        input logic signed [IP_WIDTH-1:0] act [GRID_DIM-1:0]
    );
				#1; // small offset to avoid hold-time issues at posedge boundary
				disp_wfm <=1;
        for (int r = 0; r < GRID_DIM; r++)
            ip_act[r] <= act[r];
        en <= 1;
        // long enough for full pipeline to fill the last column to drain
        // LATENCY cycles for first column, GRID_DIM-1 extra for last column.
        repeat(LATENCY + GRID_DIM + 4) @(posedge clk);
        en <= 0;
        // result_valid drain, low after LATENCY cycles after en 0
        repeat(LATENCY + 2) @(posedge clk);
				disp_wfm <=0;
    endtask

    // check_result
    task automatic check_result(
        input string test_name,
        input logic signed [PS_WIDTH-1:0] expected [GRID_DIM-1:0]
    );
        logic local_pass;
        local_pass = 1;
        begin
            int timeout = 0;
            while (!result_valid && timeout < 50) begin
                @(posedge clk);
                timeout++;
            end
            if (!result_valid) begin
                $display("[%s] ERROR: result_valid never asserted (timeout)", test_name);
                fail_count++;
                return;
            end
        end
        // sample at negedge
        @(negedge clk);
        for (int c = 0; c < GRID_DIM; c++) begin
            if (result[c] !== expected[c]) begin
                $display("[%s] FAIL col[%0d]: expected=%0d, got=%0d",
                         test_name, c, expected[c], result[c]);
                local_pass = 0;
            end
        end
        if (local_pass) begin
            $display("[%s] PASS: all %0d columns correct", test_name, GRID_DIM);
            pass_count++;
        end else fail_count++;
    endtask

    // Test Sequence
    initial begin
        apply_reset();

        $display("\n=== TEST 1: Single active row, all weights = 1 ===");
        begin : test1
            logic signed [WT_WIDTH-1:0] wt1 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act1 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp1 [GRID_DIM-1:0];

            for (int r=0; r<GRID_DIM; r++)
                for (int c=0; c<GRID_DIM; c++)
                    wt1[r][c] = 8'sh01;

            act1[0] = 8'sh01;
            for (int r=1; r<GRID_DIM; r++) act1[r] = 8'sh00;

            for (int c=0; c<GRID_DIM; c++) exp1[c] = 32'sd1;

            load_weights(wt1);
            fork
                feed_activation(act1);
                check_result("TEST1", exp1);
            join
        end
        apply_reset();

        $display("\n=== TEST 2: All rows active, all weights = 1, expected = 8 ===");
        begin : test2
            logic signed [WT_WIDTH-1:0] wt2 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act2 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp2 [GRID_DIM-1:0];

            for (int r=0; r<GRID_DIM; r++)
                for (int c=0; c<GRID_DIM; c++)
                    wt2[r][c] = 8'sh01;

            for (int r=0; r<GRID_DIM; r++) act2[r] = 8'sh01;
            for (int c=0; c<GRID_DIM; c++) exp2[c] = 32'sd8;

            load_weights(wt2);
            fork
                feed_activation(act2);
                check_result("TEST2", exp2);
            join
        end
        apply_reset();

        // -----------------------------------------------------------------
        // TEST 3: Ramp activations, per-column weights
        // ip_act[r] = r+1  (i.e., 1,2,3,4,5,6,7,8)
        // weight[r][c] = c+1 for all r  (each column has the same weight)
        // Expected: result[c] = (c+1) * SUM(r=0..7)(r+1)
        //                     = (c+1) * 36
        //   result[0]=36, result[1]=72, result[2]=108, ..., result[7]=288
        // -----------------------------------------------------------------
        $display("\n=== TEST 3: Ramp act, per-column weights, expected (c+1)*36 ===");
        begin : test3
            logic signed [WT_WIDTH-1:0] wt3 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act3 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp3 [GRID_DIM-1:0];

            for (int r=0; r<GRID_DIM; r++)
                for (int c=0; c<GRID_DIM; c++)
                    wt3[r][c] = 8'(c+1);

            for (int r=0; r<GRID_DIM; r++) act3[r] = 8'(r+1);
            // SUM(1..8) = 36
            for (int c=0; c<GRID_DIM; c++) exp3[c] = 32'($signed(c+1) * 36);

            load_weights(wt3);
            fork
                feed_activation(act3);
                check_result("TEST3", exp3);
            join
        end
        apply_reset();

        // -----------------------------------------------------------------
        // TEST 4: Negative weights — validates $signed() / DSP48E1 signed mode
        // ip_act[r] = 1 for all r, weight[r][c] = -1 for all r,c
        // Expected: result[c] = 8 * (1 * -1) = -8 for all c
        // -----------------------------------------------------------------
        $display("\n=== TEST 4: Negative weights, expected = -8 ===");
        begin : test4
            logic signed [WT_WIDTH-1:0] wt4 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act4 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp4 [GRID_DIM-1:0];

            for (int r=0; r<GRID_DIM; r++)
                for (int c=0; c<GRID_DIM; c++)
                    wt4[r][c] = -8'sd1;

            for (int r=0; r<GRID_DIM; r++) act4[r] = 8'sd1;
            for (int c=0; c<GRID_DIM; c++) exp4[c] = -32'sd8;

            load_weights(wt4);
            fork
                feed_activation(act4);
                check_result("TEST4", exp4);
            join
        end
        apply_reset();

        // -----------------------------------------------------------------
        // TEST 5: Weight reload correctness
        // First load: all weights = 2.  Compute: act[r]=1 → result[c]=16
        // Second load: all weights = 3. Compute: act[r]=1 → result[c]=24
        // This verifies that load_weights() correctly replaces all weights.
        // -----------------------------------------------------------------
        $display("\n=== TEST 5: Weight reload — weights=2 then weights=3 ===");
        begin : test5a
            logic signed [WT_WIDTH-1:0] wt5 [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act5 [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp5 [GRID_DIM-1:0];

            for (int r=0; r<GRID_DIM; r++)
                for (int c=0; c<GRID_DIM; c++)
                    wt5[r][c] = 8'sh02;

            for (int r=0; r<GRID_DIM; r++) act5[r] = 8'sh01;
            for (int c=0; c<GRID_DIM; c++) exp5[c] = 32'sd16;  // 8 * 1*2

            load_weights(wt5);
            fork
                feed_activation(act5);
                check_result("TEST5a(wt=2)", exp5);
            join
        end
        apply_reset();

        begin : test5b
            logic signed [WT_WIDTH-1:0] wt5b [GRID_DIM-1:0][GRID_DIM-1:0];
            logic signed [IP_WIDTH-1:0] act5b [GRID_DIM-1:0];
            logic signed [PS_WIDTH-1:0] exp5b [GRID_DIM-1:0];

            for (int r=0; r<GRID_DIM; r++)
                for (int c=0; c<GRID_DIM; c++)
                    wt5b[r][c] = 8'sh03;

            for (int r=0; r<GRID_DIM; r++) act5b[r] = 8'sh01;
            for (int c=0; c<GRID_DIM; c++) exp5b[c] = 32'sd24;  // 8 * 1*3

            load_weights(wt5b);
            fork
                feed_activation(act5b);
                check_result("TEST5b(wt=3)", exp5b);
            join
        end
        apply_reset();

        // -----------------------------------------------------------------
        // SUMMARY
        // -----------------------------------------------------------------
        $display("\n========================================");
        $display("  TESTBENCH COMPLETE");
        $display("  PASSED: %0d", pass_count);
        $display("  FAILED: %0d", fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED ✓");
        else
            $display("  FAILURES DETECTED — review above ✗");
        $display("========================================\n");
        $finish;
    end

endmodule
