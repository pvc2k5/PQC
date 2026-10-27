/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : AXI4-Lite wrapper for the ML-KEM-768 key-generation core.
 */

module mlkem_keygen_axi (
  (* X_INTERFACE_INFO="xilinx.com:signal:clock:1.0 s_axi_aclk CLK", X_INTERFACE_PARAMETER="ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
  input logic s_axi_aclk,
  (* X_INTERFACE_INFO="xilinx.com:signal:reset:1.0 s_axi_aresetn RST", X_INTERFACE_PARAMETER="POLARITY ACTIVE_LOW" *)
  input logic s_axi_aresetn,
  input logic [15:0] s_axi_awaddr,
  input logic s_axi_awvalid,
  output logic s_axi_awready,
  input logic [31:0] s_axi_wdata,
  input logic [3:0] s_axi_wstrb,
  input logic s_axi_wvalid,
  output logic s_axi_wready,
  output logic [1:0] s_axi_bresp,
  output logic s_axi_bvalid,
  input logic s_axi_bready,
  input logic [15:0] s_axi_araddr,
  input logic s_axi_arvalid,
  output logic s_axi_arready,
  output logic [31:0] s_axi_rdata,
  output logic [1:0] s_axi_rresp,
  output logic s_axi_rvalid,
  input logic s_axi_rready,
  output logic irq_o
);

  logic busy_w;
  logic done_w;
  logic error_w;
  logic start_w;
  logic soft_rst_w;
  logic results_valid_w;
  logic rd_en_w;
  logic [1:0] error_code_w;
  logic [31:0] cycles_w;
  logic [31:0] watchdog_w;
  logic [31:0] rd_data_w;
  logic [255:0] d_w;
  logic [255:0] z_w;
  logic [9:0] rd_addr_w;
  axi_csr u_csr (
    .*,
    .busy_i         (busy_w),
    .done_i         (done_w),
    .error_i        (error_w),
    .error_code_i   (error_code_w),
    .cycles_i       (cycles_w),
    .start_o        (start_w),
    .soft_rst_o     (soft_rst_w),
    .results_valid_o(results_valid_w),
    .d_o            (d_w),
    .z_o            (z_w),
    .watchdog_o     (watchdog_w),
    .out_rd_en_o    (rd_en_w),
    .out_rd_addr_o  (rd_addr_w),
    .out_rd_data_i  (rd_data_w)
  );
  mlkem_keygen_core u_core (
    .clk_i        (s_axi_aclk),
    .rst_ni       (s_axi_aresetn),
    .start_i      (start_w),
    .soft_rst_i   (soft_rst_w),
    .d_i          (d_w),
    .z_i          (z_w),
    .watchdog_i   (watchdog_w),
    .busy_o       (busy_w),
    .done_o       (done_w),
    .error_o      (error_w),
    .error_code_o (error_code_w),
    .cycles_o     (cycles_w),
    .cpu_rd_en_i  (rd_en_w),
    .cpu_rd_addr_i(rd_addr_w),
    .cpu_rd_data_o(rd_data_w)
  );
endmodule
