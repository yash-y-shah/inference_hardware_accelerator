
module systolic_array_core #(
    parameter IP_WIDTH = 8,    // activation bit-width = INT8
    parameter WT_WIDTH = 8,    // weight bit-width = INT8
    parameter PS_WIDTH = 32,   // partial sum width = INT32
    parameter GRID_DIM = 8     // array dimension = GRID_DIM × GRID_DIM PEs
)(
    input clk,
    input rst,
    input en,
    input weight_load,
    input  signed [WT_WIDTH-1:0] weight_matrix [GRID_DIM-1:0][GRID_DIM-1:0],
    input  signed [IP_WIDTH-1:0] ip_act        [GRID_DIM-1:0],
    output signed [PS_WIDTH-1:0] result        [GRID_DIM-1:0],
    output reg                   result_valid
);
// Pipeline latency: (GRID_DIM-1) column register stages + (GRID_DIM-1) row register stages
localparam LATENCY = 2 * (GRID_DIM - 1);
// NUM_PES would be GRID_DIM*GRID_DIM but is not used internally — kept for documentation only.
// localparam NUM_PES = GRID_DIM * GRID_DIM;
// weight loading - 2D bus - entire weight matrix in ONE clock cycle

// driven by PE[row][col].ip_fwd, read by PE[row][col+1].ip_act (for col < GRID_DIM-1)
wire signed [IP_WIDTH-1:0] act_wire  [GRID_DIM-1:0][GRID_DIM-1:0]; 
// driven by PE[row][col].op_partsum, read by PE[row+1][col].ip_partsum (for row < GRID_DIM-1).
wire signed [PS_WIDTH-1:0] psum_wire [GRID_DIM-1:0][GRID_DIM-1:0];

