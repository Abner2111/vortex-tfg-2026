// A-7: interconexión de snoop entre NUM_L1 caches L1.
//
// Cada L1 se conecta con DOS puertos VX_snoop_bus_if (ver l1_cache.sv):
//   - req_if[i] : la consulta PROPIA de l1_cache[i] (su modport .master).
//                 Desde acá el bus la RECIBE -> modport .snooper.
//   - rsp_if[i] : el broadcast hacia l1_cache[i] (su modport .snooper).
//                 Desde acá el bus lo EMITE -> modport .master.
//
// Diseño (deliberadamente simple, un solo broadcast en vuelo a la vez):
//   1. BUS_IDLE:      arbitra entre los req_if con snoop_valid (prioridad
//                      fija, el índice más bajo gana) y arranca un broadcast.
//   2. BUS_BROADCAST: le hace la consulta a todos los OTROS L1 (todos
//                      menos el que pidió) y espera a que TODOS respondan
//                      ready, acumulando el OR de sus `hit`.
//   3. BUS_DONE:      le contesta al que pidió: ready=1, hit=OR acumulado.
//
//


`include "VX_define.vh"

// LINE_SIZE no se usa acá adentro (snoop_data se deja en 0 siempre, ver
// más abajo) -- se declara solo para que los parámetros de este módulo
// calcen con los de VX_snoop_bus_if #(.LINE_SIZE(...)) en la instancia.
/* verilator lint_off UNUSEDPARAM */
module snoop_bus #(
    parameter NUM_L1     = 4,
    parameter ADDR_WIDTH = 32,
    parameter LINE_SIZE  = 64
) (
    input wire clk,
    input wire reset,

    VX_snoop_bus_if.snooper req_if [NUM_L1],
    VX_snoop_bus_if.master  rsp_if [NUM_L1]
);
    localparam GRANT_BITS = `LOG2UP(NUM_L1);

    typedef enum logic [1:0] { BUS_IDLE, BUS_BROADCAST, BUS_DONE } bus_state_t;
    bus_state_t bus_state;

    logic [GRANT_BITS-1:0] grant_r;
    logic [ADDR_WIDTH-1:0] addr_r;
    logic                  rw_r;
    logic [NUM_L1-1:0]     pending_r;
    logic                  hit_acc_r;

    // Un array de interfaces no se puede indexar con una variable en
    // tiempo de ejecución, solo con genvar (limitación de la herramienta
    // de simulación) -> se "aplanan" acá los campos que hace
    // falta leer con un índice que no es constante (grant_idx, el for de
    // arbitraje, el for de recolección de respuestas). Los assigns con
    // genvar (más abajo, para manejar req_if[i]/rsp_if[j] con índice
    // constante) no tienen este problema.
    logic [NUM_L1-1:0]     req_valid_flat;
    logic [ADDR_WIDTH-1:0] req_addr_flat [NUM_L1];
    logic [NUM_L1-1:0]     req_rw_flat;
    logic [NUM_L1-1:0]     rsp_ready_flat;
    logic [NUM_L1-1:0]     rsp_hit_flat;
    for (genvar k = 0; k < NUM_L1; ++k) begin : g_flatten
        assign req_valid_flat[k] = req_if[k].snoop_valid;
        assign req_addr_flat[k]  = req_if[k].snoop_addr;
        assign req_rw_flat[k]    = req_if[k].snoop_rw;
        assign rsp_ready_flat[k] = rsp_if[k].snoop_ready;
        assign rsp_hit_flat[k]   = rsp_if[k].snoop_hit;
    end

    // arbitraje de BUS_IDLE: prioridad fija, gana el índice más bajo con
    // snoop_valid (el for recorre de mayor a menor así el índice más bajo
    // es el último en pisar grant_idx/grant_valid).
    logic [GRANT_BITS-1:0] grant_idx;
    logic                  grant_valid;
    always_comb begin
        grant_idx   = '0;
        grant_valid = 1'b0;
        for (int i = NUM_L1 - 1; i >= 0; --i) begin
            if (req_valid_flat[i]) begin
                grant_idx   = i[GRANT_BITS-1:0];
                grant_valid = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            bus_state <= BUS_IDLE;
            pending_r <= '0;
        end else begin
            case (bus_state)
                BUS_IDLE: begin
                    if (grant_valid) begin
                        grant_r   <= grant_idx;
                        addr_r    <= req_addr_flat[grant_idx];
                        rw_r      <= req_rw_flat[grant_idx];
                        // todos menos el que pidió
                        pending_r <= ~(NUM_L1'(1) << grant_idx);
                        hit_acc_r <= 1'b0;
                        bus_state <= BUS_BROADCAST;
                    end
                end
                BUS_BROADCAST: begin
                    for (int j = 0; j < NUM_L1; ++j) begin
                        if (pending_r[j] && rsp_ready_flat[j]) begin
                            hit_acc_r    <= hit_acc_r | rsp_hit_flat[j];
                            pending_r[j] <= 1'b0;
                        end
                    end
                    if (pending_r == '0)
                        bus_state <= BUS_DONE;
                end
                BUS_DONE: begin
                    bus_state <= BUS_IDLE;
                end
                default: bus_state <= BUS_IDLE;
            endcase
        end
    end

    // ---- respuesta hacia el que pidió (req_if[grant_r]) ----
    // snoop_state/dirty/data no los usa nadie del lado master (ver
    // docs/proposals/tfg_mesi_coherence_design.md §1.1: los datos siempre
    // viajan por mem_bus_if) -- se dejan en 0.
    for (genvar i = 0; i < NUM_L1; ++i) begin : g_req_rsp
        assign req_if[i].snoop_ready = (bus_state == BUS_DONE) && (grant_r == i[GRANT_BITS-1:0]);
        assign req_if[i].snoop_hit   = hit_acc_r;
        assign req_if[i].snoop_state = 2'b00;
        assign req_if[i].snoop_dirty = 1'b0;
        assign req_if[i].snoop_data  = '0;
    end

    // ---- broadcast hacia todos menos el que pidió ----
    for (genvar j = 0; j < NUM_L1; ++j) begin : g_rsp_drive
        assign rsp_if[j].snoop_valid = (bus_state == BUS_BROADCAST) && pending_r[j];
        assign rsp_if[j].snoop_addr  = addr_r;
        assign rsp_if[j].snoop_rw    = rw_r;
    end

endmodule
/* verilator lint_on UNUSEDPARAM */
