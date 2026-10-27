/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Key-generation controller coordinating SHA3, sampling, NTT, and packing.
 */

module control_unit (
  input logic clk_i,
  input logic rst_ni,
  input logic start_i,
  input logic soft_rst_i,
  input logic [255:0] d_i,
  input logic [255:0] z_i,
  input logic [31:0] watchdog_i,
  input logic sha_busy_i,
  input logic sha_done_i,
  input logic rho_valid_i,
  input logic [3:0] sha_job_i,
  input logic sampler_busy_i,
  input logic sampler_done_i,
  input logic pau_busy_i,
  input logic pau_done_i,
  input logic tc_busy_i,
  input logic tc_done_i,
  input logic tc_error_i,
  input logic hash_done_i,
  input logic [255:0] hash_digest_i,
  output logic busy_o,
  output logic done_o,
  output logic error_o,
  output logic [1:0] error_code_o,
  output logic [31:0] cycles_o,
  output logic [3:0] phase_o,
  output logic [1:0] index_o,
  output logic sha_start_o,
  output logic sampler_start_o,
  output logic pau_start_o,
  output logic tc_start_o,
  output logic hash_start_o,
  output logic abort_o,
  output logic mask_o,
  output logic [255:0] d_work_o,
  output logic [255:0] z_work_o,
  output logic [255:0] hash_work_o
);

  localparam logic [3:0] IDLE = 0, SAMPLE = 1, NTT_S = 2, NTT_E = 3, ROW = 4, PACK_EK = 5,
      PACK_DK = 6, COPY_EK = 7, HASH_EK = 8, SUFFIX = 9, PUBLISH = 10, ABORT = 11;
  logic [3:0] phase_w;
  logic [1:0] index_w;
  logic issued_w;
  logic poly_issued_w;
  logic sha_done_seen_w;
  logic timeout_w;
  logic fault_w;
  logic [4:0] expected_job_w;
  logic [4:0] poly_count_w;
  logic [31:0] cycles_w;
  logic [31:0] reg_watchdog_early;
  logic reg_watchdog_due;
  logic watchdog_enabled_w;
  logic [255:0] d_work_w;
  logic [255:0] z_work_w;
  logic [255:0] hash_work_w;

  assign busy_o = phase_w != IDLE;
  // Predict the W-1 deadline one edge early. The registered predicate keeps
  // the wide comparison off the same-cycle abort path without delaying abort.
  assign
      timeout_w = (phase_w != IDLE && phase_w != ABORT) && watchdog_enabled_w && reg_watchdog_due;
  // Fault/reset outputs mask child requests on the detection edge.
  assign fault_w = (phase_w != IDLE && phase_w != ABORT) && (timeout_w || tc_error_i);
  assign error_o = rst_ni && !soft_rst_i && fault_w;
  assign error_code_o = tc_error_i ? 2'd2 : 2'd1;
  assign abort_o = rst_ni && (soft_rst_i || fault_w);
  assign mask_o = !rst_ni || abort_o || phase_w == ABORT;
  assign done_o = rst_ni && !mask_o && phase_w == PUBLISH;
  assign phase_o = phase_w;
  assign index_o = index_w;
  assign cycles_o = cycles_w;
  assign d_work_o = d_work_w;
  assign z_work_o = z_work_w;
  assign hash_work_o = hash_work_w;
  assign sha_start_o = phase_w == SAMPLE && !issued_w && !mask_o;
  assign sampler_start_o = phase_w == SAMPLE && !poly_issued_w && !sampler_busy_i && sha_busy_i &&
      expected_job_w < 16 && {1'b0, sha_job_i} == expected_job_w && !mask_o;

  assign pau_start_o = (phase_w == NTT_S || phase_w == NTT_E || phase_w == ROW) && !issued_w &&
      !mask_o;

  assign tc_start_o = (phase_w == PACK_EK || phase_w == PACK_DK || phase_w == COPY_EK || phase_w ==
                       SUFFIX) && !issued_w && !mask_o && (phase_w != PACK_EK || rho_valid_i);

  assign hash_start_o = phase_w == HASH_EK && !issued_w && !mask_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      phase_w <= IDLE;
      index_w <= 0;
      issued_w <= 0;
      poly_issued_w <= 0;
      sha_done_seen_w <= 0;
      expected_job_w <= 1;
      poly_count_w <= 0;
      cycles_w <= 0;
      d_work_w <= 0;
      z_work_w <= 0;
      hash_work_w <= 0;
      reg_watchdog_early <= 0;
      reg_watchdog_due <= 0;
      watchdog_enabled_w <= 0;
    end else if (abort_o) begin
      reg_watchdog_due <= 1'b0;
      phase_w <= ABORT;
      issued_w <= 0;
      poly_issued_w <= 0;
      sha_done_seen_w <= 0;
      expected_job_w <= 1;
      poly_count_w <= 0;
      d_work_w <= 0;
      z_work_w <= 0;
      hash_work_w <= 0;
      if (soft_rst_i) cycles_w <= 0;
      else if (cycles_w != 32'hffffffff) cycles_w <= cycles_w + 1'b1;
    end else begin
      if (phase_w != IDLE && phase_w != ABORT && cycles_w != 32'hffffffff)
        cycles_w <= cycles_w + 1'b1;
      // When C reaches W-2, the next registered C is W-1 and abort is due.
      // W=0 disables prediction; W=1 is handled at acceptance below.
      if (phase_w != IDLE && phase_w != ABORT)
        reg_watchdog_due <= watchdog_enabled_w && (cycles_w == reg_watchdog_early);
      case (phase_w)
        IDLE:
        if (start_i) begin
          reg_watchdog_early <= watchdog_i - 32'd2;
          reg_watchdog_due <= watchdog_i == 32'd1;
          watchdog_enabled_w <= watchdog_i != 0;
          d_work_w <= d_i;
          z_work_w <= z_i;
          hash_work_w <= 0;
          cycles_w <= 0;
          phase_w <= SAMPLE;
          issued_w <= 0;
          poly_issued_w <= 0;
          sha_done_seen_w <= 0;
          expected_job_w <= 1;
          poly_count_w <= 0;
          index_w <= 0;
        end
        SAMPLE: begin
          if (sha_start_o) issued_w <= 1;
          if (sha_done_i) sha_done_seen_w <= 1;
          if (sampler_start_o) poly_issued_w <= 1;
          if (sampler_done_i) begin
            poly_issued_w <= 0;
            poly_count_w <= poly_count_w + 1'b1;
            expected_job_w <= expected_job_w + 1'b1;
          end
          if (sha_done_seen_w && poly_count_w == 15 && !sampler_busy_i) begin
            phase_w <= NTT_S;
            issued_w <= 0;
            index_w <= 0;
          end
        end
        NTT_S, NTT_E, ROW: begin
          if (pau_start_o) issued_w <= 1;
          if (pau_done_i) begin
            issued_w <= 0;
            if (index_w < 2) index_w <= index_w + 1'b1;
            else begin
              index_w <= 0;
              phase_w <= phase_w + 1'b1;
            end
          end
        end
        PACK_EK, PACK_DK, COPY_EK, SUFFIX: begin
          if (tc_start_o) issued_w <= 1;
          if (tc_done_i) begin
            issued_w <= 0;
            phase_w <= phase_w + 1'b1;
          end
        end
        HASH_EK: begin
          if (hash_start_o) issued_w <= 1;
          if (hash_done_i) begin
            hash_work_w <= hash_digest_i;
            issued_w <= 0;
            phase_w <= SUFFIX;
          end
        end
        PUBLISH: begin
          phase_w <= IDLE;
          d_work_w <= 0;
          z_work_w <= 0;
          hash_work_w <= 0;
        end
        ABORT:   if (!sha_busy_i && !sampler_busy_i && !pau_busy_i && !tc_busy_i) phase_w <= IDLE;
        default: phase_w <= IDLE;
      endcase
    end
  end
endmodule
