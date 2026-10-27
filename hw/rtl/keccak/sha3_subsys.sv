/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Sequences the SHA-3 and SHAKE jobs used by ML-KEM-768 KeyGen.
 */
`ifndef SHA3_SUBSYS_SV
`define SHA3_SUBSYS_SV
module sha3_subsys
  import keccak_globals::*;
#(
    parameter int ROUNDS = 1
) (
  input logic clk_i,
  input logic rst_ni,
  // Control from Control Unit
  // start_i  : pulse 1 cycle -> latch d_i, begin 16-job sequence.
  //            Accepted in any state (aborts current run).
  // soft_rst_i: abort & return to IDLE without full system reset.
  input logic start_i,
  input logic soft_rst_i,
  // Seed from CSR
  // d_i[7:0] = byte 0 (LSByte). Must be stable when start_i is asserted.
  input logic [255:0] d_i,
  // Status to Control Unit
  output logic busy_o,     // 1 while any job is running
  output logic done_o,     // 1-cycle pulse when all 16 jobs done
  output logic [3:0] job_id_o,   // current job index 0..15
  output logic [1:0] job_type_o, // 0=SHA3-512  1=SHAKE128  2=SHAKE256
  // Squeeze stream to Sampler Unit
  // Active for Jobs 1-15 only. Job 0 output is captured internally.
  output logic sq_valid_o,
  input logic sq_ready_i,
  output logic [63:0] sq_data_o,
  // Feedback from Sampler
  // sampler_done_i: 1-cycle pulse from Sampler when 256 coefficients collected.
  // Only meaningful for Jobs 1-9 (SHAKE128 / SampleNTT).
  // Ignored for Jobs 10-15 (SHAKE256 / SamplePolyCBD - fixed 16-word squeeze).
  input logic sampler_done_i,
  // Public seed and sequential SHA3-256 service using the same sponge.
  // rho_valid_o remains set after Job 0 completes until reset, soft_rst, or start.
  // hash_start_i is accepted only in IDLE; the source holds data/keep/last
  // stable while hash_valid_i=1 and hash_ready_o=0.
  output logic [255:0] rho_o,
  output logic rho_valid_o,
  input logic hash_start_i,
  input logic hash_valid_i,
  output logic hash_ready_o,
  input logic [63:0] hash_data_i,
  input logic [7:0] hash_keep_i,
  input logic hash_last_i,
  output logic [255:0] hash_digest_o,
  output logic hash_done_o
);
  // Constants
  localparam int K          = 3;                  // ML-KEM-768
  localparam int TOTAL_JOBS = 1 + K * K + 2 * K;  // 1 + 9 + 6 = 16
  // SHA3-512 squeeze words to capture
  localparam int NOUT_G   = 8;   // 64 bytes
  // SHAKE256 fixed squeeze words for SamplePolyCBD
  localparam int NOUT_CBD = 16;  // 128 bytes
  // FSM state encoding
  // KeyGen job sequence: START_KECCAK -> FEED -> SQUEEZE, then repeat.
  // After Job 15: SQUEEZE -> DONE -> IDLE.
  // Hash service sequence: HASH_START -> HASH_FEED -> HASH_SQUEEZE -> HASH_DONE -> IDLE.
  typedef enum logic [3:0] {
    IDLE,
    START_KECCAK,  // 1-cycle: pulse keccak_stream.start_i
    FEED,          // absorb phase: push seed words into keccak_stream
    SQUEEZE,       // squeeze phase: drain output
    DONE,          // 1-cycle: assert done_o, return to IDLE
    HASH_START,
    HASH_FEED,
    HASH_SQUEEZE,
    HASH_DONE
  } fsm_state_t;
  fsm_state_t state;
  // [A] Seed Latch registers
  // This Level 1 group contains sequence and seed registers,
  // the counters below, and the final always_ff process. d_q captures d_i at start_i;
  // Job 0 results rho_q and sigma_q seed the remaining jobs.
  // hash_digest_q_w holds the SHA3-256 digest for external readback after hash_done_o.
  logic [255:0] d_q;  // latched seed d
  logic [255:0] rho_q;  // First 32 bytes of SHA3-512(d || 03).
  logic [255:0] sigma_q;  // Last 32 bytes of SHA3-512(d || 03).
  logic rho_valid_q_w;
  logic [255:0] hash_digest_q_w;
  logic interface_enable_w;
  logic hash_mode_w;
  logic [1:0] keccak_mode_w;
  // Block interfaces during reset, abort, and restart to prevent stale-word acceptance.
  assign interface_enable_w = rst_ni && !soft_rst_i && !start_i;
  assign hash_mode_w = (state == HASH_START || state == HASH_FEED || state == HASH_SQUEEZE ||
                        state == HASH_DONE);
  // FSM counters
  logic [3:0] job_cnt;  // 0..15
  logic [2:0] word_cnt;  // 0..4 (words fed per job; max 5)
  logic [4:0] sq_cnt;  // 0..31 (squeeze word counter)
  // [B] Seed Word MUX - derived signals (combinational)
  // word_cnt selects one of four seed words, and
  // the final word contains the suffix. The first byte is always in data[7:0].
  //   Job 0: d || 03, 33 bytes; final word has keep=01.
  //   Jobs 1-9: rho || j || i, 34 bytes; final word has keep=03.
  //   Jobs 10-15: sigma || N, 33 bytes; final word has keep=01, N=0..5.
  // keep[b]=1 marks byte b valid; last=1 marks the final message word.
  // This is combinational logic: an unchanged word_cnt keeps the selected word unchanged.
  // Number of words to feed (last word index = num_words)
  // All jobs feed 5 words (Job 0: 33 bytes, Jobs 1-9: 34 bytes, Jobs 10-15: 33 bytes)
  logic [2:0] num_words;
  assign num_words = 3'd4;  // index of last word (always 4)
  // Hash mode for keccak_stream
  // 2'd0=SHAKE128  2'd1=SHAKE256  2'd3=SHA3-512
  logic [1:0] feed_mode;
  assign keccak_mode_w = hash_mode_w ? 2'd2 : feed_mode;
  always_comb begin
    case (job_cnt)
      4'd0:                                                 feed_mode = 2'd3;  // SHA3-512
      4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9: feed_mode = 2'd0;  // SHAKE128
      default:                                              feed_mode = 2'd1;  // SHAKE256
    endcase
  end
  // Matrix coordinates are explicit to avoid synthesized division/remainder.
  logic [7:0] ij_i;
  logic [7:0] ij_j;
  always_comb begin
    ij_i = 8'd0;
    ij_j = 8'd0;
    case (job_cnt)
      4'd1: begin
        ij_i = 8'd0;
        ij_j = 8'd0;
      end
      4'd2: begin
        ij_i = 8'd0;
        ij_j = 8'd1;
      end
      4'd3: begin
        ij_i = 8'd0;
        ij_j = 8'd2;
      end
      4'd4: begin
        ij_i = 8'd1;
        ij_j = 8'd0;
      end
      4'd5: begin
        ij_i = 8'd1;
        ij_j = 8'd1;
      end
      4'd6: begin
        ij_i = 8'd1;
        ij_j = 8'd2;
      end
      4'd7: begin
        ij_i = 8'd2;
        ij_j = 8'd0;
      end
      4'd8: begin
        ij_i = 8'd2;
        ij_j = 8'd1;
      end
      4'd9: begin
        ij_i = 8'd2;
        ij_j = 8'd2;
      end
      default: ;
    endcase
  end
  // N counter for SHAKE256 jobs (jobs 10-15: N = job_cnt - 10).
  logic [7:0] cbd_n;
  assign cbd_n = 8'(job_cnt - 4'd10);
  // Feed data word mux
  logic [63:0] feed_data;
  logic [7:0] feed_keep;
  logic feed_last;
  always_comb begin
    // defaults
    feed_data = '0;
    feed_keep = 8'hFF;
    feed_last = (word_cnt == num_words);
    if (job_cnt == 4'd0) begin
      // Job 0: SHA3-512(d || k), 33 bytes (FIPS 203, Section 5.1, k=3).
      case (word_cnt)
        3'd0: feed_data = d_q[63:0];
        3'd1: feed_data = d_q[127:64];
        3'd2: feed_data = d_q[191:128];
        3'd3: feed_data = d_q[255:192];
        3'd4: begin
          feed_data = {56'd0, 8'(K)};  // byte 32 = k (0x03 for ML-KEM-768)
          feed_keep = 8'h01;
        end
        default: feed_data = '0;
      endcase
    end else if (job_cnt <= 4'd9) begin
      // Job 1-9: SHAKE128(rho || j || i) - 5 words
      // Bytes 0-31: rho (4 words x 8 bytes)
      // Byte 32: j (column index)
      // Byte 33: i (row index)
      // -> word 4 = {48'd0, i, j}  with keep=8'h03 (2 valid bytes)
      case (word_cnt)
        3'd0: feed_data = rho_q[63:0];
        3'd1: feed_data = rho_q[127:64];
        3'd2: feed_data = rho_q[191:128];
        3'd3: feed_data = rho_q[255:192];
        3'd4: begin
          feed_data = {48'd0, ij_i, ij_j};  // byte0=j, byte1=i
          feed_keep = 8'h03;
        end
        default: feed_data = '0;
      endcase
    end else begin
      // Job 10-15: SHAKE256(sigma || N) - 5 words
      // Bytes 0-31: sigma (4 words x 8 bytes)
      // Byte 32: N
      // -> word 4 = {56'd0, N}  with keep=8'h01 (1 valid byte)
      case (word_cnt)
        3'd0: feed_data = sigma_q[63:0];
        3'd1: feed_data = sigma_q[127:64];
        3'd2: feed_data = sigma_q[191:128];
        3'd3: feed_data = sigma_q[255:192];
        3'd4: begin
          feed_data = {56'd0, cbd_n};
          feed_keep = 8'h01;
        end
        default: feed_data = '0;
      endcase
    end
  end
  // [D] keccak_stream instance
  // This instance performs the hash computation and is sha3_subsys's only submodule.
  // kck_start initializes the sponge for a new message; mode selects SHA3 or SHAKE.
  // A word is accepted on the clock edge when kck_s_valid && kck_s_ready.
  // SQU emits a word when kck_m_valid && kck_m_ready.
  // The instance contains the 1600-bit state, padding, and Keccak round sequence.
  logic kck_start;
  logic kck_s_valid;
  logic kck_s_ready;
  logic [63:0] kck_s_data;
  logic [7:0] kck_s_keep;
  logic kck_s_last;
  logic kck_m_valid;
  logic kck_m_ready;
  logic [63:0] kck_m_data;
  logic kck_perm_busy;
  keccak_stream #(
      .ROUNDS(ROUNDS)
  ) u_keccak (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .start_i    (kck_start),
    .mode_i     (keccak_mode_w),
    .perm_busy_o(kck_perm_busy),
    .s_valid_i  (kck_s_valid),
    .s_ready_o  (kck_s_ready),
    .s_data_i   (kck_s_data),
    .s_keep_i   (kck_s_keep),
    .s_last_i   (kck_s_last),
    .m_valid_o  (kck_m_valid),
    .m_ready_i  (kck_m_ready),
    .m_data_o   (kck_m_data)
  );
  // [E] Squeeze Router (combinational)
  // Route u_keccak output to the selected stream destination.
  // Job 0 feeds rho_q/sigma_q into the FSM; internal ready is always high.
  // Jobs 1-15 route to the sampler, using sq_ready_i as ready.
  // HASH_SQUEEZE routes to hash_digest_q_w; internal ready is always high.
  // When the sampler lowers ready, u_keccak holds the current word until the next handshake.
  // Job 0 and hash-service data are not routed to the sq_* ports.
  always_comb begin
    if (interface_enable_w && state == SQUEEZE && job_cnt == 4'd0) begin
      // Job 0: capture internally; keccak always ready, no external output
      kck_m_ready = 1'b1;
      sq_valid_o = 1'b0;
      sq_data_o = '0;
    end else if (interface_enable_w && state == SQUEEZE) begin
      // Jobs 1-15: forward squeeze stream to Sampler with back-pressure
      kck_m_ready = sq_ready_i;
      sq_valid_o = kck_m_valid;
      sq_data_o = kck_m_data;
    end else if (interface_enable_w && state == HASH_SQUEEZE) begin
      kck_m_ready = 1'b1;
      sq_valid_o = 1'b0;
      sq_data_o = '0;
    end else begin
      kck_m_ready = 1'b0;
      sq_valid_o = 1'b0;
      sq_data_o = '0;
    end
  end
  // [C] Feeder FSM
  // Absorb-side wiring to keccak_stream
  // The remaining router selects formatter output in FEED and external
  // hash_data/keep/last in HASH_FEED.
  // In FEED, valid stays high when interface_enable_w=1, so the FSM only needs to
  // check kck_s_ready to determine whether the seed word was accepted.
  assign
      kck_s_valid = interface_enable_w && ((state == FEED) || (state == HASH_FEED && hash_valid_i));
  assign kck_s_data = (state == HASH_FEED) ? hash_data_i : feed_data;
  assign kck_s_keep = (state == HASH_FEED) ? hash_keep_i : feed_keep;
  assign kck_s_last = (state == HASH_FEED) ? hash_last_i : feed_last;
  assign kck_start = interface_enable_w && (state == START_KECCAK || state == HASH_START);
  assign hash_ready_o = interface_enable_w && state == HASH_FEED && kck_s_ready;
  assign rho_o = rho_q;
  assign rho_valid_o = rho_valid_q_w && rst_ni && !soft_rst_i && !start_i;
  assign hash_digest_o = hash_digest_q_w;
  assign hash_done_o = interface_enable_w && state == HASH_DONE;
  // Status outputs
  // busy_o covers both services. done_o marks only completion of the 16-job
  // KeyGen SHA3 sequence; hash_done_o completes the separate digest service.
  assign busy_o = (state != IDLE);
  assign done_o = interface_enable_w && (state == DONE);
  assign job_id_o = job_cnt;
  assign job_type_o = (job_cnt == 4'd0) ? 2'd0 : (job_cnt <= 4'd9) ? 2'd1 : 2'd2;
  // Squeeze-done conditions
  // The FSM below uses the completion conditions and
  // handshake directly. squeeze_done is not used for state decisions.
  logic squeeze_done;
  always_comb begin
    case (1'b1)
      (job_cnt == 4'd0):        squeeze_done = (sq_cnt == 5'(NOUT_G - 1));
      (job_cnt >= 4'd10):       squeeze_done = (sq_cnt == 5'(NOUT_CBD - 1));
      default  /* jobs 1-9 */ : squeeze_done = sampler_done_i;
    endcase
  end
  // Sequential FSM
  // Priority: hardware reset, soft reset, KeyGen start, then hash_start in IDLE.
  // Soft reset aborts the wrapper and isolates its interfaces. The sponge is reset
  // by kck_start on the next command; abort needs no additional start pulse.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state <= IDLE;
      job_cnt <= '0;
      word_cnt <= '0;
      sq_cnt <= '0;
      d_q <= '0;
      rho_q <= '0;
      sigma_q <= '0;
      rho_valid_q_w <= 1'b0;
      hash_digest_q_w <= '0;
    end else if (soft_rst_i) begin
      // Abort: return to IDLE; keccak_stream will be reset by next start_i
      state <= IDLE;
      job_cnt <= '0;
      word_cnt <= '0;
      sq_cnt <= '0;
      rho_valid_q_w <= 1'b0;
      hash_digest_q_w <= '0;
    end else if (start_i) begin
      // (Re)start: latch seed, reset counters, kick off Job 0
      d_q <= d_i;
      job_cnt <= '0;
      word_cnt <= '0;
      sq_cnt <= '0;
      rho_q <= '0;
      sigma_q <= '0;
      rho_valid_q_w <= 1'b0;
      hash_digest_q_w <= '0;
      state <= START_KECCAK;
    end else if (hash_start_i && state == IDLE) begin
      hash_digest_q_w <= '0;
      sq_cnt <= '0;
      state <= HASH_START;
    end else begin
      unique case (state)
        IDLE: ;  // wait for start_i
        // START_KECCAK: pulse keccak start for 1 cycle
        START_KECCAK: begin
          word_cnt <= '0;
          sq_cnt <= '0;
          state <= FEED;
        end
        // FEED: push seed words into keccak_stream
        FEED: begin
          if (kck_s_ready) begin  // handshake accepted
            if (word_cnt == num_words) begin
              // last word sent -> move to SQUEEZE
              state <= SQUEEZE;
              sq_cnt <= '0;
            end else begin
              word_cnt <= word_cnt + 3'd1;
            end
          end
        end
        // SQUEEZE: drain output from keccak_stream
        SQUEEZE: begin
          // A word is consumed when both sides are ready
          if (kck_m_valid && kck_m_ready) begin
            // [A] Capture rho/sigma from Job 0
            // SHA3-512 returns eight words: words 0-3 are rho and 4-7 are sigma.
            // Mark rho valid only after the eighth word has been fully received.
            if (job_cnt == 4'd0) begin
              case (sq_cnt)
                5'd0:    rho_q[63:0] <= kck_m_data;
                5'd1:    rho_q[127:64] <= kck_m_data;
                5'd2:    rho_q[191:128] <= kck_m_data;
                5'd3:    rho_q[255:192] <= kck_m_data;
                5'd4:    sigma_q[63:0] <= kck_m_data;
                5'd5:    sigma_q[127:64] <= kck_m_data;
                5'd6:    sigma_q[191:128] <= kck_m_data;
                5'd7: begin
                  sigma_q[255:192] <= kck_m_data;
                  rho_valid_q_w <= 1'b1;
                end
                default: ;
              endcase
            end
            sq_cnt <= sq_cnt + 5'd1;
          end
          // Check squeeze completion:
          // For jobs 1-9: sampler_done_i signals completion.
          // For jobs 0 and 10-15: requires valid handshake on the final word.
          // The wrapper does not impose a fixed SHAKE128 length; the sampler signals completion
          // after 256 coefficients via sampler_done_i. SHAKE256 receives exactly 16 words per job:
          // Jobs 10-12 provide s data; jobs 13-15 provide e data.
          if ((job_cnt >= 4'd1 && job_cnt <= 4'd9 && sampler_done_i) ||
              (job_cnt == 4'd0 && kck_m_valid && kck_m_ready && sq_cnt == 5'(NOUT_G - 1)) ||
              (job_cnt >= 4'd10 && kck_m_valid && kck_m_ready && sq_cnt == 5'(NOUT_CBD - 1))) begin
            if (job_cnt == 4'(TOTAL_JOBS - 1)) begin
              state <= DONE;
            end else begin
              job_cnt <= job_cnt + 4'd1;
              word_cnt <= '0;
              sq_cnt <= '0;
              state <= START_KECCAK;
            end
          end
        end
        // DONE: emit done_o pulse
        DONE: begin
          state <= IDLE;
          job_cnt <= '0;
        end
        // Reuse the sponge for SHA3-256 while retaining the stored rho.
        HASH_START: begin
          sq_cnt <= '0;
          state <= HASH_FEED;
        end
        // Advance to squeeze only after the beat with last=1 handshakes. If the sponge
        // is permuting between blocks, hash_ready_o is low and the source waits.
        HASH_FEED: begin
          if (hash_valid_i && hash_ready_o && hash_last_i) begin
            sq_cnt <= '0;
            state <= HASH_SQUEEZE;
          end
        end
        // Assemble four 64-bit words into a 256-bit digest; the first word occupies bits [63:0].
        HASH_SQUEEZE: begin
          if (kck_m_valid && kck_m_ready) begin
            hash_digest_q_w[64*sq_cnt[1:0]+:64] <= kck_m_data;
            if (sq_cnt == 5'd3) begin
              state <= HASH_DONE;
            end else begin
              sq_cnt <= sq_cnt + 5'd1;
            end
          end
        end
        // hash_done_o is decoded from this state and is high for one cycle.
        HASH_DONE: state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
`endif  // SHA3_SUBSYS_SV
