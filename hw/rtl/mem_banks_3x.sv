/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Three dual-port coefficient banks for sampler, PAU, and CPU access.
 */

module mem_banks_3x #(
    parameter int DATA_W = 32,
    parameter int ADDR_W = 10,
    parameter int NUM_BANKS = 3,
    parameter int POLY_WORDS = 128
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [NUM_BANKS-1:0] bankA_en_i,
  input logic [NUM_BANKS-1:0] bankA_we_i,
  input logic [NUM_BANKS-1:0][ADDR_W-1:0] bankA_addr_i,
  input logic [NUM_BANKS-1:0][DATA_W-1:0] bankA_din_i,
  output logic [NUM_BANKS-1:0][DATA_W-1:0] bankA_dout_o,
  input logic [NUM_BANKS-1:0] bankB_en_i,
  input logic [NUM_BANKS-1:0] bankB_we_i,
  input logic [NUM_BANKS-1:0][ADDR_W-1:0] bankB_addr_i,
  input logic [NUM_BANKS-1:0][DATA_W-1:0] bankB_din_i,
  output logic [NUM_BANKS-1:0][DATA_W-1:0] bankB_dout_o
);

  // Independent arrays and clocked ports match the Vivado dual-port template.
  // No reset of RAM content or output registers is required by the contract.
  for (genvar bank = 0; bank < NUM_BANKS; bank = bank + 1) begin : g_bank
    (* ram_style="block" *) logic [DATA_W-1:0] mem_w[0:(1<<ADDR_W)-1];
    always @(posedge clk_i) begin
      if (bankA_en_i[bank]) begin
        if (bankA_we_i[bank]) mem_w[bankA_addr_i[bank]] <= bankA_din_i[bank];
        else bankA_dout_o[bank] <= mem_w[bankA_addr_i[bank]];
      end
    end
    always @(posedge clk_i) begin
      if (bankB_en_i[bank]) begin
        if (bankB_we_i[bank]) mem_w[bankB_addr_i[bank]] <= bankB_din_i[bank];
        else bankB_dout_o[bank] <= mem_w[bankB_addr_i[bank]];
      end
    end
  end
endmodule
