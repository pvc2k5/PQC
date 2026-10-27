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
 * Description  : Computes 32-bit addition and subtraction for the BFU.
 */
// Original author: Xavier Carril

module adder_32bit (
  input logic selKD_i,  // Select Kyber(1) or Dilithium(0) operation
  input logic [31:0] srcA_i,   // Source (16+16 bits for Kyber, 32 bits for Dilithium)
  input logic [31:0] srcB_i,   // Source (16+16 bits for Kyber, 32 bits for Dilithium)
  output logic [31:0] result_o  // Result (16+16 bits for Kyber, 32 bits for Dilithium)
);

  logic [15:0] C1;
  logic [16:0] C2;
  logic carry;
  logic cin;

  assign {carry, C1} = srcA_i[15:0] + srcB_i[15:0];
  assign cin = (selKD_i) ? 1'b0 : carry;
  assign C2 = srcA_i[31:16] + srcB_i[31:16] + {15'b0, cin};

  assign result_o = {C2[15:0], C1[15:0]};

endmodule

module substraction_32bit (
  input logic selKD_i,  // Select Kyber(1) or Dilithium(0) operation
  input logic [31:0] srcA_i,   // Source (16+16 bits for Kyber, 32 bits for Dilithium)
  input logic [31:0] srcB_i,   // Source (16+16 bits for Kyber, 32 bits for Dilithium)
  output logic [31:0] result_o  // Result (16+16 bits for Kyber, 32 bits for Dilithium)
);
  logic [16:0] C1;
  logic [16:0] C2;
  logic carry;
  logic cin;

  assign C1 = {1'b1, srcA_i[15:0]} - {1'b0, srcB_i[15:0]};
  assign carry = C1[16];
  assign cin = (selKD_i) ? 1'b0 : !carry;
  assign C2 = srcA_i[31:16] - srcB_i[31:16] - {15'b0, cin};

  assign result_o = {C2[15:0], C1[15:0]};

endmodule
