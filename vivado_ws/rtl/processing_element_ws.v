// =============================================================================
// Module: processing_element_ws (Weight-Stationary Processing Element)
// Project: Neural Network Inference Accelerator
// Target: AMD Zynq-7000 (PYNQ-Z1) — Synthesis target: DSP48E1 slice
//
// PURPOSE
// -------
// This is the fundamental compute unit of the systolic array.
// Each PE computes ONE multiply-accumulate (MAC) operation:
//
//   op_partsum <= ip_partsum + (ip_act * wgt)
//
// In a weight-stationary dataflow:
//   - The WEIGHT is loaded once and stays fixed inside the PE.
//   - ACTIVATIONS stream through horizontally (left → right).
//   - PARTIAL SUMS accumulate vertically (top → bottom).
//
// This module will be replicated GRID_DIM × GRID_DIM times by the
// systolic_array_core generate block.
//
// DATAFLOW DIAGRAM (single PE in context)
// ----------------------------------------
//
//                   ip_partsum (32-bit, from PE above)
//                        │
//                        ▼
//   ip_act (8-bit) ─────►[PE]──────► ip_fwd (8-bit, to PE on right)
//                        │
//                        ▼
//                   op_partsum (32-bit, to PE below)
//
// The PE does:  op_partsum = ip_partsum + $signed(ip_act) * $signed(wgt)
//
// SIGNED ARITHMETIC — WHY IT MATTERS
// ------------------------------------
// INT8 weights range from -128 to +127. If you multiply using unsigned
// arithmetic, -1 (0xFF) becomes +255, and your network produces garbage.
// Verilog's default multiply is UNSIGNED. You MUST use $signed() to tell
// the synthesizer to use a signed multiplier — this maps to a signed DSP48E1.
//
// ACCUMULATOR WIDTH — WHY 32 BITS?
// ----------------------------------
// INT8 × INT8 = up to 127 × 127 = 16,129. That fits in 16 bits.
// But we ACCUMULATE across 9 kernel elements (3×3 conv) and across tiles.
// Worst case across a full dot product: 9 × 127 × 127 = 145,161.
// That requires 18 bits. We use 32-bit (PS_WIDTH) to be safe for any
// reasonable KERNEL_SIZE and to match the DSP48E1's native 48-bit P register
// (which gives us the 32 LSBs after sign-extension). Never size the
// accumulator to "just enough" — use the standard 32-bit width.
//
// DSP48E1 INFERENCE
// ------------------
// Xilinx's DSP48E1 slice (Zynq-7020) is a dedicated silicon MAC unit:
//   P <= A * B + C    (48-bit output, 30-bit A, 18-bit B)
// Vivado will automatically map:
//   op_partsum <= ip_act * wgt + ip_partsum
// onto a single DSP48E1 IF:
//   1. The multiply and accumulate are in ONE always block (not separate)
//   2. The inputs are signed
//   3. There are no extra logic operations between multiply and add
// This mapping reduces area and dramatically improves timing vs LUT-based MACs.
// After synthesis, check the Utilization Report for "DSP" count.
// For an 8×8 array you should see 64 DSP48E1s.
//
// =============================================================================

module processing_element_ws #(
    parameter IP_WIDTH = 8,   // activation bit-width (INT8 = 8 bits)
    parameter WT_WIDTH = 8,   // weight bit-width    (INT8 = 8 bits)
    parameter PS_WIDTH = 32   // partial sum bit-width (INT32 = 32 bits)
)(
    input                            clk,
    input                            rst,
    input                            en,        // when low, the PE holds its outputs
    input                            load_wgt,  // weight load strobe, 1-cycle pulse
    input signed [PS_WIDTH-1:0]      ip_partsum, // partial sum from above PE
    input signed [IP_WIDTH-1:0]      ip_act,     // activation from the left
    input signed [WT_WIDTH-1:0]      ip_wgt,
    output reg signed [IP_WIDTH-1:0]  ip_fwd,    // activation forwarded to right PE
    output reg signed [PS_WIDTH-1:0]  op_partsum  // partial sum passed to below PE
);
// INTERNAL SIGNALS
reg signed [WT_WIDTH-1:0] wgt; // weight register
// $signed(ip_act) and $signed(wgt) is 8-bit signed.
// Product is 8+8 = 16-bit signed (worst case: -128 × -128 = +16384, fits in 16 bits).
// we need to add this to a 32-bit ip_partsum. 
wire signed [PS_WIDTH-1:0] prod;
assign prod = $signed(ip_act) * $signed(wgt);
// Verilog multiplies the 8-bit signed values, produces a 16-bit signed
// result, then sign-extends to 32 bits because prod is declared 32-bit.

// sequential logic
always @(posedge clk) begin
    if (rst) begin
        wgt        <= {WT_WIDTH{1'b0}};
        ip_fwd     <= {IP_WIDTH{1'b0}};
        op_partsum <= {PS_WIDTH{1'b0}};
    end
    else begin
        // load_wgt takes precedence over en (cannot compute while loading weights)
        if (load_wgt) begin
            wgt        <= ip_wgt;
            op_partsum <= {PS_WIDTH{1'b0}}; // clear pipeline on weight reload
        end
        else if (en) begin // compute mode
            ip_fwd     <= ip_act;
            op_partsum <= $signed(ip_partsum) + $signed(prod);
        end
    end
end

endmodule