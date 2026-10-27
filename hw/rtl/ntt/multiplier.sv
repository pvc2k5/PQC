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
 * Description  : Implements the pipelined signed multiplier used by the BFU.
 */
// Original author: Xavier Carril

module multiplier #(
    parameter A_WIDTH = 16,
    parameter B_WIDTH = 32,
    parameter PROD_WIDTH = A_WIDTH + B_WIDTH
) (
  input logic clk_i,          // Clock
  input logic rstn_i,         // Active-low reset
  input logic validSrc_i,     // Valid inputs
  input logic sign_i,         // Signed(1) or Unsigned(0)
  input logic [A_WIDTH-1:0] srcA_i,         // A operand (signed/unsigned)
  input logic signed [B_WIDTH-1:0] srcB_i,         // B Operand (always signed)
  output logic validResult_o,  // Valid result indicator
  output logic signed [PROD_WIDTH-1:0] result_o        // Signed product
);

  // A extended by one bit so the same signed multiplier handles both modes.
  logic signed [A_WIDTH:0] a_ext;

  assign a_ext = sign_i ? {srcA_i[A_WIDTH-1], srcA_i} : {1'b0, srcA_i};

  logic signed [A_WIDTH+B_WIDTH:0] prod;

  assign prod = a_ext * srcB_i;

  // Product register is only loaded on valid data; the valid flag follows.
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o <= '0;
      validResult_o <= 1'b0;
    end else begin
      validResult_o <= validSrc_i;
      if (validSrc_i) result_o <= prod[PROD_WIDTH-1:0];
    end
  end

endmodule
