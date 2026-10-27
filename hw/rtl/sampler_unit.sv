/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : SampleNTT and CBD coefficient sampler with scratchpad writes.
 */

module sampler_unit (
  input logic clk_i,
  input logic rst_ni,
  input logic soft_rst_i,
  input logic start_poly_i,
  input logic [3:0] job_id_i,
  input logic [1:0] job_type_i,
  output logic busy_o,
  output logic sampler_done_o,
  input logic sq_valid_i,
  output logic sq_ready_o,
  input logic [63:0] sq_data_i,
  output logic bram_we_o,
  output logic [1:0] bram_bank_o,
  output logic [9:0] bram_addr_o,
  output logic [31:0] bram_wdata_o
);

  localparam logic [1:0] JOB_SAMPLE_NTT = 2'd1;
  localparam logic [1:0] JOB_SAMPLE_CBD = 2'd2;
  localparam logic [11:0] Q_MOD_W = 12'd3329;

  logic active_q_w;
  logic [1:0] job_type_q_w;
  logic [1:0] bank_q_w;
  logic [2:0] slot_q_w;
  logic [8:0] coeff_count_q_w;
  logic [7:0] written_words_q_w;

  logic [79:0] reservoir_q_w;
  logic [3:0] byte_count_q_w;
  logic pending_even_valid_q_w;
  logic [11:0] pending_even_q_w;

  logic cbd_word_valid_q_w;
  logic [63:0] cbd_word_q_w;
  logic [3:0] cbd_bytes_remaining_q_w;

  logic [11:0] candidate0_w;
  logic [11:0] candidate1_w;
  logic candidate0_accept_w;
  logic candidate1_accept_w;
  logic [1:0] accepted_count_w;
  logic write_valid_w;
  logic [11:0] write_even_w;
  logic [11:0] write_odd_w;
  logic next_pending_valid_w;
  logic [11:0] next_pending_w;
  logic [11:0] cbd_even_w;
  logic [11:0] cbd_odd_w;
  logic [7:0] cbd_byte_w;
  logic [79:0] append_data_w;
  logic sampler_done_q_w;

  function automatic logic [11:0] cbd_decode(input logic [3:0] nibble_i);
    logic [2:0] positive_w;
    logic [2:0] negative_w;
    logic signed [3:0] diff_w;
    begin
      positive_w = {2'b0, nibble_i[0]} + {2'b0, nibble_i[1]};
      negative_w = {2'b0, nibble_i[2]} + {2'b0, nibble_i[3]};
      diff_w = $signed({1'b0, positive_w}) - $signed({1'b0, negative_w});
      case (diff_w)
        -4'sd2:  cbd_decode = 12'hcff;
        -4'sd1:  cbd_decode = 12'hd00;
        4'sd0:   cbd_decode = 12'h000;
        4'sd1:   cbd_decode = 12'h001;
        4'sd2:   cbd_decode = 12'h002;
        default: cbd_decode = 12'h000;
      endcase
    end
  endfunction

  always_comb begin
    candidate0_w = {reservoir_q_w[11:8], reservoir_q_w[7:0]};
    candidate1_w = {reservoir_q_w[23:16], reservoir_q_w[15:12]};
    candidate0_accept_w = (candidate0_w < Q_MOD_W) && (coeff_count_q_w < 9'd256);
    candidate1_accept_w = (candidate1_w < Q_MOD_W) &&
        (({1'b0, coeff_count_q_w} + candidate0_accept_w) < 10'd256);
    accepted_count_w = {1'b0, candidate0_accept_w} + {1'b0, candidate1_accept_w};
    write_valid_w = 1'b0;
    write_even_w = 12'b0;
    write_odd_w = 12'b0;
    next_pending_valid_w = pending_even_valid_q_w;
    next_pending_w = pending_even_q_w;
    if (pending_even_valid_q_w) begin
      if (candidate0_accept_w) begin
        write_valid_w = 1'b1;
        write_even_w = pending_even_q_w;
        write_odd_w = candidate0_w;
        if (candidate1_accept_w) begin
          next_pending_valid_w = 1'b1;
          next_pending_w = candidate1_w;
        end else begin
          next_pending_valid_w = 1'b0;
          next_pending_w = 12'b0;
        end
      end else if (candidate1_accept_w) begin
        // d0 can be rejected while d1 still completes the pending pair.
        write_valid_w = 1'b1;
        write_even_w = pending_even_q_w;
        write_odd_w = candidate1_w;
        next_pending_valid_w = 1'b0;
        next_pending_w = 12'b0;
      end
    end else if (candidate0_accept_w && candidate1_accept_w) begin
      write_valid_w = 1'b1;
      write_even_w = candidate0_w;
      write_odd_w = candidate1_w;
      next_pending_valid_w = 1'b0;
      next_pending_w = 12'b0;
    end else if (candidate0_accept_w) begin
      next_pending_valid_w = 1'b1;
      next_pending_w = candidate0_w;
    end else if (candidate1_accept_w) begin
      next_pending_valid_w = 1'b1;
      next_pending_w = candidate1_w;
    end

    cbd_byte_w = cbd_word_q_w[7:0];
    cbd_even_w = cbd_decode(cbd_byte_w[3:0]);
    cbd_odd_w = cbd_decode(cbd_byte_w[7:4]);
    append_data_w = {16'b0, sq_data_i} << (byte_count_q_w * 8);

    sq_ready_o = 1'b0;
    if (active_q_w && !soft_rst_i && rst_ni && (coeff_count_q_w < 9'd256)) begin
      if (job_type_q_w == JOB_SAMPLE_NTT) sq_ready_o = (byte_count_q_w < 4'd3);
      else if (job_type_q_w == JOB_SAMPLE_CBD) sq_ready_o = !cbd_word_valid_q_w;
    end
    busy_o = active_q_w;
    sampler_done_o = sampler_done_q_w && !soft_rst_i && rst_ni;
    bram_we_o = 1'b0;
    bram_bank_o = bank_q_w;
    bram_addr_o = {slot_q_w, written_words_q_w[6:0]};
    bram_wdata_o = 32'b0;
    if (rst_ni && !soft_rst_i && active_q_w && (job_type_q_w == JOB_SAMPLE_NTT) &&
        (byte_count_q_w >= 4'd3) && write_valid_w) begin
      bram_we_o = 1'b1;
      bram_wdata_o = {4'b0, write_odd_w, 4'b0, write_even_w};
    end else if (rst_ni && !soft_rst_i && active_q_w && (job_type_q_w == JOB_SAMPLE_CBD) &&
                 cbd_word_valid_q_w) begin
      bram_we_o = 1'b1;
      bram_wdata_o = {4'b0, cbd_odd_w, 4'b0, cbd_even_w};
    end
    if (soft_rst_i || !rst_ni) begin
      sq_ready_o = 1'b0;
      bram_we_o = 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q_w <= 1'b0;
      job_type_q_w <= 2'b0;
      bank_q_w <= 2'b0;
      slot_q_w <= 3'b0;
      coeff_count_q_w <= 9'b0;
      written_words_q_w <= 8'b0;
      reservoir_q_w <= 80'b0;
      byte_count_q_w <= 4'b0;
      pending_even_valid_q_w <= 1'b0;
      pending_even_q_w <= 12'b0;
      cbd_word_valid_q_w <= 1'b0;
      cbd_word_q_w <= 64'b0;
      cbd_bytes_remaining_q_w <= 4'b0;
      sampler_done_q_w <= 1'b0;
    end else if (soft_rst_i) begin
      active_q_w <= 1'b0;
      job_type_q_w <= 2'b0;
      bank_q_w <= 2'b0;
      slot_q_w <= 3'b0;
      coeff_count_q_w <= 9'b0;
      written_words_q_w <= 8'b0;
      reservoir_q_w <= 80'b0;
      byte_count_q_w <= 4'b0;
      pending_even_valid_q_w <= 1'b0;
      pending_even_q_w <= 12'b0;
      cbd_word_valid_q_w <= 1'b0;
      cbd_word_q_w <= 64'b0;
      cbd_bytes_remaining_q_w <= 4'b0;
      sampler_done_q_w <= 1'b0;
    end else begin
      sampler_done_q_w <= 1'b0;
      if (!active_q_w && start_poly_i) begin
        active_q_w <= 1'b1;
        job_type_q_w <= job_type_i;
        coeff_count_q_w <= 9'b0;
        written_words_q_w <= 8'b0;
        reservoir_q_w <= 80'b0;
        byte_count_q_w <= 4'b0;
        pending_even_valid_q_w <= 1'b0;
        pending_even_q_w <= 12'b0;
        cbd_word_valid_q_w <= 1'b0;
        cbd_word_q_w <= 64'b0;
        cbd_bytes_remaining_q_w <= 4'b0;
        case (job_id_i)
          4'd1, 4'd4, 4'd7, 4'd10, 4'd13: bank_q_w <= 2'd0;
          4'd2, 4'd5, 4'd8, 4'd11, 4'd14: bank_q_w <= 2'd1;
          4'd3, 4'd6, 4'd9, 4'd12, 4'd15: bank_q_w <= 2'd2;
          default: bank_q_w <= 2'd0;
        endcase
        case (job_id_i)
          4'd10, 4'd11, 4'd12: slot_q_w <= 3'd0;
          4'd13, 4'd14, 4'd15: slot_q_w <= 3'd1;
          4'd1, 4'd2, 4'd3:    slot_q_w <= 3'd2;
          4'd4, 4'd5, 4'd6:    slot_q_w <= 3'd3;
          4'd7, 4'd8, 4'd9:    slot_q_w <= 3'd4;
          default: slot_q_w <= 3'd0;
        endcase
      end else if (active_q_w && (job_type_q_w == JOB_SAMPLE_NTT)) begin
        if ((byte_count_q_w >= 4'd3) && (coeff_count_q_w < 9'd256)) begin
          reservoir_q_w <= reservoir_q_w >> 24;
          byte_count_q_w <= byte_count_q_w - 4'd3;
          if (accepted_count_w != 0) coeff_count_q_w <= coeff_count_q_w + accepted_count_w;
          pending_even_valid_q_w <= next_pending_valid_w;
          pending_even_q_w <= next_pending_w;
        end else if (sq_valid_i && sq_ready_o) begin
          reservoir_q_w <= reservoir_q_w | append_data_w;
          byte_count_q_w <= byte_count_q_w + 4'd8;
        end
      end else if (active_q_w && (job_type_q_w == JOB_SAMPLE_CBD)) begin
        if (cbd_word_valid_q_w) begin
          cbd_word_q_w <= cbd_word_q_w >> 8;
          cbd_bytes_remaining_q_w <= cbd_bytes_remaining_q_w - 4'd1;
          coeff_count_q_w <= coeff_count_q_w + 9'd2;
          if (cbd_bytes_remaining_q_w == 4'd1) cbd_word_valid_q_w <= 1'b0;
        end else if (sq_valid_i && sq_ready_o) begin
          cbd_word_q_w <= sq_data_i;
          cbd_word_valid_q_w <= 1'b1;
          cbd_bytes_remaining_q_w <= 4'd8;
        end
      end

      if (bram_we_o) begin
        written_words_q_w <= written_words_q_w + 8'd1;
        if (written_words_q_w == 8'd127) begin
          active_q_w <= 1'b0;
          sampler_done_q_w <= 1'b1;
          reservoir_q_w <= 80'b0;
          byte_count_q_w <= 4'b0;
          pending_even_valid_q_w <= 1'b0;
          cbd_word_valid_q_w <= 1'b0;
          cbd_bytes_remaining_q_w <= 4'b0;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk_i) begin
    if (rst_ni && !soft_rst_i && start_poly_i) begin
      assert (!active_q_w)
      else $error("sampler_unit start_poly_i asserted while busy");
      assert (((job_id_i >= 4'd1) && (job_id_i <= 4'd9) && (job_type_i == JOB_SAMPLE_NTT)) ||
              ((job_id_i >= 4'd10) && (job_id_i <= 4'd15) && (job_type_i == JOB_SAMPLE_CBD)))
      else $error("sampler_unit job_id_i/job_type_i mismatch");
    end
  end
`endif
endmodule