// PE array
genvar row, col;
generate
    for (row = 0; row < GRID_DIM; row = row + 1) begin : row_gen
        for (col = 0; col < GRID_DIM; col = col + 1) begin : col_gen
            processing_element_ws #(
                .IP_WIDTH  (IP_WIDTH),
                .WT_WIDTH  (WT_WIDTH),
                .PS_WIDTH  (PS_WIDTH)
            ) u_pe (
                .clk       (clk),
                .rst       (rst),
                .en        (en),
                .load_wgt  (weight_load),
                .ip_wgt    (weight_matrix[row][col]),
                .ip_act    ((col == 0) ? ip_act[row] : act_wire[row][col-1]),
                .ip_partsum((row == 0) ? {PS_WIDTH{1'b0}} : psum_wire[row-1][col]),
                .ip_fwd    (act_wire[row][col]),
                .op_partsum(psum_wire[row][col])
            );
        end
    end
endgenerate

// RESULT OUTPUT CONNECTIONS
//
// We need a generate loop to make GRID_DIM individual assign statements
// because 'result' is an UNPACKED array. Unpacked arrays cannot be driven
// by a single assignment statement that spans all elements.
//
// SystemVerilog allows driving unpacked arrays in some contexts (e.g., always blocks)
// but continuous assign on packed slices of unpacked arrays is not legal.
// A generate loop with individual assign statements is the most portable approach.

genvar i;
generate
    for (i = 0; i < GRID_DIM; i = i + 1) begin : result_assign
        assign result[i] = psum_wire[GRID_DIM-1][i];
    end
endgenerate

// a shift register of LATENCY bits, so result_valid is driven by the last bit of the shift register.
// Timing example for GRID_DIM=4 (LATENCY=6):
//   Cycle 0: en=1 → valid_sr = 6'b000001
//   Cycle 1: en=1 → valid_sr = 6'b000011
//   ...
//   Cycle 5: en=1 → valid_sr = 6'b111111 → result_valid = 1
// This is a standard technique used in all pipelined RTL designs.
// In interviews, this is called a "pipeline valid tracking" or
// "credit counter" approach (for multi-beat pipelines).
generate
    if (LATENCY == 0) begin // no latency, combinational
        always @(*) result_valid = en;
    end else begin // nonzero latency
        reg [LATENCY-1:0] valid_sr;
        always @(posedge clk) begin
            if (rst) begin
                valid_sr <= {LATENCY{1'b0}};
                result_valid <= 1'b0;
            end else begin
                // shift toward the MSB
                valid_sr <= {valid_sr[LATENCY-2:0], en};
                // output has traveled through LATENCY number of stages
                result_valid <= valid_sr[LATENCY-1];
            end
        end
    end
endgenerate

endmodule

// =============================================================================
// SYSTOLIC ARRAY THEORY — WEIGHT-STATIONARY DATAFLOW
// =============================================================================
//
// ARRAY STRUCTURE (N = GRID_DIM, shown for N=4 for readability)
//
//   ip_act[0] ──►[PE 0,0]──►[PE 0,1]──►[PE 0,2]──►[PE 0,3]
//                    │            │            │            │
//   ip_act[1] ──►[PE 1,0]──►[PE 1,1]──►[PE 1,2]──►[PE 1,3]
//                    │            │            │            │
//   ip_act[2] ──►[PE 2,0]──►[PE 2,1]──►[PE 2,2]──►[PE 2,3]
//                    │            │            │            │
//   ip_act[3] ──►[PE 3,0]──►[PE 3,1]──►[PE 3,2]──►[PE 3,3]
//                    │            │            │            │
//               result[0]   result[1]   result[2]   result[3]
//
//   ──► = activation flows horizontally (left → right), registered each step
//    │  = partial sum flows vertically  (top → bottom), registered each step
//
// Each PE[row][col] holds weight[row][col] and computes:
//   psum_out = psum_in + ip_act × weight[row][col]
//
// After all GRID_DIM rows drain their partial sums:
//   result[col] = ip_act[0]*W[0][col] + ip_act[1]*W[1][col] + ... + ip_act[N-1]*W[N-1][col]
//
// That is the dot product of the activation vector with column col of the weight matrix.
//
// =============================================================================
// WEIGHT LOADING — 2D BUS (SINGLE-CYCLE LOAD)
// =============================================================================
//
// We use a 2D weight input bus: weight_matrix[GRID_DIM][GRID_DIM]
// When weight_load is asserted, every PE[row][col] loads weight_matrix[row][col].
// This loads the full N×N weight matrix in exactly ONE clock cycle.
//
// WHY NOT SHIFT-REGISTER LOADING?
// Shift-register loading (as used in Google's TPU) loads one row per cycle over
// N cycles. It is more area-efficient (thinner bus) but requires N cycles of
// loading time and more complex control. For our 8×8 array with Vivado synthesis,
// the 2D bus approach is simpler to implement correctly and to verify.
//
// INTERVIEW TALKING POINT:
// "I chose single-cycle weight loading via a 2D bus for simplicity and
// verification clarity. A production design would use shift-register loading
// (as in Google's TPU) to reduce the weight bus fanout and allow streaming
// weight updates without stalling the pipeline."
//
// =============================================================================
// TIMING AND VALID GENERATION
// =============================================================================
//
// Because activations are REGISTERED at each PE, they take 1 cycle to cross.
// ip_act[row] takes (col) cycles to reach PE[row][col].
// Partial sums take (row) cycles to travel from row 0 to the bottom.
//
// With properly skewed inputs (skewing FIFOs upstream), the first valid result
// exits at cycle LATENCY = 2*(GRID_DIM-1) after en is asserted.
//
// result_valid is asserted LATENCY cycles after en goes high.
// It stays high as long as en is high (streaming mode).
//
// =============================================================================

// KEY LEARNING: HOW GENERATE WORKS IN SYSTEMVERILOG
// ---------------------------------------------------
// generate/endgenerate encloses a region where you can use for loops,
// if statements, and case statements to conditionally or repeatedly
// instantiate hardware.
//
// Syntax rules:
//   1. One pair of generate/endgenerate for the whole block.
//   2. Inner for loops do NOT get their own generate/endgenerate.
//   3. genvar variables must be declared OUTSIDE the generate block.
//   4. Each begin...end block MUST have a unique name (: name).
//      These names become hierarchical path prefixes in simulation:
//      e.g., u_systolic_array.row_gen[2].col_gen[5].pe
//   5. Conditional expressions in port connections (col == 0) ? ... 
//      are evaluated STATICALLY at elaboration time when the condition
//      involves only genvars and parameters. The synthesizer unrolls them.