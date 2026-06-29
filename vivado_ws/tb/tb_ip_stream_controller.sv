module tb_ip_stream_controller; // Removed duplicate module declaration


  localparam IP_WIDTH = 8;
  localparam DMA_WIDTH = 32;
  localparam BRAM_ADDR_WIDTH = 10;
  localparam int unsigned K = DMA_WIDTH/IP_WIDTH;
  // Global Control
	reg  clk = 0;
	always #5ns clk = !clk;
	reg  rst = 1;
	initial begin
		repeat(4) @(posedge clk);
		rst <= 0;
	end

  // input axi stream
  reg tvalid; // DMA driven
  reg [DMA_WIDTH-1:0] tdata; // DMA driven(32-bit)
  reg tlast; // DMA driven
  reg tready; //  FSM driven - tells DMA if BRAM is full.

  reg im2col_busy; // im2Col asserts this while computing - drives tready low, preventing DMA from overwriting image being processed.
  reg img_complete; // asserted when a valid handshake occurs with tlast high, indicating end of an image stream.
  
  wire bank_sel; // toggle bit to alternate bram storage (This signal is commented out in DUT, consider removing if unused)
  wire bram_we; // write enable, high when a valid handshake occurs.
  wire [BRAM_ADDR_WIDTH-1:0] bram_addr; // counter value.
  wire [IP_WIDTH-1:0] bram_data; // sliced/unpacked pixel data.
  
  wire [$clog2(K):0] debug_datactr;

  //module instance
  ip_stream_controller #(
    .IP_WIDTH(IP_WIDTH),
    .DMA_WIDTH(DMA_WIDTH),
    .BRAM_ADDR_WIDTH(BRAM_ADDR_WIDTH)
  ) dut (
    .clk(clk),
    .rst(rst),
    .tvalid(tvalid),
    .tdata(tdata),
    .tlast(tlast),
    .tready(tready),
    .im2col_busy(im2col_busy),
    .img_complete(img_complete),
    .debug_datactr(debug_datactr),
    //.bank_sel(bank_sel),
    .bram_we(bram_we),
    .bram_addr(bram_addr),
    .bram_data(bram_data)
  );
  
  // A task that aends a 32-bit hex word
  task automatic data_write(
    input logic [DMA_WIDTH-1:0] data_in,
    input logic                 is_last
  );
    begin
      // synchronize to the clock edge before driving signals
      @(posedge clk);
      tvalid <= 1'b1;
      tdata  <= data_in;
      tlast  <= is_last;
      
      // Wait for the AXI handshake (TVALID && TREADY == 1 on a clock edge)
      // do-while loop to check TREADY exactly on the rising clock edges.
      do begin
        @(posedge clk);
      end while (tready == 1'b0);
      //Handshake complete, deassert signals
      tvalid <= 1'b0;
      tlast  <= 1'b0;
      tdata  <= 'x; // X catches bugs if DUT reads when TVALID is 0
    end
  endtask
  
  // always block that captures data whenever bram_we is high
  always @(posedge clk) begin
    if(bram_we) begin
      $display("BRAM Write - Addr: %0d, Data: %h", bram_addr, bram_data);
    end
  end
    
  // A SystemVerilog Queue to hold what we EXPECT the DUT to output
  logic [IP_WIDTH-1:0] expected_queue [$];
  int expected_addr = 0;
  // fill the queue with test data
  initial begin
    expected_queue.push_back(8'h04);
    expected_queue.push_back(8'h03);
    expected_queue.push_back(8'h02);
    expected_queue.push_back(8'h01);
    // Add more as you add more stimulus...
  end

  // Automated Checker
  always @(posedge clk) begin
    if(tvalid && tready) begin
        expected_queue.push_back(tdata[7:0]);
        expected_queue.push_back(tdata[15:8]);
        expected_queue.push_back(tdata[23:16]);
        expected_queue.push_back(tdata[31:24]);
    end
    if(bram_we) begin
      logic [IP_WIDTH-1:0] expected_data;
      if(expected_queue.size() == 0) begin
         $error("DUT wrote data %h, but we didn't expect any more writes!", bram_data);
      end else begin
         expected_data = expected_queue.pop_front();
         // Automatically check Data and Address!
         if(bram_data !== expected_data)
            $error("DATA MISMATCH at Addr %0d. Expected %h, Got %h", bram_addr, expected_data, bram_data);
         if(bram_addr !== expected_addr)
            $error("ADDR MISMATCH. Expected %0d, Got %0d", expected_addr, bram_addr);         
         expected_addr++; // Calculate next expected address
      end
    end
  end
  
  // Test Sequence
  initial begin
    // Wait for reset deassertion
    wait(!rst);
    $display("Reset Turned off - Start");
    @(posedge clk); // Hold for 1 cycle of valid handshake
    im2col_busy = 0;
    data_write (32'h01020304, 0);
    data_write (32'h02030405, 1);
    repeat(5) @(posedge clk);
    tdata <= 32'h01020304;
    @(posedge clk); tdata <= tdata-1;
    @(posedge clk); tdata <= tdata-1;
    repeat(10) @(posedge clk);
    
    $display("All test cases completed.");
    $finish;
  end

endmodule
