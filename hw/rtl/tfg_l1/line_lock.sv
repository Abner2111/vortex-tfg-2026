// TFG: candado por línea entre los NUM_L1 l1_cache.sv de un mismo cluster
// -- ver VX_line_lock_if.sv para el porqué y el protocolo.
//
// Una tabla de NUM_L1 slots, uno por núcleo (cada núcleo tiene como mucho
// un miss en vuelo a la vez, mismo supuesto que ya usa el resto de
// l1_cache.sv -- no hace falta más slots que núcleos). req_ready[i] se
// otorga solo si:
//   (a) el slot propio de i está libre,
//   (b) ningún OTRO slot ya registrado tiene la misma dirección, y
//   (c) ningún otro núcleo con índice MÁS BAJO pide la MISMA dirección
//       este mismo ciclo -- prioridad fija, mismo criterio de desempate
//       que snoop_bus.sv ya usa ("el índice más bajo gana").
// rel_valid[i] libera el slot propio.

`include "VX_define.vh"

module line_lock #(
    parameter NUM_L1     = 4,
    parameter ADDR_WIDTH = 32
) (
    input wire clk,
    input wire reset,

    VX_line_lock_if.slave req_if [NUM_L1]
);
    logic [NUM_L1-1:0]     slot_valid;
    logic [ADDR_WIDTH-1:0] slot_addr [NUM_L1];

    logic [NUM_L1-1:0]     req_valid_flat;
    logic [ADDR_WIDTH-1:0] req_addr_flat [NUM_L1];
    logic [NUM_L1-1:0]     rel_valid_flat;
    for (genvar k = 0; k < NUM_L1; ++k) begin : g_flatten
        assign req_valid_flat[k] = req_if[k].req_valid;
        assign req_addr_flat[k]  = req_if[k].req_addr;
        assign rel_valid_flat[k] = req_if[k].rel_valid;
    end

    logic [NUM_L1-1:0] grant;
    always_comb begin
        for (int i = 0; i < NUM_L1; ++i) begin
            logic conflict;
            conflict = 1'b0;
            for (int j = 0; j < NUM_L1; ++j)
                if (j != i && slot_valid[j] && slot_addr[j] == req_addr_flat[i])
                    conflict = 1'b1;
            for (int j = 0; j < i; ++j)
                if (req_valid_flat[j] && !slot_valid[j] && req_addr_flat[j] == req_addr_flat[i])
                    conflict = 1'b1;
            grant[i] = req_valid_flat[i] && !slot_valid[i] && !conflict;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            slot_valid <= '0;
        end else begin
            for (int i = 0; i < NUM_L1; ++i) begin
                if (grant[i]) begin
                    slot_valid[i] <= 1'b1;
                    slot_addr[i]  <= req_addr_flat[i];
                    `TRACE(2, ("%t: line_lock grant[%0d]: addr=%0h\n", $time, i, req_addr_flat[i]))
                end else if (rel_valid_flat[i]) begin
                    slot_valid[i] <= 1'b0;
                    `TRACE(2, ("%t: line_lock release[%0d]\n", $time, i))
                end
            end
        end
    end

    for (genvar i = 0; i < NUM_L1; ++i) begin : g_grant
        assign req_if[i].req_ready = grant[i];
    end

endmodule
