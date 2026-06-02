`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 29.05.2026 10:46:29
// Design Name: 
// Module Name: axis_increment
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module axis_increment (
    input  wire        aclk,
    input  wire        aresetn,
    
    // AXI4-Stream Slave Interface (Receives data from DMA)
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    
    // AXI4-Stream Master Interface (Sends data back to DMA)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // Combinational logic: Data passes through incremented by 1
    assign m_axis_tdata = s_axis_tdata + 32'd1;
    
    // Handshake logic: The pipeline is ready when the downstream master is ready
    assign s_axis_tready = m_axis_tready;
    
    // Valid logic: The output data is valid if the input data is valid
    assign m_axis_tvalid = s_axis_tvalid;
    
    // TLAST logic: Pass the End-of-Packet signal directly to prevent DMA hangs
    assign m_axis_tlast  = s_axis_tlast;

endmodule