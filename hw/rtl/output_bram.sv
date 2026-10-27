/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Dual-port output memory for encoded public and private keys.
 */

module output_bram (
  input logic clk_i,
  input logic wr_en_i,
  input logic [9:0] wr_addr_i,
  input logic [31:0] wr_data_i,
  input logic rd_en_i,
  input logic [9:0] rd_addr_i,
  output logic [31:0] rd_data_o
);

  logic [31:0] mem_w[0:1023];

  always_ff @(posedge clk_i) begin
    if (wr_en_i) mem_w[wr_addr_i] <= wr_data_i;
    if (rd_en_i) rd_data_o <= mem_w[rd_addr_i];
  end
endmodule
