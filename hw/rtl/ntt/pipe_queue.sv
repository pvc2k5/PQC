/*
 * Project      : ML-KEM-768 Hardware Accelerator
 * Author       : Chien Pham (user)
 * Date         : 2026-10-27
 * Description  : Delays data through a parameterized pipeline.
 */
// Original author: Xavier Carril

module pipe_queue #(
    parameter DATA_WIDTH = 8,  // Width of the input/output signals
    parameter PIPE_DEPTH = 4   // Number of pipeline stages
) (
  input logic clk_i,    // Clock signal
  input logic rstn_i,   // Active-low reset signal
  input logic flush_i,  // Flush signal
  input logic [DATA_WIDTH-1:0] data_i,   // Input signal
  output logic [DATA_WIDTH-1:0] data_o    // Output signal
);

  // Array of pipeline registers
  logic [DATA_WIDTH-1:0] pipeline[0:PIPE_DEPTH-1];

  // Sequential logic for the pipeline
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      // Reset all pipeline stages to zero
      for (int i = 0; i < PIPE_DEPTH; i++) begin
        pipeline[i] <= {DATA_WIDTH{1'b0}};
      end
    end else begin
      if (flush_i) begin
        // Reset all pipeline stages to zero
        for (int i = 0; i < PIPE_DEPTH; i++) begin
          pipeline[i] <= {DATA_WIDTH{1'b0}};
        end
      end else begin
        // Shift data through the pipeline stages
        pipeline[0] <= data_i;  // First stage gets the input
        for (int i = 1; i < PIPE_DEPTH; i++) begin
          pipeline[i] <= pipeline[i-1];
        end
      end
    end
  end

  // Assign the output to the last stage of the pipeline
  assign data_o = pipeline[PIPE_DEPTH-1];

endmodule
