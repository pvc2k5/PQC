/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : ML-KEM-768 key-generation datapath and command integration.
 */

module mlkem_keygen_core (
  input logic clk_i,
  input logic rst_ni,
  input logic start_i,
  input logic soft_rst_i,
  input logic [255:0] d_i,
  input logic [255:0] z_i,
  input logic [31:0] watchdog_i,
  output logic busy_o,
  output logic done_o,
  output logic error_o,
  output logic [1:0] error_code_o,
  output logic [31:0] cycles_o,
  input logic cpu_rd_en_i,
  input logic [9:0] cpu_rd_addr_i,
  output logic [31:0] cpu_rd_data_o
);

  logic [3:0] phase_w;
  logic [3:0] job_w;
  logic [1:0] index_w;
  logic [1:0] job_type_w;
  logic [1:0] pau_cmd_w;
  logic [1:0] tc_cmd_w;
  logic [2:0] pau_slot_w;
  logic sha_start_w;
  logic poly_start_w;
  logic pau_start_w;
  logic tc_start_w;
  logic hash_start_w;
  logic abort_w;
  logic mask_w;
  logic tc_abort_w;
  logic sha_busy_w;
  logic sha_done_w;
  logic rho_valid_w;
  logic sampler_busy_w;
  logic sampler_done_w;
  logic pau_busy_w;
  logic pau_done_w;
  logic tc_busy_w;
  logic tc_done_w;
  logic tc_error_w;
  logic [255:0] d_work_w;
  logic [255:0] z_work_w;
  logic [255:0] hash_work_w;
  logic [255:0] rho_w;
  logic [255:0] hash_digest_w;
  logic sq_valid_w;
  logic sq_ready_w;
  logic hash_valid_w;
  logic hash_ready_w;
  logic hash_last_w;
  logic hash_done_w;
  logic [63:0] sq_data_w;
  logic [63:0] hash_data_w;
  logic sampler_we_w;
  logic pau_en_w;
  logic pau_we_w;
  logic pau_a_en_w;
  logic pau_a_we_w;
  logic tc_en_w;
  logic tc_out_we_w;
  logic tc_rd_en_w;
  logic [1:0] sampler_bank_w;
  logic [1:0] pau_bank_w;
  logic [1:0] pau_a_bank_w;
  logic [1:0] tc_bank_w;
  logic [9:0] sampler_addr_w;
  logic [9:0] pau_addr_w;
  logic [9:0] pau_a_addr_w;
  logic [9:0] tc_addr_w;
  logic [9:0] tc_out_addr_w;
  logic [9:0] tc_rd_addr_w;
  logic [31:0] sampler_data_w;
  logic [31:0] pau_data_w;
  logic [31:0] pau_rdata_w;
  logic [31:0] pau_a_rdata_w;
  logic [31:0] pau_a_data_w;
  logic [31:0] tc_rdata_w;
  logic [31:0] tc_out_data_w;
  logic [2:0] bankA_en_w;
  logic [2:0] bankA_we_w;
  logic [2:0] bankB_en_w;
  logic [2:0] bankB_we_w;
  logic [2:0][9:0] bankA_addr_w;
  logic [2:0][9:0] bankB_addr_w;
  logic [2:0][31:0] bankA_din_w;
  logic [2:0][31:0] bankA_dout_w;
  logic [2:0][31:0] bankB_din_w;
  logic [2:0][31:0] bankB_dout_w;
  logic [1:0] readA_bank_w;
  logic [1:0] readB_bank_w;
  logic out_rd_en_w;
  logic out_we_w;
  logic [9:0] out_rd_addr_w;
  logic [31:0] out_rd_data_w;
  typedef enum logic [2:0] {
    H_IDLE,
    H_EVEN,
    H_ODD,
    H_CAPTURE,
    H_BEAT,
    H_WAIT
  } hash_state_t;
  hash_state_t hash_state_w;
  logic [7:0] hash_beat_w;
  logic [31:0] hash_even_w;
  logic hash_rd_en_w;
  logic [9:0] hash_rd_addr_w;
  control_unit u_control (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .start_i        (start_i),
    .soft_rst_i     (soft_rst_i),
    .d_i            (d_i),
    .z_i            (z_i),
    .watchdog_i     (watchdog_i),
    .sha_busy_i     (sha_busy_w),
    .sha_done_i     (sha_done_w),
    .rho_valid_i    (rho_valid_w),
    .sha_job_i      (job_w),
    .sampler_busy_i (sampler_busy_w),
    .sampler_done_i (sampler_done_w),
    .pau_busy_i     (pau_busy_w),
    .pau_done_i     (pau_done_w),
    .tc_busy_i      (tc_busy_w),
    .tc_done_i      (tc_done_w),
    .tc_error_i     (tc_error_w),
    .hash_done_i    (hash_done_w),
    .hash_digest_i  (hash_digest_w),
    .busy_o         (busy_o),
    .done_o         (done_o),
    .error_o        (error_o),
    .error_code_o   (error_code_o),
    .cycles_o       (cycles_o),
    .phase_o        (phase_w),
    .index_o        (index_w),
    .sha_start_o    (sha_start_w),
    .sampler_start_o(poly_start_w),
    .pau_start_o    (pau_start_w),
    .tc_start_o     (tc_start_w),
    .hash_start_o   (hash_start_w),
    .abort_o        (abort_w),
    .mask_o         (mask_w),
    .d_work_o       (d_work_w),
    .z_work_o       (z_work_w),
    .hash_work_o    (hash_work_w)
  );
  sha3_subsys #(
      .ROUNDS(1)
  ) u_sha3 (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .start_i       (sha_start_w),
    .soft_rst_i    (abort_w),
    .d_i           (d_work_w),
    .busy_o        (sha_busy_w),
    .done_o        (sha_done_w),
    .job_id_o      (job_w),
    .job_type_o    (job_type_w),
    .sq_valid_o    (sq_valid_w),
    .sq_ready_i    (sq_ready_w),
    .sq_data_o     (sq_data_w),
    .sampler_done_i(sampler_done_w),
    .rho_o         (rho_w),
    .rho_valid_o   (rho_valid_w),
    .hash_start_i  (hash_start_w),
    .hash_valid_i  (hash_valid_w),
    .hash_ready_o  (hash_ready_w),
    .hash_data_i   (hash_data_w),
    .hash_keep_i   (8'hff),
    .hash_last_i   (hash_last_w),
    .hash_digest_o (hash_digest_w),
    .hash_done_o   (hash_done_w)
  );
  sampler_unit u_sampler (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .soft_rst_i    (abort_w),
    .start_poly_i  (poly_start_w),
    .job_id_i      (job_w),
    .job_type_i    (job_type_w),
    .busy_o        (sampler_busy_w),
    .sampler_done_o(sampler_done_w),
    .sq_valid_i    (sq_valid_w),
    .sq_ready_o    (sq_ready_w),
    .sq_data_i     (sq_data_w),
    .bram_we_o     (sampler_we_w),
    .bram_bank_o   (sampler_bank_w),
    .bram_addr_o   (sampler_addr_w),
    .bram_wdata_o  (sampler_data_w)
  );

  assign pau_cmd_w = phase_w == 4 ? 2'd1 : 2'd0;
  assign pau_slot_w = phase_w == 3 ? 3'd1 : 3'd0;
  pau_top u_pau (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .soft_rst_i    (abort_w),
    .pau_start_i   (pau_start_w),
    .pau_cmd_i     (pau_cmd_w),
    .pau_bank_sel_i(index_w),
    .pau_row_i     (index_w),
    .pau_slot_src_i(pau_slot_w),
    .pau_slot_dst_i(pau_slot_w),
    .pau_busy_o    (pau_busy_w),
    .pau_done_o    (pau_done_w),
    .bram_en_o     (pau_en_w),
    .bram_we_o     (pau_we_w),
    .bram_bank_o   (pau_bank_w),
    .bram_addr_o   (pau_addr_w),
    .bram_wdata_o  (pau_data_w),
    .bram_rdata_i  (pau_rdata_w),
    .bram_a_en_o   (pau_a_en_w),
    .bram_a_we_o   (pau_a_we_w),
    .bram_a_bank_o (pau_a_bank_w),
    .bram_a_addr_o (pau_a_addr_w),
    .bram_a_wdata_o(pau_a_data_w),
    .bram_a_rdata_i(pau_a_rdata_w)
  );

  assign tc_cmd_w = phase_w == 5 ? 2'd0 : phase_w == 6 ? 2'd1 : phase_w == 7 ? 2'd2 : 2'd3;
  // Error must reach the scheduler without feeding back through its own mask.
  // Top-level RAM enables are masked on the detection edge; TC resets in ABORT.
  assign tc_abort_w = soft_rst_i || phase_w == 11;
  transcoder u_tc (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .soft_rst_i      (tc_abort_w),
    .tc_start_i      (tc_start_w),
    .tc_cmd_i        (tc_cmd_w),
    .rho_i           (rho_w),
    .hash_i          (hash_work_w),
    .z_i             (z_work_w),
    .tc_busy_o       (tc_busy_w),
    .tc_done_o       (tc_done_w),
    .tc_error_o      (tc_error_w),
    .bankA_en_o      (tc_en_w),
    .bankA_bank_o    (tc_bank_w),
    .bankA_addr_o    (tc_addr_w),
    .bankA_rdata_i   (tc_rdata_w),
    .bram_out_we_o   (tc_out_we_w),
    .bram_out_addr_o (tc_out_addr_w),
    .bram_out_wdata_o(tc_out_data_w),
    .out_rd_en_o     (tc_rd_en_w),
    .out_rd_addr_o   (tc_rd_addr_w),
    .out_rd_data_i   (out_rd_data_w)
  );

  always_comb begin
    bankA_en_w = 0;
    bankA_we_w = 0;
    bankB_en_w = 0;
    bankB_we_w = 0;
    bankA_addr_w = 0;
    bankA_din_w = 0;
    bankB_addr_w = 0;
    bankB_din_w = 0;
    if (!mask_w) begin
      if (phase_w == 1 && sampler_bank_w < 3) begin
        bankA_en_w[sampler_bank_w] = sampler_we_w;
        bankA_we_w[sampler_bank_w] = sampler_we_w;
        bankA_addr_w[sampler_bank_w] = sampler_addr_w;
        bankA_din_w[sampler_bank_w] = sampler_data_w;
      end
      if ((phase_w == 2 || phase_w == 3 || phase_w == 4) && pau_bank_w < 3) begin
        bankB_en_w[pau_bank_w] = pau_en_w;
        bankB_we_w[pau_bank_w] = pau_we_w;
        bankB_addr_w[pau_bank_w] = pau_addr_w;
        bankB_din_w[pau_bank_w] = pau_data_w;
      end
      if ((phase_w == 2 || phase_w == 3 || phase_w == 4) && pau_a_bank_w < 3) begin
        bankA_en_w[pau_a_bank_w] = pau_a_en_w;
        bankA_we_w[pau_a_bank_w] = pau_a_we_w;
        bankA_addr_w[pau_a_bank_w] = pau_a_addr_w;
        bankA_din_w[pau_a_bank_w] = pau_a_data_w;
      end
      if ((phase_w == 5 || phase_w == 6) && tc_bank_w < 3) begin
        bankA_en_w[tc_bank_w] = tc_en_w;
        bankA_addr_w[tc_bank_w] = tc_addr_w;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      readA_bank_w <= 0;
      readB_bank_w <= 0;
    end else if (mask_w) begin
      readA_bank_w <= 0;
      readB_bank_w <= 0;
    end else begin
      if (tc_en_w && (phase_w == 5 || phase_w == 6)) readA_bank_w <= tc_bank_w;
      if (pau_en_w && !pau_we_w && (phase_w == 2 || phase_w == 3 || phase_w == 4))
        readB_bank_w <= pau_bank_w;
      if (pau_a_en_w && !pau_a_we_w && (phase_w == 2 || phase_w == 3 || phase_w == 4))
        readA_bank_w <= pau_a_bank_w;
    end
  end

  assign tc_rdata_w = bankA_dout_w[readA_bank_w];
  assign pau_rdata_w = bankB_dout_w[readB_bank_w];
  assign pau_a_rdata_w = bankA_dout_w[readA_bank_w];
  mem_banks_3x u_mem (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .bankA_en_i  (bankA_en_w),
    .bankA_we_i  (bankA_we_w),
    .bankA_addr_i(bankA_addr_w),
    .bankA_din_i (bankA_din_w),
    .bankA_dout_o(bankA_dout_w),
    .bankB_en_i  (bankB_en_w),
    .bankB_we_i  (bankB_we_w),
    .bankB_addr_i(bankB_addr_w),
    .bankB_din_i (bankB_din_w),
    .bankB_dout_o(bankB_dout_w)
  );

  assign hash_valid_w = hash_state_w == H_BEAT && !mask_w;
  assign hash_last_w = hash_beat_w == 147;
  assign hash_rd_en_w = (hash_state_w == H_EVEN || hash_state_w == H_ODD) && !mask_w;
  assign hash_rd_addr_w = {1'b0, hash_beat_w, 1'b0} + (hash_state_w == H_ODD ? 10'd1 : 10'd0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hash_state_w <= H_IDLE;
      hash_beat_w <= 0;
      hash_even_w <= 0;
      hash_data_w <= 0;
    end else if (mask_w || phase_w != 8) begin
      hash_state_w <= H_IDLE;
      hash_beat_w <= 0;
      hash_even_w <= 0;
      hash_data_w <= 0;
    end else if (hash_start_w) begin
      hash_state_w <= H_EVEN;
      hash_beat_w <= 0;
    end else
      case (hash_state_w)
        H_EVEN:  hash_state_w <= H_ODD;
        H_ODD: begin
          hash_even_w <= out_rd_data_w;
          hash_state_w <= H_CAPTURE;
        end
        H_CAPTURE: begin
          hash_data_w <= {out_rd_data_w, hash_even_w};
          hash_state_w <= H_BEAT;
        end
        H_BEAT:
        if (hash_ready_w) begin
          if (hash_beat_w == 147) hash_state_w <= H_WAIT;
          else begin
            hash_beat_w <= hash_beat_w + 1'b1;
            hash_state_w <= H_EVEN;
          end
        end
        default: ;
      endcase
  end

  always_comb begin
    out_rd_en_w = 0;
    out_rd_addr_w = 0;
    if (!mask_w) begin
      if (phase_w == 7) begin
        out_rd_en_w = tc_rd_en_w;
        out_rd_addr_w = tc_rd_addr_w;
      end else if (phase_w == 8) begin
        out_rd_en_w = hash_rd_en_w;
        out_rd_addr_w = hash_rd_addr_w;
      end else if (phase_w == 0) begin
        out_rd_en_w = cpu_rd_en_i;
        out_rd_addr_w = cpu_rd_addr_i;
      end
    end
  end

  assign out_we_w = tc_out_we_w && !mask_w &&
      (phase_w == 5 || phase_w == 6 || phase_w == 7 || phase_w == 9);
  output_bram u_output (
    .clk_i    (clk_i),
    .wr_en_i  (out_we_w),
    .wr_addr_i(tc_out_addr_w),
    .wr_data_i(tc_out_data_w),
    .rd_en_i  (out_rd_en_w),
    .rd_addr_i(out_rd_addr_w),
    .rd_data_o(out_rd_data_w)
  );

  assign cpu_rd_data_o = out_rd_data_w;
endmodule
