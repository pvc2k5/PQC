/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Key and polynomial packing, copying, and output serialization.
 */
`timescale 1ns / 1ps

module transcoder (
  input logic clk_i,
  input logic rst_ni,
  input logic soft_rst_i,
  input logic tc_start_i,
  input logic [1:0] tc_cmd_i,
  input logic [255:0] rho_i,
  input logic [255:0] hash_i,
  input logic [255:0] z_i,
  output logic tc_busy_o,
  output logic tc_done_o,
  output logic tc_error_o,
  output logic bankA_en_o,
  output logic [1:0] bankA_bank_o,
  output logic [9:0] bankA_addr_o,
  input logic [31:0] bankA_rdata_i,
  output logic bram_out_we_o,
  output logic [9:0] bram_out_addr_o,
  output logic [31:0] bram_out_wdata_o,
  output logic out_rd_en_o,
  output logic [9:0] out_rd_addr_o,
  input logic [31:0] out_rd_data_i
);

  localparam logic [ 1:0] CMD_PACK_EK_W       = 2'd0;
  localparam logic [ 1:0] CMD_PACK_DKPKE_W    = 2'd1;
  localparam logic [ 1:0] CMD_COPY_EK_W       = 2'd2;
  localparam logic [ 1:0] CMD_APPEND_SUFFIX_W = 2'd3;
  localparam logic [11:0] Q_MOD_W             = 12'd3329;

  typedef enum logic [3:0] {
    ST_IDLE_W,
    ST_BANK_REQ_W,
    ST_BANK_CAPTURE_W,
    ST_PACK_WRITE_W,
    ST_RHO_WRITE_W,
    ST_COPY_REQ_W,
    ST_COPY_CAPTURE_W,
    ST_COPY_WRITE_W,
    ST_SUFFIX_WRITE_W
  } state_t_w;

  state_t_w state_q_w;
  logic [1:0] cmd_q_w;
  logic [255:0] rho_q_w;
  logic [255:0] hash_q_w;
  logic [255:0] z_q_w;
  logic [1:0] bank_q_w;
  logic [6:0] pair_q_w;
  logic [8:0] pack_word_q_w;
  logic [3:0] rho_word_q_w;
  logic [8:0] copy_word_q_w;
  logic [4:0] suffix_word_q_w;
  logic [47:0] reservoir_q_w;
  logic [5:0] bit_count_q_w;
  logic [31:0] copy_data_q_w;
  logic tc_done_q_w;
  logic tc_error_q_w;
  logic [23:0] chunk_w;
  logic [47:0] append_value_w;
  logic [5:0] append_count_w;
  logic [9:0] pack_base_w;
  logic [9:0] output_pack_base_w;
  logic [11:0] coeff0_w;
  logic [11:0] coeff1_w;
  logic bad_word_w;

  always_comb begin
    coeff0_w = bankA_rdata_i[11:0];
    coeff1_w = bankA_rdata_i[27:16];
    chunk_w = {coeff1_w[11:4], coeff1_w[3:0], coeff0_w[11:8], coeff0_w[7:0]};
    append_value_w = reservoir_q_w | ({{24{1'b0}}, chunk_w} << bit_count_q_w);
    append_count_w = bit_count_q_w + 6'd24;
    bad_word_w = (bankA_rdata_i[15:12] != 4'd0) || (bankA_rdata_i[31:28] != 4'd0) ||
        (coeff0_w >= Q_MOD_W) || (coeff1_w >= Q_MOD_W);
    pack_base_w = (cmd_q_w == CMD_PACK_EK_W) ? 10'd640 : 10'd0;
    output_pack_base_w = (cmd_q_w == CMD_PACK_EK_W) ? 10'd0 : 10'd296;
  end

  always_comb begin
    tc_busy_o = (state_q_w != ST_IDLE_W);
    tc_done_o = tc_done_q_w && rst_ni && !soft_rst_i;
    tc_error_o = tc_error_q_w && rst_ni && !soft_rst_i;
    bankA_en_o = 1'b0;
    bankA_bank_o = bank_q_w;
    bankA_addr_o = {pack_base_w[9:7], pair_q_w};
    bram_out_we_o = 1'b0;
    bram_out_addr_o = 10'd0;
    bram_out_wdata_o = 32'd0;
    out_rd_en_o = 1'b0;
    out_rd_addr_o = {1'b0, copy_word_q_w};

    if (rst_ni && !soft_rst_i) begin
      case (state_q_w)
        ST_BANK_REQ_W: bankA_en_o = 1'b1;
        ST_PACK_WRITE_W: begin
          bram_out_we_o = 1'b1;
          bram_out_addr_o = output_pack_base_w + pack_word_q_w;
          bram_out_wdata_o = reservoir_q_w[31:0];
        end
        ST_RHO_WRITE_W: begin
          bram_out_we_o = 1'b1;
          bram_out_addr_o = 10'd288 + rho_word_q_w;
          bram_out_wdata_o = rho_q_w[32*rho_word_q_w+:32];
        end
        ST_COPY_REQ_W: out_rd_en_o = 1'b1;
        ST_COPY_WRITE_W: begin
          bram_out_we_o = 1'b1;
          bram_out_addr_o = 10'd584 + copy_word_q_w;
          bram_out_wdata_o = copy_data_q_w;
        end
        ST_SUFFIX_WRITE_W: begin
          bram_out_we_o = 1'b1;
          if (suffix_word_q_w < 5'd8) begin
            bram_out_addr_o = 10'd880 + suffix_word_q_w;
            bram_out_wdata_o = hash_q_w[32*suffix_word_q_w[2:0]+:32];
          end else begin
            bram_out_addr_o = 10'd888 + (suffix_word_q_w - 5'd8);
            bram_out_wdata_o = z_q_w[32*suffix_word_q_w[2:0]+:32];
          end
        end
        default: begin
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q_w <= ST_IDLE_W;
      cmd_q_w <= 2'd0;
      rho_q_w <= '0;
      hash_q_w <= '0;
      z_q_w <= '0;
      bank_q_w <= '0;
      pair_q_w <= '0;
      pack_word_q_w <= '0;
      rho_word_q_w <= '0;
      copy_word_q_w <= '0;
      suffix_word_q_w <= '0;
      reservoir_q_w <= '0;
      bit_count_q_w <= '0;
      copy_data_q_w <= '0;
      tc_done_q_w <= 1'b0;
      tc_error_q_w <= 1'b0;
    end else if (soft_rst_i) begin
      state_q_w <= ST_IDLE_W;
      cmd_q_w <= 2'd0;
      rho_q_w <= '0;
      hash_q_w <= '0;
      z_q_w <= '0;
      bank_q_w <= '0;
      pair_q_w <= '0;
      pack_word_q_w <= '0;
      rho_word_q_w <= '0;
      copy_word_q_w <= '0;
      suffix_word_q_w <= '0;
      reservoir_q_w <= '0;
      bit_count_q_w <= '0;
      copy_data_q_w <= '0;
      tc_done_q_w <= 1'b0;
      tc_error_q_w <= 1'b0;
    end else begin
      tc_done_q_w <= 1'b0;
      tc_error_q_w <= 1'b0;
      case (state_q_w)
        ST_IDLE_W: begin
          if (tc_start_i) begin
            cmd_q_w <= tc_cmd_i;
            rho_q_w <= rho_i;
            hash_q_w <= hash_i;
            z_q_w <= z_i;
            bank_q_w <= 2'd0;
            pair_q_w <= 7'd0;
            pack_word_q_w <= 9'd0;
            rho_word_q_w <= 4'd0;
            copy_word_q_w <= 9'd0;
            suffix_word_q_w <= 5'd0;
            reservoir_q_w <= 48'd0;
            bit_count_q_w <= 6'd0;
            case (tc_cmd_i)
              CMD_PACK_EK_W, CMD_PACK_DKPKE_W: state_q_w <= ST_BANK_REQ_W;
              CMD_COPY_EK_W: state_q_w <= ST_COPY_REQ_W;
              default: state_q_w <= ST_SUFFIX_WRITE_W;
            endcase
          end
        end
        ST_BANK_REQ_W: state_q_w <= ST_BANK_CAPTURE_W;
        ST_BANK_CAPTURE_W: begin
          if (bad_word_w) begin
            reservoir_q_w <= 48'd0;
            bit_count_q_w <= 6'd0;
            state_q_w <= ST_IDLE_W;
            tc_error_q_w <= 1'b1;
          end else begin
            reservoir_q_w <= append_value_w;
            if (append_count_w >= 6'd32) begin
              bit_count_q_w <= append_count_w - 6'd32;
              state_q_w <= ST_PACK_WRITE_W;
            end else begin
              bit_count_q_w <= append_count_w;
              if ((bank_q_w == 2'd2) && (pair_q_w == 7'd127)) begin
                // A complete polynomial stream always ends on a word boundary.
                state_q_w <= ST_IDLE_W;
                tc_error_q_w <= 1'b1;
              end else if (pair_q_w == 7'd127) begin
                pair_q_w <= 7'd0;
                bank_q_w <= bank_q_w + 2'd1;
                state_q_w <= ST_BANK_REQ_W;
              end else begin
                pair_q_w <= pair_q_w + 7'd1;
                state_q_w <= ST_BANK_REQ_W;
              end
            end
          end
        end
        ST_PACK_WRITE_W: begin
          reservoir_q_w <= reservoir_q_w >> 32;
          if (bank_q_w == 2'd2 && pair_q_w == 7'd127) begin
            reservoir_q_w <= 48'd0;
            bit_count_q_w <= 6'd0;
            if (pack_word_q_w == 9'd287) begin
              if (cmd_q_w == CMD_PACK_EK_W) begin
                rho_word_q_w <= 4'd0;
                state_q_w <= ST_RHO_WRITE_W;
              end else begin
                state_q_w <= ST_IDLE_W;
                tc_done_q_w <= 1'b1;
              end
            end else begin
              state_q_w <= ST_IDLE_W;
              tc_error_q_w <= 1'b1;
            end
          end else begin
            bit_count_q_w <= bit_count_q_w;
            pack_word_q_w <= pack_word_q_w + 9'd1;
            if (pair_q_w == 7'd127) begin
              pair_q_w <= 7'd0;
              bank_q_w <= bank_q_w + 2'd1;
            end else begin
              pair_q_w <= pair_q_w + 7'd1;
            end
            state_q_w <= ST_BANK_REQ_W;
          end
        end
        ST_RHO_WRITE_W: begin
          if (rho_word_q_w == 4'd7) begin
            state_q_w <= ST_IDLE_W;
            tc_done_q_w <= 1'b1;
          end else begin
            rho_word_q_w <= rho_word_q_w + 4'd1;
          end
        end
        ST_COPY_REQ_W: state_q_w <= ST_COPY_CAPTURE_W;
        ST_COPY_CAPTURE_W: begin
          copy_data_q_w <= out_rd_data_i;
          state_q_w <= ST_COPY_WRITE_W;
        end
        ST_COPY_WRITE_W: begin
          if (copy_word_q_w == 9'd295) begin
            state_q_w <= ST_IDLE_W;
            tc_done_q_w <= 1'b1;
          end else begin
            copy_word_q_w <= copy_word_q_w + 9'd1;
            state_q_w <= ST_COPY_REQ_W;
          end
        end
        ST_SUFFIX_WRITE_W: begin
          if (suffix_word_q_w == 5'd15) begin
            state_q_w <= ST_IDLE_W;
            tc_done_q_w <= 1'b1;
          end else begin
            suffix_word_q_w <= suffix_word_q_w + 5'd1;
          end
        end
        default: state_q_w <= ST_IDLE_W;
      endcase
    end
  end

`ifndef SYNTHESIS

  always_ff @(posedge clk_i) begin
    if (rst_ni && !soft_rst_i && tc_start_i && (state_q_w != ST_IDLE_W)) begin
      assert (1'b0)
      else $fatal(1, "transcoder start while busy");
    end
  end
`endif

endmodule
