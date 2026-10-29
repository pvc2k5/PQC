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
 * Description  : Configures the BFU for the Kyber arithmetic mode.
 */

module bfu_kyber (
  input logic clk_i,
  input logic rstn_i,
  input logic flush_i,
  input logic selNTT_i,       // 1: NTT, 0: InvNTT
  input logic validSrc_i,
  input logic fqmul_i,
  input logic hilo_i,
  input logic [31:0] srcA_i,
  input logic [31:0] srcB_i,
  input logic [15:0] zeta_addr_i,
  output logic validResult_o,
  output logic [31:0] resultA_o,
  output logic [31:0] resultB_o
);

  bfu_top u_bfu_top (
    .clk_i        (clk_i),
    .rstn_i       (rstn_i),
    .flush_i      (flush_i),
    .selKD_i      (1'b1),           // Kyber mode
    .selNTT_i     (selNTT_i),
    .validSrc_i   (validSrc_i),
    .fqmul_i      (fqmul_i),
    .hilo_i       (hilo_i),
    .srcA_i       (srcA_i),
    .srcB_i       (srcB_i),
    .zeta_addr_i  (zeta_addr_i),
    .we_zeta_i    (1'b0),
    .validResult_o(validResult_o),
    .resultA_o    (resultA_o),
    .resultB_o    (resultB_o)
  );

endmodule
