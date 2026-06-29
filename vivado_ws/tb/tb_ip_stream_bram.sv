`timescale 1ns / 1ps

module tb_ip_stream_bram;

  // Global Control
	reg  clk = 0;
	always #5ns clk = !clk;
	reg  rst = 1;
	initial begin
		repeat(4) @(posedge clk);
		rst <= 0;
	end

  // Parameters
  localparam IP_WIDTH = 8;
  localparam DMA_WIDTH = 32;
  localparam BRAM_ADDR_WIDTH = 10;
  localparam K = DMA_WIDTH / IP_WIDTH;
  localparam IMAGE_SIZE = 8; // test image of 8 bytes

  // AXI stream wires
  logic tvalid;
  logic [DMA_WIDTH-1:0] tdata;
  logic tlast;
  logic tready;
  logic im2col_busy;
  logic img_complete;

	// inter-module interconnects for writing data to bram
  logic bram_we;
  logic [BRAM_ADDR_WIDTH-1:0] bram_waddr;
  logic [IP_WIDTH-1:0] bram_wdata;
	
	// bram reading wires
  logic bram_re;
  logic [BRAM_ADDR_WIDTH-1:0] bram_raddr;
  logic [IP_WIDTH-1:0] bram_rdata;
	
  // bank select
  logic bank_sel_w;
  logic bank_sel_r;

  // DUT 1: ip_stream_controller
  ip_stream_controller #(
    .IP_WIDTH(IP_WIDTH),
    .DMA_WIDTH(DMA_WIDTH),
    .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH)
  ) dut_ip_stream_controller (
    .clk(clk),
    .rst(rst),
    .tvalid(tvalid),
    .tdata(tdata),
    .tlast(tlast),
    .tready(tready),
    .im2col_busy(im2col_busy),
    .img_complete(img_complete),
    .bram_we(bram_we),
    .bram_addr(bram_waddr),
    .bram_data(bram_wdata)
  );

  // DUT 2: input_bram
  input_bram #(
    .WIDTH(IP_WIDTH),
    .DEPTH(784),
    .SIZE(BRAM_ADDR_WIDTH)
  ) dut_bram (
    .clk(clk),
    .rst(rst),
    .we(bram_we),
    .w_bank_sel(bank_sel_w),
    .w_addr(bram_waddr),
    .w_data(bram_wdata),
    .re(bram_re),
    .r_bank_sel(bank_sel_r),
    .r_addr(bram_raddr),
    .r_data(bram_rdata)
  );

  // golden reference queue for the scoreboard 
  logic [IP_WIDTH-1:0] expected_mem_q [$];

  // AXI master writer
  task automatic send_axi_word(input logic [DMA_WIDTH-1:0] data_in, input logic is_last);
    begin
      @(posedge clk);
      tvalid <= 1;
      tdata  <= data_in;
      tlast  <= is_last;
      // expected memory layout - LSB first, MSB last
      expected_mem_q.push_back(data_in[7:0]);
      expected_mem_q.push_back(data_in[15:8]);
      expected_mem_q.push_back(data_in[23:16]);
      expected_mem_q.push_back(data_in[31:24]);
      do begin
        @(posedge clk);
      end while (!tready);
      tvalid <= 0;
      tlast  <= 0;
      tdata  <= 'x;
    end
  endtask

  // verify the data in bram
  task automatic verify_bram_contents(input int num_bytes);
    logic [IP_WIDTH-1:0] expected_val;
    begin
      $display("--- Starting BRAM Read Verification ---");
      for (int i = 0; i < num_bytes; i++) begin
        // address and read en
        @(posedge clk);
        bram_re <= 1;
        bram_raddr <= i;
        // wait 1 cycle for BRAM
        @(posedge clk);
        // deassertand check dataa 
        bram_re <= 0;
        #1;
        expected_val = expected_mem_q.pop_front();
				// print the check
        if (bram_rdata !== expected_val) begin
            $error("Time %0t: MEM FAIL @ Addr %0d. Expected %h, Got %h", $time, i, expected_val, bram_rdata);
            $stop;
        end else begin
            $display("MEM PASS @ Addr %0d: Data = %h", i, bram_rdata);
        end
      end
    end
  endtask

  // Test sequence
  initial begin
    $display("=== Starting Integration Test ===");
    // init
    rst = 1;
    tvalid = 0;
    im2col_busy = 0;
    bram_re = 0;
    bram_raddr = 0;
    bank_sel_w = 0; // write to Bank 0
    bank_sel_r = 0; // read from Bank 0 
    repeat(2) @(posedge clk);
    rst = 0;
    repeat(2) @(posedge clk);

    // write 8 bytes (2 AXI Words)
    $display("--- DMA Writing to BRAM ---");
    send_axi_word(32'h04030201, 0); // 0, 1, 2, 3
    repeat(5) @(posedge clk);       // wait for unpacking
    send_axi_word(32'h08070605, 1); // 4, 5, 6, 7 (here TLAST = 1)
    // wait for image complete flag
    wait(img_complete);
    $display("Image Transfer Complete.");
    repeat(2) @(posedge clk);

    // read the 8 bytes from BRAM
    $display("--- Reading from BRAM ---");
    verify_bram_contents(8);

		//print resujlts
    if (expected_mem_q.size() == 0)
        $display("=== INTEGRATION TEST PASSED SUCCESSFULLY ===");
    else
        $error("Test Failed: Leftover expected data.");
        
    $finish;
  end

endmodule