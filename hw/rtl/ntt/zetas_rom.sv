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
 * Description  : Provides the Kyber NTT twiddle factors by address.
 */
// Original author: Xavier Carril

module zetas_rom #(
    parameter int DATA_WIDTH = 32,  // Data width (32-bit values)
    parameter int ADDR_WIDTH = 8    // Address width (memory of 2^ADDR_WIDTH, here 256 locations)
) (
  input logic clk_i,     // Clock signal
  input logic rstn_i,    // Reset signal
  input logic valid_i,   // Valid data input signal
  input logic selKD_i,   // Select Kyber(1) or Dilithium(0)
  input logic selNTT_i,  // Select NTT(1) or InvNTT(0)
  input logic [ADDR_WIDTH-1:0] addrX_i,   // Address input (Only Kyber)
  input logic [ADDR_WIDTH-1:0] addrY_i,   // Address input
  output logic signed [DATA_WIDTH-1:0] data_o     // Signed 16-bit data output
);

  logic validOut;
  logic signed [DATA_WIDTH-1:0] dataOut;

  // FPGA port: ROM contents come from zetas_kyber_pkg (generated from zetas_kyber.hex)
  // instead of $readmemh with an absolute path.
  logic selKD;
  logic selNTT;
  localparam logic signed [15:0] kyber_rom_array[0:127] = zetas_kyber_pkg::KYBER_ZETAS;
  logic [ADDR_WIDTH-1:0] addrX;
  logic [ADDR_WIDTH-1:0] addrY;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      validOut <= 1'b0;
      selKD <= 1'b0;
      selNTT <= 1'b0;
      addrX <= '0;
      addrY <= '0;
    end else begin
      validOut <= valid_i;
      selKD <= selKD_i;
      selNTT <= selNTT_i;
      addrX <= addrX_i;
      addrY <= addrY_i;
    end
  end

  // FPGA port: Dilithium is not supported (outputs 0); Kyber table is a package constant.
  assign dataOut = (selKD) ? {kyber_rom_array[addrX[6:0]], kyber_rom_array[addrY[6:0]]} : '0;

  assign data_o = (validOut) ? dataOut : '0;

endmodule
