/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Canonical and pipelined Barrett reduction for ML-KEM residues.
 */

module canonical_reduce (
  input logic [15:0] data_i,
  output logic [11:0] data_o
);

  logic [15:0] centered_w;
  logic signed [16:0] corrected_w;
  barrett_reduce u_barrett (
    .src_i   (data_i),
    .result_o(centered_w)
  );

  always_comb begin
    corrected_w = {centered_w[15], centered_w};
    if (corrected_w < 0) corrected_w = corrected_w + 17'sd3329;
    if (corrected_w >= 17'sd3329) corrected_w = corrected_w - 17'sd3329;
    data_o = corrected_w[11:0];
  end
endmodule

// The rounded Barrett quotient is corrected into the canonical range.
// Flush clears valid state while the data pipeline drains.
module canonical_reduce_pipe (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,
  input logic valid_i,
  input logic [15:0] data_i,
  output logic valid_o,
  output logic [11:0] data_o
);
  logic [5:0] valid_w;
  logic signed [15:0] a0_w;
  logic signed [15:0] a1_w;
  logic signed [15:0] a2_w;
  logic signed [15:0] a3_w;
  (* use_dsp = "yes" *)logic signed [31:0] product_w;
  logic signed [31:0] rounded_w;
  logic signed [5:0] quotient_w;
  (* use_dsp = "no" *)logic signed [21:0] multiple_w;
  logic signed [21:0] residue_w;

  assign rounded_w = product_w + 32'sd33554432;
  assign valid_o = valid_w[5] && !flush_i && rst_ni;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      valid_w <= 0;
      a0_w <= 0;
      a1_w <= 0;
      a2_w <= 0;
      a3_w <= 0;
      product_w <= 0;
      quotient_w <= 0;
      multiple_w <= 0;
      residue_w <= 0;
      data_o <= 0;
    end else begin
      valid_w <= flush_i ? 6'd0 : {valid_w[4:0], valid_i};
      a0_w <= $signed(data_i);
      a1_w <= a0_w;
      product_w <= a0_w * 16'sd20159;
      a2_w <= a1_w;
      quotient_w <= rounded_w >>> 26;
      a3_w <= a2_w;
      multiple_w <= quotient_w * 16'sd3329;
      residue_w <= a3_w - multiple_w;
      data_o <= residue_w[21] ? residue_w + 22'sd3329 : residue_w;
    end
  end
endmodule
