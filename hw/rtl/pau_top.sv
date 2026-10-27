/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Pipelined NTT and row multiply-accumulate processing unit.
 */

module pau_top #(
    // Each NTT layer issues 64 paired butterfly requests.
    localparam logic [31:0] LPARA_NT_ISSUES_PER_LAYER = 7'd64
) (
  input logic clk_i,
  input logic rst_ni,
  input logic soft_rst_i,
  input logic pau_start_i,
  input logic [1:0] pau_cmd_i,
  input logic [1:0] pau_bank_sel_i,
  input logic [1:0] pau_row_i,
  input logic [2:0] pau_slot_src_i,
  input logic [2:0] pau_slot_dst_i,
  output logic pau_busy_o,
  output logic pau_done_o,
  output logic bram_en_o,
  output logic bram_we_o,
  output logic [1:0] bram_bank_o,
  output logic [9:0] bram_addr_o,
  output logic [31:0] bram_wdata_o,
  input logic [31:0] bram_rdata_i,
  output logic bram_a_en_o,
  output logic bram_a_we_o,
  output logic [1:0] bram_a_bank_o,
  output logic [9:0] bram_a_addr_o,
  output logic [31:0] bram_a_wdata_o,
  input logic [31:0] bram_a_rdata_i
);

  // State values support legacy NTT command sequencing.
  typedef enum logic [5:0] {
    IDLE,
    NA,
    NB,
    NC,
    NI,
    NW,
    NORM_A,
    WRITE_A,
    NORM_B,
    WRITE_B,
    DONE,
    FLUSH,
    NORM_WAIT
  } state_t;
  state_t state_w;
  state_t norm_source_w;
  logic [1:0] bank_w;
  logic [2:0] slot_w;
  logic [2:0] flush_count_w;
  logic [8:0] len_w;
  logic [8:0] group_w;
  logic [8:0] j_w;
  logic [7:0] k_w;
  logic [31:0] a_w;
  logic [31:0] b_w;
  logic [31:0] raw_a_w;
  logic [31:0] raw_b_w;
  logic [31:0] word_w;
  logic [15:0] norm0_w;
  logic [15:0] norm1_w;
  logic [11:0] canon0_w;
  logic [11:0] canon1_w;
  logic issue_w;
  logic fqmul_w;
  logic bfu_valid_w;
  logic flush_w;
  logic [31:0] bfu_a_w;
  logic [31:0] bfu_b_w;
  logic [31:0] result_a_w;
  logic [31:0] result_b_w;
  logic norm_start_w;
  logic norm_valid_w;
  // NTT work is independent of the legacy command FSM. The metadata queue
  // follows accepted BFU requests; the paired-write queue absorbs the two
  // consecutive canonicalizer results before their dual-port commit.
  logic reg_nt_busy;
  logic reg_nt_done;
  logic reg_nt_slot;
  logic reg_nt_feed_b;
  logic [8:0] reg_nt_len;
  logic [8:0] reg_nt_group;
  logic [8:0] reg_nt_j;
  logic [7:0] reg_nt_k;
  logic [6:0] reg_nt_issue_count;
  logic [6:0] reg_nt_write_count;
  logic [2:0] reg_nt_slot_sel;
  logic [1:0] reg_nt_bank;
  logic reg_nt_read_pending;
  logic [2:0] reg_meta_wr;
  logic [2:0] reg_meta_rd;
  logic [3:0] reg_meta_count;
  logic [9:0] reg_meta_addr_a[0:7];
  logic [9:0] reg_meta_addr_b[0:7];
  logic [3:0] reg_wr_wr;
  logic [3:0] reg_wr_rd;
  logic [4:0] reg_wr_count;
  logic [9:0] reg_wr_addr_a[0:15];
  logic [9:0] reg_wr_addr_b[0:15];
  logic [31:0] reg_wr_data_a[0:15];
  logic [31:0] reg_wr_data_b[0:15];
  logic [31:0] reg_nt_raw_b;
  logic [9:0] reg_nt_meta_a;
  logic [9:0] reg_nt_meta_b;
  logic [9:0] reg_nt_pend_addr_a;
  logic [9:0] reg_nt_pend_addr_b;
  logic [7:0] reg_nt_pend_k;
  logic [5:0] reg_nt_canon_valid;
  logic [5:0] reg_nt_canon_tag;
  logic [9:0] reg_nt_addr_a_pipe[0:5];
  logic [9:0] reg_nt_addr_b_pipe[0:5];
  logic [11:0] reg_nt_canon_a;
  logic [11:0] reg_nt_canon_a_high;
  logic [9:0] reg_nt_canon_addr_a;
  logic [9:0] reg_nt_canon_addr_b;
  logic w_nt_admit;
  logic w_nt_issue;
  logic w_nt_canon_valid;
  logic w_nt_canon_tag;
  logic w_nt_canon1_valid;
  logic [31:0] w_nt_bfu_a;
  logic [31:0] w_nt_bfu_b;
  logic [9:0] w_nt_read_addr_a;
  logic [9:0] w_nt_read_addr_b;

  assign w_nt_canon_valid = reg_nt_busy && (bfu_valid_w || reg_nt_feed_b);
  assign w_nt_canon_tag = reg_nt_feed_b;

  always_comb begin
    w_nt_read_addr_a = {reg_nt_slot_sel, reg_nt_j[7:1]};
    w_nt_read_addr_b = ({7'd0, reg_nt_slot_sel} << 7) + ((reg_nt_j + reg_nt_len) >> 1);
    // Admit paired reads only when metadata and write capacity are available.
    w_nt_admit = reg_nt_busy && !reg_nt_slot && reg_nt_issue_count < 64 &&
        (reg_nt_issue_count - reg_nt_write_count) < 16 && reg_meta_count < 4'd8;
    w_nt_issue = reg_nt_busy && reg_nt_slot && reg_nt_read_pending;
    w_nt_bfu_a = a_w;
    w_nt_bfu_b = b_w;
    if (w_nt_issue) begin
      w_nt_bfu_a = bram_a_rdata_i;
      w_nt_bfu_b = bram_rdata_i;
    end
  end
  canonical_reduce_pipe u_canon0 (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(flush_w),
    .valid_i(norm_start_w),
    .data_i (norm0_w),
    .valid_o(norm_valid_w),
    .data_o (canon0_w)
  );
  canonical_reduce_pipe u_canon1 (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(flush_w),
    .valid_i(norm_start_w),
    .data_i (norm1_w),
    .valid_o(w_nt_canon1_valid),
    .data_o (canon1_w)
  );

  assign flush_w = soft_rst_i || state_w == FLUSH;
  // ROW_MAC schedules work across eight contexts.
  // Bank/slot/address mapping is verbatim from the removed legacy MA..TW FSM;
  // only the scheduling is new (grant at edge 12*p, commit at 12*p+67, done at
  // the commit edge of pair 127 = edge 1591). Context q age = blk-1-q where
  // reg_rm_blk=floor((edge-2)/12)+1 increments on slot-11 edges; the (age,slot)
  // Decode follows the specified Section 3.3 table. Results are captured
  // valid-driven at issue+6 (BFU/canon) and request+1 (synchronous memory).
  logic reg_rm_busy;
  logic reg_rm_done;
  logic reg_rm_capv;
  logic [1:0] reg_rm_row;
  logic [3:0] reg_rm_slot;
  logic [7:0] reg_rm_pair;
  logic [7:0] reg_rm_blk;
  logic [7:0] reg_rm_valid;
  logic [6:0] reg_rm_pair_c[0:7];
  logic [2:0] reg_rm_age[0:7];
  logic [31:0] reg_rm_as_a[0:2][0:7];
  logic [31:0] reg_rm_as_b[0:2][0:7];
  logic [31:0] reg_rm_di[0:2][0:7];
  logic [31:0] reg_rm_cr[0:2][0:7];
  logic [31:0] reg_rm_sc[0:7];
  logic [31:0] reg_rm_e[0:7];
  logic [15:0] reg_rm_ga[0:2][0:7];
  logic [23:0] reg_rm_c [0:2][0:7];  // {lane1,lane0} canonical pair result
  logic [23:0] reg_rm_acc[0:7];
  logic [23:0] reg_rm_sn[0:7];
  logic [23:0] reg_rm_fi[0:7];
  logic [2:0] reg_rm_pend_di[0:7];
  logic [2:0] reg_rm_pend_cr[0:7];
  logic [2:0] reg_rm_pend_ga[0:7];
  logic [2:0] reg_rm_pend_pn[0:7];
  logic [2:0] reg_rm_pend_ac[0:7];
  logic [7:0] reg_rm_pend_sc;
  logic [7:0] reg_rm_pend_sn;
  logic [7:0] reg_rm_pend_en;
  logic [5:0] reg_rm_bfu_tagv;
  logic [5:0] reg_rm_can_tagv;
  logic [6:0] reg_rm_bfu_tag[0:5];
  logic [5:0] reg_rm_can_tag[0:5];
  logic [2:0] reg_rm_capctx;
  logic [2:0] reg_rm_capdst;
  logic w_rm_accept;
  logic w_rm_gnt;
  logic w_rm_bfu_fire;
  logic w_rm_can_fire;
  logic [3:0] w_rm_bfu_op;
  logic [2:0] w_rm_can_op;
  logic [2:0] w_rm_bfu_ctx;
  logic [2:0] w_rm_can_ctx;
  logic [2:0] w_rm_gnt_idx;
  logic [6:0] w_rm_bfu_pair;
  logic [6:0] w_rm_can_pair;
  logic [6:0] w_rm_gnt_pair;
  logic [31:0] w_rm_bfu_a;
  logic [31:0] w_rm_bfu_b;
  logic [15:0] w_rm_can_in0;
  logic [15:0] w_rm_can_in1;
  logic [15:0] w_rm_gamma;
  logic [8:0] w_rm_q0;
  logic [8:0] w_rm_q1;
  logic [8:0] w_rm_q2;
  logic [8:0] w_rm_q3;
  logic [8:0] w_rm_q4;
  logic [8:0] w_rm_q5;
  logic w_rm_v0;
  logic w_rm_v1;
  logic w_rm_v2;
  logic w_rm_v3;
  logic w_rm_v4;
  logic w_rm_v5;
  logic [2:0] w_rm_i0;
  logic [2:0] w_rm_i1;
  logic [2:0] w_rm_i2;
  logic [2:0] w_rm_i3;
  logic [2:0] w_rm_i4;
  logic [2:0] w_rm_i5;
  logic [2:0] w_rm_mslot;
  logic w_rm_req_a_en;
  logic w_rm_req_b_en;
  logic w_rm_req_b_we;
  logic [1:0] w_rm_req_a_bank;
  logic [1:0] w_rm_req_b_bank;
  logic [9:0] w_rm_req_a_addr;
  logic [9:0] w_rm_req_b_addr;
  logic [31:0] w_rm_req_b_data;
  logic w_rm_cap_set;
  logic [2:0] w_rm_cap_set_ctx;
  logic [2:0] w_rm_cap_set_dst;

  assign norm_start_w = w_nt_canon_valid || w_rm_can_fire;
  // Selects a ready context for one multiply or canonicalization beat.
  always_comb begin : p_com_rm_decode
    w_rm_accept = 1'b0;
    w_rm_gnt = 1'b0;
    w_rm_gnt_idx = 3'd0;
    w_rm_gnt_pair = 7'd0;
    w_rm_mslot = 3'd0;
    w_rm_gamma = 16'd0;
    w_rm_bfu_fire = 1'b0;
    w_rm_bfu_op = 4'd0;
    w_rm_bfu_ctx = 3'd0;
    w_rm_bfu_pair = 7'd0;
    w_rm_bfu_a = 32'd0;
    w_rm_bfu_b = 32'd0;
    w_rm_can_fire = 1'b0;
    w_rm_can_op = 3'd0;
    w_rm_can_ctx = 3'd0;
    w_rm_can_pair = 7'd0;
    w_rm_can_in0 = 16'd0;
    w_rm_can_in1 = 16'd0;
    w_rm_req_a_en = 1'b0;
    w_rm_req_a_bank = 2'd0;
    w_rm_req_a_addr = 10'd0;
    w_rm_req_b_en = 1'b0;
    w_rm_req_b_we = 1'b0;
    w_rm_req_b_bank = 2'd0;
    w_rm_req_b_addr = 10'd0;
    w_rm_req_b_data = 32'd0;
    w_rm_cap_set = 1'b0;
    w_rm_cap_set_ctx = 3'd0;
    w_rm_cap_set_dst = 3'd0;
    w_rm_q0 = 9'd0;
    w_rm_v0 = 1'b0;
    w_rm_i0 = 3'd0;
    w_rm_q1 = 9'd0;
    w_rm_v1 = 1'b0;
    w_rm_i1 = 3'd0;
    w_rm_q2 = 9'd0;
    w_rm_v2 = 1'b0;
    w_rm_i2 = 3'd0;
    w_rm_q3 = 9'd0;
    w_rm_v3 = 1'b0;
    w_rm_i3 = 3'd0;
    w_rm_q4 = 9'd0;
    w_rm_v4 = 1'b0;
    w_rm_i4 = 3'd0;
    w_rm_q5 = 9'd0;
    w_rm_v5 = 1'b0;
    w_rm_i5 = 3'd0;
    w_rm_accept = pau_start_i && (pau_cmd_i == 2'd1) && (state_w == IDLE) && !reg_nt_busy &&
        !reg_rm_busy && rst_ni && !soft_rst_i;
    w_rm_gnt = w_rm_accept || (reg_rm_busy && (reg_rm_slot == 4'd10) && (reg_rm_pair[7] == 1'b0));
    w_rm_gnt_idx = w_rm_accept ? 3'd0 : reg_rm_pair[2:0];
    w_rm_gnt_pair = w_rm_accept ? 7'd0 : reg_rm_pair[6:0];
    w_rm_mslot = {1'b0, reg_rm_row} + 3'd2;
    w_rm_q0 = {1'b0, reg_rm_blk} - 9'd1;
    w_rm_v0 = !w_rm_q0[8] && (w_rm_q0[7:0] < 8'd128) && reg_rm_valid[w_rm_q0[2:0]];
    w_rm_i0 = w_rm_q0[2:0];
    w_rm_q1 = {1'b0, reg_rm_blk} - 9'd2;
    w_rm_v1 = !w_rm_q1[8] && (w_rm_q1[7:0] < 8'd128) && reg_rm_valid[w_rm_q1[2:0]];
    w_rm_i1 = w_rm_q1[2:0];
    w_rm_q2 = {1'b0, reg_rm_blk} - 9'd3;
    w_rm_v2 = !w_rm_q2[8] && (w_rm_q2[7:0] < 8'd128) && reg_rm_valid[w_rm_q2[2:0]];
    w_rm_i2 = w_rm_q2[2:0];
    w_rm_q3 = {1'b0, reg_rm_blk} - 9'd4;
    w_rm_v3 = !w_rm_q3[8] && (w_rm_q3[7:0] < 8'd128) && reg_rm_valid[w_rm_q3[2:0]];
    w_rm_i3 = w_rm_q3[2:0];
    w_rm_q4 = {1'b0, reg_rm_blk} - 9'd5;
    w_rm_v4 = !w_rm_q4[8] && (w_rm_q4[7:0] < 8'd128) && reg_rm_valid[w_rm_q4[2:0]];
    w_rm_i4 = w_rm_q4[2:0];
    w_rm_q5 = {1'b0, reg_rm_blk} - 9'd6;
    w_rm_v5 = !w_rm_q5[8] && (w_rm_q5[7:0] < 8'd128) && reg_rm_valid[w_rm_q5[2:0]];
    w_rm_i5 = w_rm_q5[2:0];
    // gamma = (-1)^p * ZETAS[64+(p>>1)] for the age-0 pair (only GAMMA(j) of
    // that context consumes it), already a Montgomery twiddle - no reconversion.
    w_rm_gamma = w_rm_q0[0] ? -zetas_kyber_pkg::KYBER_ZETAS[64+{1'b0, w_rm_q0[6:1]}] :
        zetas_kyber_pkg::KYBER_ZETAS[64+{1'b0, w_rm_q0[6:1]}];
    if (reg_rm_busy) begin
      if (w_rm_v0)
        case (reg_rm_slot)
          4'd0: begin  // DI(0) + streaming read bank 1 (both ports)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd0;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = reg_rm_as_a[0][w_rm_i0];
            w_rm_bfu_b = reg_rm_as_b[0][w_rm_i0];
            w_rm_req_a_en = 1'b1;
            w_rm_req_a_bank = 2'd1;
            w_rm_req_a_addr = {w_rm_mslot, w_rm_q0[6:0]};
            w_rm_req_b_en = 1'b1;
            w_rm_req_b_bank = 2'd1;
            w_rm_req_b_addr = {3'd0, w_rm_q0[6:0]};
            w_rm_cap_set = 1'b1;
            w_rm_cap_set_ctx = w_rm_i0;
            w_rm_cap_set_dst = 3'd1;
          end
          4'd1: begin  // CROSS(0): s lanes swapped
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd1;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = reg_rm_as_a[0][w_rm_i0];
            w_rm_bfu_b = {reg_rm_as_b[0][w_rm_i0][15:0], reg_rm_as_b[0][w_rm_i0][31:16]};
          end
          4'd2: begin  // DI(1) + streaming read bank 2 (both ports)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd2;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = reg_rm_as_a[1][w_rm_i0];
            w_rm_bfu_b = reg_rm_as_b[1][w_rm_i0];
            w_rm_req_a_en = 1'b1;
            w_rm_req_a_bank = 2'd2;
            w_rm_req_a_addr = {w_rm_mslot, w_rm_q0[6:0]};
            w_rm_req_b_en = 1'b1;
            w_rm_req_b_bank = 2'd2;
            w_rm_req_b_addr = {3'd0, w_rm_q0[6:0]};
            w_rm_cap_set = 1'b1;
            w_rm_cap_set_ctx = w_rm_i0;
            w_rm_cap_set_dst = 3'd2;
          end
          4'd3: begin  // CROSS(1)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd3;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = reg_rm_as_a[1][w_rm_i0];
            w_rm_bfu_b = {reg_rm_as_b[1][w_rm_i0][15:0], reg_rm_as_b[1][w_rm_i0][31:16]};
          end
          4'd4: begin  // DI(2)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd4;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = reg_rm_as_a[2][w_rm_i0];
            w_rm_bfu_b = reg_rm_as_b[2][w_rm_i0];
          end
          4'd5: begin  // CROSS(2)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd5;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = reg_rm_as_a[2][w_rm_i0];
            w_rm_bfu_b = {reg_rm_as_b[2][w_rm_i0][15:0], reg_rm_as_b[2][w_rm_i0][31:16]};
          end
          4'd7: begin  // GAMMA(0): M(u11,gamma), result lane 0
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd6;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = {16'd0, reg_rm_di[0][w_rm_i0][31:16]};
            w_rm_bfu_b = {16'd0, w_rm_gamma};
          end
          4'd9: begin  // GAMMA(1)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd7;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = {16'd0, reg_rm_di[1][w_rm_i0][31:16]};
            w_rm_bfu_b = {16'd0, w_rm_gamma};
          end
          4'd11: begin  // GAMMA(2)
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd8;
            w_rm_bfu_ctx = w_rm_i0;
            w_rm_bfu_pair = w_rm_q0[6:0];
            w_rm_bfu_a = {16'd0, reg_rm_di[2][w_rm_i0][31:16]};
            w_rm_bfu_b = {16'd0, w_rm_gamma};
          end
          default: ;
        endcase
      if (w_rm_v1)
        case (reg_rm_slot)
          4'd2: begin  // PAIR_NORM(0): canon(u00+ug), canon(u01+u10)
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd0;
            w_rm_can_ctx = w_rm_i1;
            w_rm_can_pair = w_rm_q1[6:0];
            w_rm_can_in0 = reg_rm_di[0][w_rm_i1][15:0] + reg_rm_ga[0][w_rm_i1];
            w_rm_can_in1 = reg_rm_cr[0][w_rm_i1][15:0] + reg_rm_cr[0][w_rm_i1][31:16];
          end
          4'd4: begin  // PAIR_NORM(1)
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd1;
            w_rm_can_ctx = w_rm_i1;
            w_rm_can_pair = w_rm_q1[6:0];
            w_rm_can_in0 = reg_rm_di[1][w_rm_i1][15:0] + reg_rm_ga[1][w_rm_i1];
            w_rm_can_in1 = reg_rm_cr[1][w_rm_i1][15:0] + reg_rm_cr[1][w_rm_i1][31:16];
          end
          4'd6: begin  // PAIR_NORM(2)
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd2;
            w_rm_can_ctx = w_rm_i1;
            w_rm_can_pair = w_rm_q1[6:0];
            w_rm_can_in0 = reg_rm_di[2][w_rm_i1][15:0] + reg_rm_ga[2][w_rm_i1];
            w_rm_can_in1 = reg_rm_cr[2][w_rm_i1][15:0] + reg_rm_cr[2][w_rm_i1][31:16];
          end
          4'd9: begin  // ACC_NORM(0): acc += c[0]
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd3;
            w_rm_can_ctx = w_rm_i1;
            w_rm_can_pair = w_rm_q1[6:0];
            w_rm_can_in0 = {4'd0, reg_rm_acc[w_rm_i1][11:0]} + {4'd0, reg_rm_c[0][w_rm_i1][11:0]};
            w_rm_can_in1 = {4'd0, reg_rm_acc[w_rm_i1][23:12]} + {4'd0, reg_rm_c[0][w_rm_i1][23:12]};
          end
          default: ;
        endcase
      if (w_rm_v2)
        case (reg_rm_slot)
          4'd5: begin  // ACC_NORM(1): acc += c[1]
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd4;
            w_rm_can_ctx = w_rm_i2;
            w_rm_can_pair = w_rm_q2[6:0];
            w_rm_can_in0 = {4'd0, reg_rm_acc[w_rm_i2][11:0]} + {4'd0, reg_rm_c[1][w_rm_i2][11:0]};
            w_rm_can_in1 = {4'd0, reg_rm_acc[w_rm_i2][23:12]} + {4'd0, reg_rm_c[1][w_rm_i2][23:12]};
          end
          default: ;
        endcase
      if (w_rm_v3)
        case (reg_rm_slot)
          4'd0: begin  // ACC_NORM(2): acc += c[2]
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd5;
            w_rm_can_ctx = w_rm_i3;
            w_rm_can_pair = w_rm_q3[6:0];
            w_rm_can_in0 = {4'd0, reg_rm_acc[w_rm_i3][11:0]} + {4'd0, reg_rm_c[2][w_rm_i3][11:0]};
            w_rm_can_in1 = {4'd0, reg_rm_acc[w_rm_i3][23:12]} + {4'd0, reg_rm_c[2][w_rm_i3][23:12]};
          end
          4'd8: begin  // SCALE: both lanes * 1353
            w_rm_bfu_fire = 1'b1;
            w_rm_bfu_op = 4'd9;
            w_rm_bfu_ctx = w_rm_i3;
            w_rm_bfu_pair = w_rm_q3[6:0];
            w_rm_bfu_a = {4'd0, reg_rm_acc[w_rm_i3][23:12], 4'd0, reg_rm_acc[w_rm_i3][11:0]};
            w_rm_bfu_b = {16'd1353, 16'd1353};
          end
          default: ;
        endcase
      if (w_rm_v4)
        case (reg_rm_slot)
          4'd3: begin  // SCALE_NORM
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd6;
            w_rm_can_ctx = w_rm_i4;
            w_rm_can_pair = w_rm_q4[6:0];
            w_rm_can_in0 = reg_rm_sc[w_rm_i4][15:0];
            w_rm_can_in1 = reg_rm_sc[w_rm_i4][31:16];
          end
          4'd8: begin  // e read: port A, bank row, slot 1 (legacy ER)
            w_rm_req_a_en = 1'b1;
            w_rm_req_a_bank = reg_rm_row;
            w_rm_req_a_addr = {3'd1, w_rm_q4[6:0]};
            w_rm_cap_set = 1'b1;
            w_rm_cap_set_ctx = w_rm_i4;
            w_rm_cap_set_dst = 3'd3;
          end
          4'd10: begin  // E_NORM: scaled + e (zero-extended, sum <= 6656)
            w_rm_can_fire = 1'b1;
            w_rm_can_op = 3'd7;
            w_rm_can_ctx = w_rm_i4;
            w_rm_can_pair = w_rm_q4[6:0];
            w_rm_can_in0 = {4'd0, reg_rm_sn[w_rm_i4][11:0]} + reg_rm_e[w_rm_i4][15:0];
            w_rm_can_in1 = {4'd0, reg_rm_sn[w_rm_i4][23:12]} + reg_rm_e[w_rm_i4][31:16];
          end
          default: ;
        endcase
      if (w_rm_v5)
        case (reg_rm_slot)
          4'd5: begin  // t write commit (legacy TW), release context after commit
            w_rm_req_b_en = 1'b1;
            w_rm_req_b_we = 1'b1;
            w_rm_req_b_bank = reg_rm_row;
            w_rm_req_b_addr = {3'd5, w_rm_q5[6:0]};
            w_rm_req_b_data = {4'd0, reg_rm_fi[w_rm_i5][23:12], 4'd0, reg_rm_fi[w_rm_i5][11:0]};
          end
          default: ;
        endcase
    end
    if (w_rm_gnt) begin  // grant edge: first streaming read, bank 0, both ports
      w_rm_req_a_en = 1'b1;
      w_rm_req_a_bank = 2'd0;
      w_rm_req_a_addr = w_rm_accept ?
          {{1'b0, pau_row_i} + 3'd2, 7'd0} : {w_rm_mslot, w_rm_gnt_pair};
      w_rm_req_b_en = 1'b1;
      w_rm_req_b_bank = 2'd0;
      w_rm_req_b_addr = {3'd0, w_rm_gnt_pair};
      w_rm_cap_set = 1'b1;
      w_rm_cap_set_ctx = w_rm_gnt_idx;
      w_rm_cap_set_dst = 3'd0;
    end
  end
  bfu_kyber u_bfu (
    .clk_i        (clk_i),
    .rstn_i       (rst_ni),
    .flush_i      (flush_w),
    .selNTT_i     (1'b1),
    .validSrc_i   (issue_w),
    .fqmul_i      (fqmul_w),
    .hilo_i       (1'b0),
    .srcA_i       (bfu_a_w),
    .srcB_i       (bfu_b_w),
    .zeta_addr_i  (reg_nt_busy ? {reg_nt_pend_k, reg_nt_pend_k} : {k_w, k_w}),
    .validResult_o(bfu_valid_w),
    .resultA_o    (result_a_w),
    .resultB_o    (result_b_w)
  );
  // p_com_prim_mux: BFU operand/valid mux (NTT default, ROW_MAC override) and
  // canonicalizer input mux (NTT feed default, ROW_MAC pair sums override).
  // Every output has exactly one assignment (single-driver statements); during
  // ROW_MAC ownership reg_nt_busy=0 so the NTT defaults are inactive.
  always_comb begin : p_com_prim_mux
    issue_w = (w_nt_issue || w_rm_bfu_fire) && rst_ni && !soft_rst_i;
    fqmul_w = !w_nt_issue;
    bfu_a_w = w_rm_bfu_fire ? w_rm_bfu_a : w_nt_bfu_a;
    bfu_b_w = w_rm_bfu_fire ? w_rm_bfu_b : w_nt_bfu_b;
    norm0_w = w_rm_can_fire ?
        w_rm_can_in0 : (w_nt_canon_valid ? (reg_nt_feed_b ? reg_nt_raw_b[15:0] : result_a_w[15:0]) :
                        (state_w == NORM_B ? raw_b_w[15:0] : raw_a_w[15:0]));
    norm1_w = w_rm_can_fire ? w_rm_can_in1 :
        (w_nt_canon_valid ? (reg_nt_feed_b ? reg_nt_raw_b[31:16] : result_a_w[31:16]) :
         (state_w == NORM_B ? raw_b_w[31:16] : raw_a_w[31:16]));
  end
  // p_com_pau_sts: command-interface status outputs.
  always_comb begin : p_com_pau_sts
    pau_busy_o = (state_w != IDLE) || reg_nt_busy || reg_rm_busy;
    pau_done_o = ((state_w == DONE) || reg_nt_done || reg_rm_done) && rst_ni && !soft_rst_i;
  end
  // Combines scheduler requests and abort masking at the scratchpad ports.
  always_comb begin : p_com_bram_drive
    bram_a_en_o = 0;
    bram_a_we_o = 0;
    bram_a_bank_o = reg_nt_bank;
    bram_a_addr_o = 0;
    bram_a_wdata_o = 0;
    bram_en_o = 0;
    bram_we_o = 0;
    bram_bank_o = bank_w;
    bram_addr_o = 0;
    bram_wdata_o = word_w;
    case (state_w)
      NA: begin
        bram_en_o = 1;
        bram_addr_o = {slot_w, j_w[7:1]};
      end
      NB: begin
        bram_en_o = 1;
        bram_addr_o = ({7'd0, slot_w} << 7) + ((j_w + len_w) >> 1);
      end
      WRITE_A: begin
        bram_en_o = 1;
        bram_we_o = 1;
        bram_addr_o = {slot_w, j_w[7:1]};
      end
      WRITE_B: begin
        bram_en_o = 1;
        bram_we_o = 1;
        bram_addr_o = ({7'd0, slot_w} << 7) + ((j_w + len_w) >> 1);
      end
      default: ;
    endcase
    if (reg_nt_busy) begin
      bram_bank_o = reg_nt_bank;
      if (w_nt_admit) begin
        bram_a_en_o = 1;
        bram_en_o = 1;
        bram_a_addr_o = w_nt_read_addr_a;
        bram_addr_o = w_nt_read_addr_b;
      end else if (reg_nt_slot && reg_wr_count != 0) begin
        bram_a_en_o = 1;
        bram_a_we_o = 1;
        bram_en_o = 1;
        bram_we_o = 1;
        bram_a_addr_o = reg_wr_addr_a[reg_wr_rd];
        bram_addr_o = reg_wr_addr_b[reg_wr_rd];
        bram_a_wdata_o = reg_wr_data_a[reg_wr_rd];
        bram_wdata_o = reg_wr_data_b[reg_wr_rd];
      end else begin
        bram_en_o = 0;
        bram_we_o = 0;
        bram_a_en_o = 0;
        bram_a_we_o = 0;
      end
    end else if (reg_rm_busy || w_rm_accept) begin
      // ROW_MAC memory drive: streaming reads occupy both ports of bank j
      // (A word on port A at the legacy matrix slot row+2, s word on port B at
      // slot 0), the e read uses port A bank row slot 1, the t write port B
      // bank row slot 5 - mapping identical to the removed legacy MA/MB/ER/TW.
      bram_a_en_o = w_rm_req_a_en;
      bram_a_we_o = 1'b0;
      bram_a_bank_o = w_rm_req_a_bank;
      bram_a_addr_o = w_rm_req_a_addr;
      bram_a_wdata_o = 32'd0;
      bram_en_o = w_rm_req_b_en;
      bram_we_o = w_rm_req_b_we;
      bram_bank_o = w_rm_req_b_bank;
      bram_addr_o = w_rm_req_b_addr;
      bram_wdata_o = w_rm_req_b_data;
    end
    if (!rst_ni || soft_rst_i) begin
      bram_en_o = 0;
      bram_we_o = 0;
    end
    if (!rst_ni || soft_rst_i) begin
      bram_a_en_o = 0;
      bram_a_we_o = 0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_nt_busy <= 0;
      reg_nt_done <= 0;
      reg_nt_slot <= 0;
      reg_nt_feed_b <= 0;
      reg_nt_read_pending <= 0;
      reg_nt_len <= 0;
      reg_nt_group <= 0;
      reg_nt_j <= 0;
      reg_nt_k <= 0;
      reg_nt_issue_count <= 0;
      reg_nt_write_count <= 0;
      reg_nt_slot_sel <= 0;
      reg_nt_bank <= 0;
      reg_meta_wr <= 0;
      reg_meta_rd <= 0;
      reg_meta_count <= 0;
      reg_wr_wr <= 0;
      reg_wr_rd <= 0;
      reg_wr_count <= 0;
      reg_nt_raw_b <= 0;
      reg_nt_meta_a <= 0;
      reg_nt_meta_b <= 0;
      reg_nt_pend_addr_a <= 0;
      reg_nt_pend_addr_b <= 0;
      reg_nt_pend_k <= 0;
      reg_nt_canon_valid <= 0;
      reg_nt_canon_tag <= 0;
      reg_nt_canon_a <= 0;
      reg_nt_canon_a_high <= 0;
      reg_nt_canon_addr_a <= 0;
      reg_nt_canon_addr_b <= 0;
    end else if (soft_rst_i) begin
      reg_nt_busy <= 0;
      reg_nt_done <= 0;
      reg_nt_slot <= 0;
      reg_nt_feed_b <= 0;
      reg_nt_read_pending <= 0;
      reg_nt_len <= 0;
      reg_nt_group <= 0;
      reg_nt_j <= 0;
      reg_nt_k <= 0;
      reg_nt_issue_count <= 0;
      reg_nt_write_count <= 0;
      reg_meta_wr <= 0;
      reg_meta_rd <= 0;
      reg_meta_count <= 0;
      reg_wr_wr <= 0;
      reg_wr_rd <= 0;
      reg_wr_count <= 0;
      reg_nt_pend_addr_a <= 0;
      reg_nt_pend_addr_b <= 0;
      reg_nt_pend_k <= 0;
      reg_nt_raw_b <= 0;
      reg_nt_meta_a <= 0;
      reg_nt_meta_b <= 0;
      reg_nt_canon_valid <= 0;
      reg_nt_canon_tag <= 0;
    end else begin
      reg_nt_done <= 0;
      reg_nt_canon_valid <= {reg_nt_canon_valid[4:0], w_nt_canon_valid};
      reg_nt_canon_tag <= {reg_nt_canon_tag[4:0], w_nt_canon_tag};
      if (w_nt_canon_valid) begin
        reg_nt_addr_a_pipe[0] <= reg_nt_feed_b ? reg_nt_meta_a : reg_meta_addr_a[reg_meta_rd];
        reg_nt_addr_b_pipe[0] <= reg_nt_feed_b ? reg_nt_meta_b : reg_meta_addr_b[reg_meta_rd];
      end
      reg_nt_addr_a_pipe[1] <= reg_nt_addr_a_pipe[0];
      reg_nt_addr_a_pipe[2] <= reg_nt_addr_a_pipe[1];
      reg_nt_addr_a_pipe[3] <= reg_nt_addr_a_pipe[2];
      reg_nt_addr_a_pipe[4] <= reg_nt_addr_a_pipe[3];
      reg_nt_addr_a_pipe[5] <= reg_nt_addr_a_pipe[4];
      reg_nt_addr_b_pipe[1] <= reg_nt_addr_b_pipe[0];
      reg_nt_addr_b_pipe[2] <= reg_nt_addr_b_pipe[1];
      reg_nt_addr_b_pipe[3] <= reg_nt_addr_b_pipe[2];
      reg_nt_addr_b_pipe[4] <= reg_nt_addr_b_pipe[3];
      reg_nt_addr_b_pipe[5] <= reg_nt_addr_b_pipe[4];
      if (pau_start_i && state_w == IDLE && !reg_nt_busy && !reg_rm_busy && pau_cmd_i == 0) begin
        reg_nt_busy <= 1;
        reg_nt_slot <= 0;
        reg_nt_feed_b <= 0;
        reg_nt_read_pending <= 0;
        reg_nt_len <= 9'd128;
        reg_nt_group <= 0;
        reg_nt_j <= 0;
        reg_nt_k <= 1;
        reg_nt_issue_count <= 0;
        reg_nt_write_count <= 0;
        reg_nt_slot_sel <= pau_slot_src_i;
        reg_nt_bank <= pau_bank_sel_i;
        reg_meta_wr <= 0;
        reg_meta_rd <= 0;
        reg_meta_count <= 0;
        reg_wr_wr <= 0;
        reg_wr_rd <= 0;
        reg_wr_count <= 0;
      end else if (reg_nt_busy) begin
        reg_nt_slot <= ~reg_nt_slot;
        // Capture accepted read addresses and stage index for BFU issue.
        if (w_nt_admit) begin
          reg_nt_read_pending <= 1;
          reg_nt_pend_addr_a <= w_nt_read_addr_a;
          reg_nt_pend_addr_b <= w_nt_read_addr_b;
          reg_nt_pend_k <= reg_nt_k;
        end
        if (w_nt_issue) begin
          reg_nt_read_pending <= 0;
          reg_nt_issue_count <= reg_nt_issue_count + 1'b1;
          reg_meta_addr_a[reg_meta_wr] <= reg_nt_pend_addr_a;
          reg_meta_addr_b[reg_meta_wr] <= reg_nt_pend_addr_b;
          reg_meta_wr <= reg_meta_wr + 1'b1;
          if (reg_nt_j + 9'd2 < reg_nt_group + reg_nt_len) reg_nt_j <= reg_nt_j + 9'd2;
          else if (reg_nt_group + (reg_nt_len << 1) < 9'd256) begin
            reg_nt_group <= reg_nt_group + (reg_nt_len << 1);
            reg_nt_j <= reg_nt_group + (reg_nt_len << 1);
            reg_nt_k <= reg_nt_k + 1'b1;
          end
        end
        if (bfu_valid_w) begin
          reg_nt_meta_a <= reg_meta_addr_a[reg_meta_rd];
          reg_nt_meta_b <= reg_meta_addr_b[reg_meta_rd];
          reg_nt_raw_b <= result_b_w;
          reg_meta_rd <= reg_meta_rd + 1'b1;
        end
        if (bfu_valid_w) reg_nt_feed_b <= 1;
        else if (reg_nt_feed_b) reg_nt_feed_b <= 0;
        if (norm_valid_w && reg_nt_canon_tag[5] == 0) begin
          reg_nt_canon_a <= canon0_w;
          reg_nt_canon_a_high <= canon1_w;
          reg_nt_canon_addr_a <= reg_nt_addr_a_pipe[5];
          reg_nt_canon_addr_b <= reg_nt_addr_b_pipe[5];
        end
        if (norm_valid_w && reg_nt_canon_tag[5] == 1) begin
          reg_wr_addr_a[reg_wr_wr] <= reg_nt_canon_addr_a;
          reg_wr_addr_b[reg_wr_wr] <= reg_nt_canon_addr_b;
          reg_wr_data_a[reg_wr_wr] <= {4'd0, reg_nt_canon_a_high, 4'd0, reg_nt_canon_a};
          reg_wr_data_b[reg_wr_wr] <= {4'd0, canon1_w, 4'd0, canon0_w};
          reg_wr_wr <= reg_wr_wr + 1'b1;
        end
        if (reg_nt_slot && reg_wr_count != 0) begin
          reg_wr_rd <= reg_wr_rd + 1'b1;
          reg_nt_write_count <= reg_nt_write_count + 1'b1;
          // Advance the layer after all requests issue and the final pair commits.
          if (reg_nt_write_count == LPARA_NT_ISSUES_PER_LAYER - 1 &&
              reg_nt_issue_count == LPARA_NT_ISSUES_PER_LAYER && reg_meta_count == 0 &&
              !reg_nt_read_pending && reg_wr_count == 1) begin
            if (reg_nt_len == 2) begin
              reg_nt_busy <= 0;
              reg_nt_done <= 1;
            end else begin
              reg_nt_len <= reg_nt_len >> 1;
              reg_nt_group <= 0;
              reg_nt_j <= 0;
              reg_nt_k <= reg_nt_k + 1'b1;
              reg_nt_issue_count <= 0;
              reg_nt_write_count <= 0;
            end
          end
        end else if (reg_nt_write_count == LPARA_NT_ISSUES_PER_LAYER &&
                     reg_nt_issue_count == LPARA_NT_ISSUES_PER_LAYER && reg_wr_count == 0 &&
                     reg_meta_count == 0 && !reg_nt_read_pending) begin
          // Complete after the final pair drains if the commit-edge condition was missed.
          if (reg_nt_len == 2) begin
            reg_nt_busy <= 0;
            reg_nt_done <= 1;
          end else begin
            reg_nt_len <= reg_nt_len >> 1;
            reg_nt_group <= 0;
            reg_nt_j <= 0;
            reg_nt_k <= reg_nt_k + 1'b1;
            reg_nt_issue_count <= 0;
            reg_nt_write_count <= 0;
          end
        end
        case ({
          (norm_valid_w && reg_nt_canon_tag[5] == 1), (reg_nt_slot && reg_wr_count != 0)
        })
          2'b10:   reg_wr_count <= reg_wr_count + 1'b1;
          2'b01:   reg_wr_count <= reg_wr_count - 1'b1;
          default: ;
        endcase
        case ({
          w_nt_issue, bfu_valid_w
        })
          2'b10:   reg_meta_count <= reg_meta_count + 1'b1;
          2'b01:   reg_meta_count <= reg_meta_count - 1'b1;
          default: ;
        endcase
      end
    end
  end
  // p_ff_rm_engine: context file, tag pipes, valid-driven capture, grant and
  // release for the II=12 ROW_MAC machine. Reservation bits (pend_*) are set at
  // issue and cleared at capture; a result arriving without its reservation is
  // a design error, detected from the testbench (no assertions in design RTL).
  // On soft_rst both memory ports are masked the same cycle (drive-side gate),
  // every context/tag/delayed event is voided here and the arithmetic pipelines
  // flush via flush_w during the FLUSH state before the next command.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_ff_rm_engine
    if (!rst_ni) begin
      state_w <= IDLE;
      norm_source_w <= IDLE;
      bank_w <= 0;
      slot_w <= 0;
      flush_count_w <= 0;
      len_w <= 0;
      group_w <= 0;
      j_w <= 0;
      k_w <= 0;
      a_w <= 0;
      b_w <= 0;
      raw_a_w <= 0;
      raw_b_w <= 0;
      word_w <= 0;
      reg_rm_busy <= 1'b0;
      reg_rm_done <= 1'b0;
      reg_rm_row <= 2'd0;
      reg_rm_slot <= 4'd0;
      reg_rm_pair <= 8'd0;
      reg_rm_blk <= 8'd0;
      reg_rm_valid <= 8'd0;
      reg_rm_capv <= 1'b0;
      reg_rm_capctx <= 3'd0;
      reg_rm_capdst <= 3'd0;
      reg_rm_bfu_tagv <= 6'd0;
      reg_rm_can_tagv <= 6'd0;
      reg_rm_bfu_tag[0] <= 7'd0;
      reg_rm_bfu_tag[1] <= 7'd0;
      reg_rm_bfu_tag[2] <= 7'd0;
      reg_rm_bfu_tag[3] <= 7'd0;
      reg_rm_bfu_tag[4] <= 7'd0;
      reg_rm_bfu_tag[5] <= 7'd0;
      reg_rm_can_tag[0] <= 6'd0;
      reg_rm_can_tag[1] <= 6'd0;
      reg_rm_can_tag[2] <= 6'd0;
      reg_rm_can_tag[3] <= 6'd0;
      reg_rm_can_tag[4] <= 6'd0;
      reg_rm_can_tag[5] <= 6'd0;
    end else if (soft_rst_i) begin
      state_w <= FLUSH;
      flush_count_w <= 0;
      a_w <= 0;
      b_w <= 0;
      raw_a_w <= 0;
      raw_b_w <= 0;
      reg_rm_busy <= 1'b0;
      reg_rm_done <= 1'b0;
      reg_rm_pair <= 8'd0;
      reg_rm_slot <= 4'd0;
      reg_rm_blk <= 8'd0;
      reg_rm_valid <= 8'd0;
      reg_rm_capv <= 1'b0;
      reg_rm_bfu_tagv <= 6'd0;
      reg_rm_can_tagv <= 6'd0;
    end else begin
      reg_rm_done <= 1'b0;
      if (reg_rm_busy) begin
        reg_rm_slot <= (reg_rm_slot == 4'd11) ? 4'd0 : (reg_rm_slot + 4'd1);
        if (reg_rm_slot == 4'd11) reg_rm_blk <= reg_rm_blk + 8'd1;
      end
      // age++ at slot-11 edges for contexts older than the youngest block
      if (reg_rm_busy && (reg_rm_slot == 4'd11)) begin
        if (reg_rm_valid[0] && ({1'b0, reg_rm_pair_c[0]} < reg_rm_blk))
          reg_rm_age[0] <= reg_rm_age[0] + 3'd1;
        if (reg_rm_valid[1] && ({1'b0, reg_rm_pair_c[1]} < reg_rm_blk))
          reg_rm_age[1] <= reg_rm_age[1] + 3'd1;
        if (reg_rm_valid[2] && ({1'b0, reg_rm_pair_c[2]} < reg_rm_blk))
          reg_rm_age[2] <= reg_rm_age[2] + 3'd1;
        if (reg_rm_valid[3] && ({1'b0, reg_rm_pair_c[3]} < reg_rm_blk))
          reg_rm_age[3] <= reg_rm_age[3] + 3'd1;
        if (reg_rm_valid[4] && ({1'b0, reg_rm_pair_c[4]} < reg_rm_blk))
          reg_rm_age[4] <= reg_rm_age[4] + 3'd1;
        if (reg_rm_valid[5] && ({1'b0, reg_rm_pair_c[5]} < reg_rm_blk))
          reg_rm_age[5] <= reg_rm_age[5] + 3'd1;
        if (reg_rm_valid[6] && ({1'b0, reg_rm_pair_c[6]} < reg_rm_blk))
          reg_rm_age[6] <= reg_rm_age[6] + 3'd1;
        if (reg_rm_valid[7] && ({1'b0, reg_rm_pair_c[7]} < reg_rm_blk))
          reg_rm_age[7] <= reg_rm_age[7] + 3'd1;
      end
      if (w_rm_gnt) begin
        reg_rm_busy <= 1'b1;
        reg_rm_pair <= w_rm_accept ? 8'd1 : (reg_rm_pair + 8'd1);
        if (w_rm_accept) begin
          reg_rm_slot <= 4'd11;
          reg_rm_blk <= 8'd0;
          reg_rm_row <= pau_row_i;
        end
        reg_rm_valid[w_rm_gnt_idx] <= 1'b1;
        reg_rm_pair_c[w_rm_gnt_idx] <= w_rm_gnt_pair;
        reg_rm_age[w_rm_gnt_idx] <= 3'd0;
        reg_rm_acc[w_rm_gnt_idx] <= 24'd0;
        reg_rm_pend_di[w_rm_gnt_idx] <= 3'd0;
        reg_rm_pend_cr[w_rm_gnt_idx] <= 3'd0;
        reg_rm_pend_ga[w_rm_gnt_idx] <= 3'd0;
        reg_rm_pend_pn[w_rm_gnt_idx] <= 3'd0;
        reg_rm_pend_ac[w_rm_gnt_idx] <= 3'd0;
        reg_rm_pend_sc[w_rm_gnt_idx] <= 1'b0;
        reg_rm_pend_sn[w_rm_gnt_idx] <= 1'b0;
        reg_rm_pend_en[w_rm_gnt_idx] <= 1'b0;
      end
      if (reg_rm_busy && w_rm_v5 && (reg_rm_slot == 4'd5)) begin
        reg_rm_valid[w_rm_i5] <= 1'b0;
        if (w_rm_q5[6:0] == 7'd127) begin
          reg_rm_busy <= 1'b0;
          reg_rm_done <= 1'b1;
        end
      end
      reg_rm_bfu_tagv <= {reg_rm_bfu_tagv[4:0], w_rm_bfu_fire};
      if (w_rm_bfu_fire) reg_rm_bfu_tag[0] <= {w_rm_bfu_ctx, w_rm_bfu_op};
      reg_rm_bfu_tag[1] <= reg_rm_bfu_tag[0];
      reg_rm_bfu_tag[2] <= reg_rm_bfu_tag[1];
      reg_rm_bfu_tag[3] <= reg_rm_bfu_tag[2];
      reg_rm_bfu_tag[4] <= reg_rm_bfu_tag[3];
      reg_rm_bfu_tag[5] <= reg_rm_bfu_tag[4];
      if (w_rm_bfu_fire)
        case (w_rm_bfu_op)
          4'd0, 4'd2, 4'd4: reg_rm_pend_di[w_rm_bfu_ctx][w_rm_bfu_op[2:1]] <= 1'b1;
          4'd1, 4'd3, 4'd5: reg_rm_pend_cr[w_rm_bfu_ctx][w_rm_bfu_op[2:1]] <= 1'b1;
          4'd6: reg_rm_pend_ga[w_rm_bfu_ctx][0] <= 1'b1;
          4'd7: reg_rm_pend_ga[w_rm_bfu_ctx][1] <= 1'b1;
          4'd8: reg_rm_pend_ga[w_rm_bfu_ctx][2] <= 1'b1;
          4'd9: reg_rm_pend_sc[w_rm_bfu_ctx] <= 1'b1;
          default: ;
        endcase
      reg_rm_can_tagv <= {reg_rm_can_tagv[4:0], w_rm_can_fire};
      if (w_rm_can_fire) reg_rm_can_tag[0] <= {w_rm_can_ctx, w_rm_can_op};
      reg_rm_can_tag[1] <= reg_rm_can_tag[0];
      reg_rm_can_tag[2] <= reg_rm_can_tag[1];
      reg_rm_can_tag[3] <= reg_rm_can_tag[2];
      reg_rm_can_tag[4] <= reg_rm_can_tag[3];
      reg_rm_can_tag[5] <= reg_rm_can_tag[4];
      if (w_rm_can_fire)
        case (w_rm_can_op)
          3'd0, 3'd1, 3'd2: reg_rm_pend_pn[w_rm_can_ctx][w_rm_can_op[1:0]] <= 1'b1;
          3'd3: reg_rm_pend_ac[w_rm_can_ctx][0] <= 1'b1;
          3'd4: reg_rm_pend_ac[w_rm_can_ctx][1] <= 1'b1;
          3'd5: reg_rm_pend_ac[w_rm_can_ctx][2] <= 1'b1;
          3'd6: reg_rm_pend_sn[w_rm_can_ctx] <= 1'b1;
          3'd7: reg_rm_pend_en[w_rm_can_ctx] <= 1'b1;
          default: ;
        endcase
      if (reg_rm_busy && bfu_valid_w && reg_rm_bfu_tagv[5])
        case (reg_rm_bfu_tag[5][3:0])
          4'd0, 4'd2, 4'd4: begin
            reg_rm_di[reg_rm_bfu_tag[5][2:1]][reg_rm_bfu_tag[5][6:4]] <= result_a_w;
            reg_rm_pend_di[reg_rm_bfu_tag[5][6:4]][reg_rm_bfu_tag[5][2:1]] <= 1'b0;
          end
          4'd1, 4'd3, 4'd5: begin
            reg_rm_cr[reg_rm_bfu_tag[5][2:1]][reg_rm_bfu_tag[5][6:4]] <= result_a_w;
            reg_rm_pend_cr[reg_rm_bfu_tag[5][6:4]][reg_rm_bfu_tag[5][2:1]] <= 1'b0;
          end
          4'd6: begin
            reg_rm_ga[0][reg_rm_bfu_tag[5][6:4]] <= result_a_w[15:0];
            reg_rm_pend_ga[reg_rm_bfu_tag[5][6:4]][0] <= 1'b0;
          end
          4'd7: begin
            reg_rm_ga[1][reg_rm_bfu_tag[5][6:4]] <= result_a_w[15:0];
            reg_rm_pend_ga[reg_rm_bfu_tag[5][6:4]][1] <= 1'b0;
          end
          4'd8: begin
            reg_rm_ga[2][reg_rm_bfu_tag[5][6:4]] <= result_a_w[15:0];
            reg_rm_pend_ga[reg_rm_bfu_tag[5][6:4]][2] <= 1'b0;
          end
          4'd9: begin
            reg_rm_sc[reg_rm_bfu_tag[5][6:4]] <= result_a_w;
            reg_rm_pend_sc[reg_rm_bfu_tag[5][6:4]] <= 1'b0;
          end
          default: ;
        endcase
      if (reg_rm_busy && norm_valid_w && reg_rm_can_tagv[5])
        case (reg_rm_can_tag[5][2:0])
          3'd0, 3'd1, 3'd2: begin
            reg_rm_c[reg_rm_can_tag[5][1:0]][reg_rm_can_tag[5][5:3]] <= {canon1_w, canon0_w};
            reg_rm_pend_pn[reg_rm_can_tag[5][5:3]][reg_rm_can_tag[5][1:0]] <= 1'b0;
          end
          3'd3: begin
            reg_rm_acc[reg_rm_can_tag[5][5:3]] <= {canon1_w, canon0_w};
            reg_rm_pend_ac[reg_rm_can_tag[5][5:3]][0] <= 1'b0;
          end
          3'd4: begin
            reg_rm_acc[reg_rm_can_tag[5][5:3]] <= {canon1_w, canon0_w};
            reg_rm_pend_ac[reg_rm_can_tag[5][5:3]][1] <= 1'b0;
          end
          3'd5: begin
            reg_rm_acc[reg_rm_can_tag[5][5:3]] <= {canon1_w, canon0_w};
            reg_rm_pend_ac[reg_rm_can_tag[5][5:3]][2] <= 1'b0;
          end
          3'd6: begin
            reg_rm_sn[reg_rm_can_tag[5][5:3]] <= {canon1_w, canon0_w};
            reg_rm_pend_sn[reg_rm_can_tag[5][5:3]] <= 1'b0;
          end
          3'd7: begin
            reg_rm_fi[reg_rm_can_tag[5][5:3]] <= {canon1_w, canon0_w};
            reg_rm_pend_en[reg_rm_can_tag[5][5:3]] <= 1'b0;
          end
          default: ;
        endcase
      if (reg_rm_capv) begin
        if (reg_rm_capdst == 3'd3) reg_rm_e[reg_rm_capctx] <= bram_a_rdata_i;
        else begin
          reg_rm_as_a[reg_rm_capdst[1:0]][reg_rm_capctx] <= bram_a_rdata_i;
          reg_rm_as_b[reg_rm_capdst[1:0]][reg_rm_capctx] <= bram_rdata_i;
        end
      end
      reg_rm_capv <= w_rm_cap_set;
      reg_rm_capctx <= w_rm_cap_set_ctx;
      reg_rm_capdst <= w_rm_cap_set_dst;
      // Legacy NTT transitions remain alongside the pipelined schedulers.
      case (state_w)
        NA: state_w <= NB;
        NB: begin
          a_w <= bram_rdata_i;
          state_w <= NC;
        end
        NC: begin
          b_w <= bram_rdata_i;
          state_w <= NI;
        end
        NI: state_w <= NW;
        NW:
        if (bfu_valid_w) begin
          raw_a_w <= result_a_w;
          raw_b_w <= result_b_w;
          state_w <= NORM_A;
        end
        NORM_A, NORM_B: begin
          norm_source_w <= state_w;
          state_w <= NORM_WAIT;
        end
        NORM_WAIT:
        if (norm_valid_w)
          case (norm_source_w)
            NORM_A: begin
              word_w <= {4'd0, canon1_w, 4'd0, canon0_w};
              state_w <= WRITE_A;
            end
            NORM_B: begin
              word_w <= {4'd0, canon1_w, 4'd0, canon0_w};
              state_w <= WRITE_B;
            end
            default: state_w <= IDLE;
          endcase
        WRITE_A: state_w <= NORM_B;
        WRITE_B: begin
          if (j_w + 9'd2 < group_w + len_w) begin
            j_w <= j_w + 9'd2;
            state_w <= NA;
          end else if (group_w + (len_w << 1) < 9'd256) begin
            group_w <= group_w + (len_w << 1);
            j_w <= group_w + (len_w << 1);
            k_w <= k_w + 1'b1;
            state_w <= NA;
          end else if (len_w > 2) begin
            len_w <= len_w >> 1;
            group_w <= 0;
            j_w <= 0;
            k_w <= k_w + 1'b1;
            state_w <= NA;
          end else state_w <= DONE;
        end
        DONE: state_w <= IDLE;
        FLUSH:
        if (flush_count_w == 7) state_w <= IDLE;
        else flush_count_w <= flush_count_w + 1'b1;
        default: state_w <= IDLE;
      endcase
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk_i)
    if (rst_ni && !soft_rst_i) begin
      if (reg_nt_busy && (reg_meta_count > 8 || reg_wr_count > 16))
        $fatal(1, "PAU NTT queue capacity exceeded");
      if (reg_nt_busy && norm_valid_w != reg_nt_canon_valid[5])
        $fatal(1, "PAU canonical valid/tag pipeline mismatch");
      if (pau_start_i) begin
        assert (state_w == IDLE && !reg_nt_busy && !reg_rm_busy)
        else $fatal(1, "PAU start while busy");
        assert (pau_cmd_i < 2)
        else $fatal(1, "PAU invalid command");
        if (pau_cmd_i == 0)
          assert (pau_bank_sel_i < 3 && pau_slot_src_i < 2 && pau_slot_src_i == pau_slot_dst_i)
          else $fatal(1, "PAU invalid NTT descriptor");
        else
          assert (pau_row_i < 3)
          else $fatal(1, "PAU invalid row");
      end
      if (bram_we_o)
        assert (bram_bank_o < 3 && bram_wdata_o[15:0] < 3329 && bram_wdata_o[31:16] < 3329)
        else $fatal(1, "PAU noncanonical write");
    end
`endif
endmodule
