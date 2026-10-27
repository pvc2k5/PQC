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
 * Description  : Provides the BFU Barrett reduction datapath.
 */
// Original author: Xavier Carril

module bfu_barrett (
  input logic clk_i,
  input logic rstn_i,
  input logic flush_i,        // Flush signal to clear the pipeline
  input logic validSrc_i,     // Valid Operands
  input logic [31:0] src_i,          // Source (16+16 bits)
  output logic validResult_o,  // Valid result
  output logic [31:0] result_o        // Result (16+16 bits)
);

  logic valid;
  logic [15:0] srcA;
  logic [15:0] srcB;
  logic [31:0] result;

  always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
      valid <= 1'b0;
      srcB <= '0;
      srcA <= '0;
    end else begin
      valid <= validSrc_i;
      srcB <= src_i[31:16];
      srcA <= src_i[15:0];
    end
  end

  barrett_reduce barrett_B (
    .src_i   (srcB),
    .result_o(result[31:16])
  );

  barrett_reduce barrett_A (
    .src_i   (srcA),
    .result_o(result[15:0])
  );

  assign result_o = result;
  assign validResult_o = valid & (~flush_i);

endmodule
