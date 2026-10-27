// Copyright 2026 Barcelona Supercomputing Center (BSC)
//
// Licensed under the Solderpad Hardware License v 2.1 (the "License");
// you may not use this file except in compliance with the License, or,
// at your option, the Apache License version 2.0.
// You may obtain a copy of the License at
//
//     https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Selects the Kyber or Dilithium modular reduction datapath.
 */
// Original author: Xavier Carril

module bfu_modred (
  input logic clk_i,
  input logic rstn_i,
  input logic flush_i,        // Flush signal to clear the pipeline
  input logic validSrc_i,     // Valid Operands
  input logic selKD_i,        // Select Kyber(1) or Dilithium(0)
  input logic [63:0] src_i,          // Source (32+32 bits)
  output logic validResult_o,  // Valid result
  output logic [31:0] result_o        // Result (16+16 bits)
);

  logic valid;
  logic selKD;
  logic [31:0] srcA;
  logic [31:0] srcB;
  logic [31:0] result_kyber;
  logic [31:0] result_dilithium;

  always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
      valid <= 1'b0;
      selKD <= 1'b0;
      srcB <= '0;
      srcA <= '0;
    end else begin
      valid <= validSrc_i;
      selKD <= selKD_i;
      srcB <= src_i[63:32];
      srcA <= src_i[31:0];
    end
  end

  // Board timing adaptation (2026-10-17): split the exact legacy Montgomery
  // expression across two additional stages. Public ports and signed raw
  // results are unchanged. All products are constant shift/add LUT logic.
  logic signed [15:0] tA_w;
  logic signed [15:0] tB_w;
  logic signed [31:0] qA_w;
  logic signed [31:0] qB_w;
  logic signed [31:0] a1_w;
  logic signed [31:0] b1_w;
  logic signed [31:0] a2_w;
  logic signed [31:0] b2_w;
  logic signed [31:0] tA_ext_w;
  logic signed [31:0] tB_ext_w;
  logic signed [31:0] diffA_w;
  logic signed [31:0] diffB_w;
  logic valid1_w;
  logic valid2_w;

  assign tA_ext_w = {{16{tA_w[15]}}, tA_w};
  assign tB_ext_w = {{16{tB_w[15]}}, tB_w};
  assign diffA_w = a2_w - qA_w;
  assign diffB_w = b2_w - qB_w;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      tA_w <= 0;
      tB_w <= 0;
      qA_w <= 0;
      qB_w <= 0;
      a1_w <= 0;
      b1_w <= 0;
      a2_w <= 0;
      b2_w <= 0;
      valid1_w <= 0;
      valid2_w <= 0;
    end else begin
      tA_w <= srcA[15:0] - (srcA[15:0] << 11) - (srcA[15:0] << 10) - (srcA[15:0] << 8);
      tB_w <= srcB[15:0] - (srcB[15:0] << 11) - (srcB[15:0] << 10) - (srcB[15:0] << 8);
      qA_w <= (tA_ext_w <<< 11) + (tA_ext_w <<< 10) + (tA_ext_w <<< 8) + tA_ext_w;
      qB_w <= (tB_ext_w <<< 11) + (tB_ext_w <<< 10) + (tB_ext_w <<< 8) + tB_ext_w;
      a1_w <= srcA;
      b1_w <= srcB;
      a2_w <= a1_w;
      b2_w <= b1_w;
      valid1_w <= valid && !flush_i;
      valid2_w <= valid1_w && !flush_i;
    end
  end

  assign result_kyber = {diffB_w[31:16], diffA_w[31:16]};

  // FPGA port: Kyber-only Montgomery reduction for ML-KEM
  assign result_o = result_kyber;
  assign validResult_o = valid2_w & (~flush_i);

endmodule
