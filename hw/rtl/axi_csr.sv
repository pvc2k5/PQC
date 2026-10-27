/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : AXI4-Lite control and status registers, seed storage, and interrupt generation.
 */

module axi_csr (
  input logic s_axi_aclk,
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
  output logic irq_o,
  input logic busy_i,
  input logic done_i,
  input logic error_i,
  input logic [1:0] error_code_i,
  input logic [31:0] cycles_i,
  output logic start_o,
  output logic soft_rst_o,
  output logic results_valid_o,
  output logic [255:0] d_o,
  output logic [255:0] z_o,
  output logic [31:0] watchdog_o,
  output logic out_rd_en_o,
  output logic [9:0] out_rd_addr_o,
  input logic [31:0] out_rd_data_i
);

  logic aw_pending_w;
  logic w_pending_w;
  logic read_pending_w;
  logic [15:0] awaddr_w;
  logic [31:0] wdata_w;
  logic [3:0] wstrb_w;
  logic [255:0] d_w;
  logic [255:0] z_w;
  logic [15:0] seed_valid_w;
  logic [31:0] watchdog_w;
  logic ie_w;
  logic done_w;
  logic error_w;
  logic results_valid_w;
  logic [1:0] error_code_w;
  logic [1:0] write_resp_w;
  logic commit_w;
  logic read_accept_w;
  logic write_ok_w;
  logic [31:0] read_data_w;
  logic [1:0] read_resp_w;
  logic output_read_w;

  assign s_axi_awready = s_axi_aresetn && !aw_pending_w && !s_axi_bvalid;
  assign s_axi_wready = s_axi_aresetn && !w_pending_w && !s_axi_bvalid;
  assign s_axi_arready = s_axi_aresetn && !s_axi_rvalid && !read_pending_w;
  assign commit_w = aw_pending_w && w_pending_w && !s_axi_bvalid;
  assign read_accept_w = s_axi_arvalid && s_axi_arready;

  always_comb begin
    write_resp_w = 2'b00;
    if (awaddr_w[1:0] != 0) write_resp_w = 2'b10;
    else
      case (awaddr_w)
        16'h0000:
        if (wstrb_w[0] && wdata_w[0] && !wdata_w[1] && (busy_i || seed_valid_w != 16'hffff))
          write_resp_w = 2'b10;
        16'h0004: ;
        16'h000c: if (busy_i || (wstrb_w != 0 && wstrb_w != 15)) write_resp_w = 2'b10;
        default: begin
          if (awaddr_w >= 16'h0010 && awaddr_w <= 16'h004c) begin
            if (busy_i || (wstrb_w != 0 && wstrb_w != 15)) write_resp_w = 2'b10;
          end else write_resp_w = 2'b10;
        end
      endcase
  end

  assign write_ok_w = commit_w && write_resp_w == 0;
  // CTRL reset is always legal, even with incomplete seeds or a busy core.
  // Decode commands directly so seed checks in BRESP cannot delay abort masking.
  // Both pulses retain the original write-commit edge and reset priority.
  assign soft_rst_o = s_axi_aresetn && commit_w && awaddr_w == 16'h0000 && wstrb_w[0] && wdata_w[1];
  assign start_o = s_axi_aresetn && commit_w && awaddr_w == 16'h0000 && wstrb_w[0] && wdata_w[0] &&
      !wdata_w[1] && !busy_i && seed_valid_w == 16'hffff;
  // Forward sticky event IRQ and the software-programmed transaction inputs.
  assign irq_o = ie_w && (done_w || error_w);
  assign d_o = d_w;
  assign z_o = z_w;
  assign watchdog_o = watchdog_w;
  assign results_valid_o = results_valid_w;

  always_comb begin
    read_data_w = 0;
    read_resp_w = 0;
    output_read_w = 0;
    if (s_axi_araddr[1:0] != 0) read_resp_w = 2'b10;
    else
      case (s_axi_araddr)
        16'h0000: read_data_w = {29'd0, ie_w, 2'd0};
        16'h0004: read_data_w = {28'd0, results_valid_w, error_w, done_w, busy_i};
        16'h0008: read_data_w = cycles_i;
        16'h000c: read_data_w = watchdog_w;
        16'h0050: read_data_w = {30'd0, error_code_w};
        16'h0054: read_data_w = {16'd0, seed_valid_w};
        default: begin
          if (s_axi_araddr >= 16'h0010 && s_axi_araddr <= 16'h002c)
            read_data_w = d_w[32*((s_axi_araddr-16'h0010)>>2)+:32];
          else if (s_axi_araddr >= 16'h0030 && s_axi_araddr <= 16'h004c)
            read_data_w = z_w[32*((s_axi_araddr-16'h0030)>>2)+:32];
          else if (s_axi_araddr >= 16'h1000 && s_axi_araddr <= 16'h1ffc) begin
            if (!results_valid_w || start_o || soft_rst_o || error_i) read_resp_w = 2'b10;
            else if (s_axi_araddr < 16'h1e00) output_read_w = 1;
          end else read_resp_w = 2'b10;
        end
      endcase
  end

  assign out_rd_en_o = read_accept_w && output_read_w;
  assign out_rd_addr_o = s_axi_araddr[11:2];

  always_ff @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
    if (!s_axi_aresetn) begin
      aw_pending_w <= 0;
      w_pending_w <= 0;
      read_pending_w <= 0;
      awaddr_w <= 0;
      wdata_w <= 0;
      wstrb_w <= 0;
      s_axi_bvalid <= 0;
      s_axi_bresp <= 0;
      s_axi_rvalid <= 0;
      s_axi_rresp <= 0;
      s_axi_rdata <= 0;
      d_w <= 0;
      z_w <= 0;
      seed_valid_w <= 0;
      watchdog_w <= 32'h00100000;
      ie_w <= 0;
      done_w <= 0;
      error_w <= 0;
      results_valid_w <= 0;
      error_code_w <= 0;
    end else begin
      if (s_axi_awvalid && s_axi_awready) begin
        awaddr_w <= s_axi_awaddr;
        aw_pending_w <= 1;
      end
      if (s_axi_wvalid && s_axi_wready) begin
        wdata_w <= s_axi_wdata;
        wstrb_w <= s_axi_wstrb;
        w_pending_w <= 1;
      end
      if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
      if (commit_w) begin
        aw_pending_w <= 0;
        w_pending_w <= 0;
        s_axi_bvalid <= 1;
        s_axi_bresp <= write_resp_w;
      end
      if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
      if (read_accept_w) begin
        if (output_read_w) read_pending_w <= 1;
        else begin
          s_axi_rvalid <= 1;
          s_axi_rresp <= read_resp_w;
          s_axi_rdata <= read_data_w;
        end
      end
      if (read_pending_w) begin
        read_pending_w <= 0;
        s_axi_rvalid <= 1;
        s_axi_rresp <= 0;
        s_axi_rdata <= out_rd_data_i;
      end
      if (write_ok_w) begin
        case (awaddr_w)
          16'h0000: if (wstrb_w[0]) ie_w <= wdata_w[2];
          16'h0004:
          if (wstrb_w[0]) begin
            if (wdata_w[1]) done_w <= 0;
            if (wdata_w[2]) begin
              error_w <= 0;
              error_code_w <= 0;
            end
          end
          16'h000c: if (wstrb_w == 15) watchdog_w <= wdata_w;
          default:
          if (wstrb_w == 15) begin
            if (awaddr_w >= 16'h0010 && awaddr_w <= 16'h002c) begin
              d_w[32*((awaddr_w-16'h0010)>>2)+:32] <= wdata_w;
              seed_valid_w[(awaddr_w-16'h0010)>>2] <= 1;
            end else if (awaddr_w >= 16'h0030 && awaddr_w <= 16'h004c) begin
              z_w[32*((awaddr_w-16'h0030)>>2)+:32] <= wdata_w;
              seed_valid_w[8+((awaddr_w-16'h0030)>>2)] <= 1;
            end
          end
        endcase
      end
      // Event set wins over software W1C; reset/start invalidation wins overall.
      if (done_i) begin
        done_w <= 1;
        results_valid_w <= 1;
      end
      if (error_i) begin
        error_w <= 1;
        error_code_w <= error_code_i;
        results_valid_w <= 0;
      end
      if (start_o || soft_rst_o) begin
        done_w <= 0;
        error_w <= 0;
        error_code_w <= 0;
        results_valid_w <= 0;
        seed_valid_w <= 0;
      end
      if (soft_rst_o) begin
        d_w <= 0;
        z_w <= 0;
      end
    end
  end
endmodule
