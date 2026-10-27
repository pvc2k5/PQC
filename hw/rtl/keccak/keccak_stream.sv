/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham
 * Date         : 2026-10-27
 * Description  : Implements the streaming SHA-3 and SHAKE sponge engine.
 */
// Original author: Xavier Carril

module keccak_stream
  import keccak_globals::*;
#(
    parameter int ROUNDS = 1
) (
  input logic clk_i,
  input logic rst_ni,

  // controlg
  input logic start_i,
  input logic [1:0] mode_i,
  output logic perm_busy_o, // high while a permutation is running

  // absorb stream
  input logic s_valid_i,
  output logic s_ready_o,
  input logic [63:0] s_data_i,
  input logic [7:0] s_keep_i,
  input logic s_last_i,

  // squeeze stream
  output logic m_valid_o,
  input logic m_ready_i,
  output logic [63:0] m_data_o
);

  // --------------------------------------------------------------- constants
  typedef enum logic [2:0] {
    S_IDLE,
    S_ABSORB,
    S_PAD,
    S_PERM,
    S_SQUEEZE
  } state_t;
  state_t state;
  state_t next_after_perm;

  logic [1:0] mode_q;
  logic [4:0] rate_lanes;  // lanes in the rate part
  logic [7:0] ds_byte;  // domain-separation byte

  always_comb begin
    case (mode_q)
      2'd0:    rate_lanes = 5'd21;
      2'd1:    rate_lanes = 5'd17;
      2'd2:    rate_lanes = 5'd17;
      default: rate_lanes = 5'd9;
    endcase
    ds_byte = (mode_q[1]) ? 8'h06 : 8'h1F;
  end

  // ------------------------------------------------------------------- state
  logic [63:0] st                                                        [25];
  logic [4:0] pos;  // current lane in the rate part
  logic [2:0] boff;  // byte offset inside lane `pos` (padding position)
  logic [4:0] rnd;  // round counter 0, ROUNDS, 2*ROUNDS ...

  // Keccak round chain (combinational, ROUNDS rounds per clock)
  k_state round_in;
  k_state [ROUNDS-1:0] round_out;
  logic [ROUNDS-1:0][6:0] rc;

  always_comb begin
    for (int y = 0; y < 5; y++) for (int x = 0; x < 5; x++) round_in[y][x] = st[5*y+x];
  end

  for (genvar r = 0; r < ROUNDS; r++) begin : g_round
    keccak_round_constants_gen_simplified u_rc (
      .round_number             (5'(rnd + r)),
      .round_constant_signal_out(rc[r])
    );
    keccak_round u_round (
      .round_in             ((r == 0) ? round_in : round_out[(r == 0) ? 0 : r - 1]),
      .round_constant_signal(rc[r]),
      .round_out            (round_out[r])
    );
  end

  // ------------------------------------------------------ input word helpers
  logic [63:0] mask;
  logic [63:0] din_masked;
  logic [3:0] nbytes;

  always_comb begin
    for (int b = 0; b < 8; b++) mask[8*b+:8] = (s_last_i && !s_keep_i[b]) ? 8'h00 : 8'hFF;
    din_masked = s_data_i & mask;
    nbytes = 4'd8;
    if (s_last_i) begin
      nbytes = 4'd0;
      for (int b = 0; b < 8; b++) nbytes = nbytes + 4'(s_keep_i[b]);
    end
  end

  assign s_ready_o = (state == S_ABSORB);
  assign perm_busy_o = (state == S_PERM);
  assign m_valid_o = (state == S_SQUEEZE);
  assign m_data_o = st[pos];

  // -------------------------------------------------------------------- FSM
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state <= S_IDLE;
      next_after_perm <= S_IDLE;
      mode_q <= '0;
      pos <= '0;
      boff <= '0;
      rnd <= '0;
      for (int i = 0; i < 25; i++) st[i] <= '0;
    end else if (start_i) begin
      state <= S_ABSORB;
      mode_q <= mode_i;
      pos <= '0;
      boff <= '0;
      rnd <= '0;
      for (int i = 0; i < 25; i++) st[i] <= '0;
    end else begin
      unique case (state)
        S_IDLE: ;

        S_ABSORB: begin
          if (s_valid_i) begin
            for (int i = 0; i < 25; i++) if (i == pos) st[i] <= st[i] ^ din_masked;

            if (!s_last_i) begin
              if (pos == rate_lanes - 5'd1) begin
                pos <= '0;
                rnd <= '0;
                next_after_perm <= S_ABSORB;
                state <= S_PERM;
              end else begin
                pos <= pos + 5'd1;
              end
            end else begin
              // last word: decide where the domain byte goes
              if (nbytes == 4'd8) begin
                boff <= 3'd0;
                if (pos == rate_lanes - 5'd1) begin
                  // block exactly full -> permute, then pad in lane 0
                  pos <= '0;
                  rnd <= '0;
                  next_after_perm <= S_PAD;
                  state <= S_PERM;
                end else begin
                  pos <= pos + 5'd1;
                  state <= S_PAD;
                end
              end else begin
                boff <= nbytes[2:0];
                state <= S_PAD;
              end
            end
          end
        end

        S_PAD: begin
          for (int i = 0; i < 25; i++) begin
            if (i == pos)
              st[i] <= st[i] ^ (64'(ds_byte) << (8 * boff)) ^
                  ((i == rate_lanes - 1) ? 64'h8000_0000_0000_0000 : 64'h0);
            else if (i == rate_lanes - 1) st[i] <= st[i] ^ 64'h8000_0000_0000_0000;
          end
          pos <= '0;
          rnd <= '0;
          next_after_perm <= S_SQUEEZE;
          state <= S_PERM;
        end

        S_PERM: begin
          for (int y = 0; y < 5; y++)
          for (int x = 0; x < 5; x++) st[5*y+x] <= round_out[ROUNDS-1][y][x];
          if (rnd == 5'(24 - ROUNDS)) begin
            rnd <= '0;
            state <= next_after_perm;
          end else begin
            rnd <= rnd + 5'(ROUNDS);
          end
        end

        S_SQUEEZE: begin
          if (m_ready_i) begin
            if (pos == rate_lanes - 5'd1) begin
              pos <= '0;
              rnd <= '0;
              next_after_perm <= S_SQUEEZE;
              state <= S_PERM;
            end else begin
              pos <= pos + 5'd1;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
