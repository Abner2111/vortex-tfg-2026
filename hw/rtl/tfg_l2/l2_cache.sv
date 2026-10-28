// Interfaces:
//   core_bus_if[NUM_CORES] : L2 <-> L1 (una por núcleo). Reutiliza
//                            VX_mem_bus_if, igual convención que
//                            l1_cache.sv (hw/rtl/tfg_l1/l1_cache.sv) -- L2
//                            es slave, cada L1 es master hacia su banco.
//   mem_bus_if[NUM_BANKS]  : L2 <-> árbitro global, UN puerto POR banco.
//
// Paso 1 (de 6, implementación incremental con commits graduales):
// bancos BRAM independientes -- tag array + data array por banco (listo).
//
// Paso 2: acceso simultáneo de los N núcleos a bancos distintos.
// Direccionamiento banco-intercalado (bits más bajos de la dirección de
// línea seleccionan banco) + un árbitro round-robin INDEPENDIENTE por
// banco entre los núcleos que lo apuntan ese ciclo -- dos núcleos pidiendo
// bancos distintos ganan arbitraje en el mismo ciclo, sin tocarse. Todavía
// NO hay hit/miss ni FSM (eso es paso 3/4): el "ganador" de cada banco se
// calcula, pero nadie lo usa aún para leer/escribir el tag o data array
// -- por eso `grant_ready` de cada árbitro es constante 1 por ahora (no
// hay un estado de banco que diga "ocupado"); eso se vuelve real recién
// cuando el paso 3/4 agregue la FSM con S_IDLE.
`include "VX_define.vh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module l2_cache import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",

    parameter NUM_CORES = 4,      // puertos L1 servidos
    parameter NUM_BANKS = 4,      // bancos independientes -- debe ser potencia de 2
    parameter BANK_SIZE = 16384,  // bytes, POR banco
    parameter NUM_WAYS  = 4,      // vías por banco
    parameter LINE_SIZE = 16,     // bytes -- tiene que calzar con el LINE_SIZE
                                   // de mem_bus_if de la L1 que conecta acá
                                   // (ver hw/rtl/tfg_l1/l1_cache.sv)
    parameter CORE_TAG_WIDTH = 8,
    parameter MEM_TAG_WIDTH  = 8
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave  core_bus_if [NUM_CORES],
    VX_mem_bus_if.master mem_bus_if  [NUM_BANKS]
);
    // ------------------------------------------------------------------
    // Direccionamiento (todavía sin usar -- queda fijado acá porque
    // NUM_SETS/TAG_BITS lo necesitan para dimensionar el storage de este
    // paso): bancos intercalados por los bits más bajos de la dirección
    // de línea (después de banco vienen set, después tag).
    // ------------------------------------------------------------------
    localparam ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(LINE_SIZE);
    localparam LINE_BITS  = LINE_SIZE * 8;
    localparam BANK_BITS  = `CLOG2(NUM_BANKS);
    localparam NUM_SETS   = BANK_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam SET_BITS   = `CLOG2(NUM_SETS);
    localparam TAG_BITS   = ADDR_WIDTH - BANK_BITS - SET_BITS;
    localparam WAY_BITS   = `LOG2UP(NUM_WAYS);

    `STATIC_ASSERT((NUM_BANKS >= 2) && (NUM_BANKS == (1 << BANK_BITS)),
                   ("l2_cache: NUM_BANKS debe ser potencia de 2, >= 2"))

    localparam CORE_BITS = `LOG2UP(NUM_CORES);

    typedef struct packed {
        logic                 valid;
        logic                 dirty;
        logic [TAG_BITS-1:0]  tag;
    } tag_entry_t;

    // ------------------------------------------------------------------
    // Aplanado de core_bus_if a arrays de señales planas ANTES de
    // cualquier lógica de arbitraje. Necesario porque, en los próximos
    // pasos, un banco cualquiera va a terminar atendiendo a CUALQUIER
    // núcleo según quién gane su arbitraje ese ciclo -- hace falta indexar
    // con una variable en tiempo de ejecución, y eso no se puede hacer
    // directo sobre un array de interfaces en Verilator (solo con
    // `genvar`, es decir, índices constantes). mem_bus_if NO necesita este
    // tratamiento: cada banco solo toca SU PROPIO puerto, con el índice de
    // banco (genvar) constante.
    // ------------------------------------------------------------------
    logic [NUM_CORES-1:0]                     core_req_valid_flat;
    logic [NUM_CORES-1:0]                     core_req_rw_flat;
    logic [NUM_CORES-1:0][ADDR_WIDTH-1:0]     core_req_addr_flat;
    logic [NUM_CORES-1:0][LINE_BITS-1:0]      core_req_data_flat;
    logic [NUM_CORES-1:0][CORE_TAG_WIDTH-1:0] core_req_tag_flat;
    logic [NUM_CORES-1:0]                     core_rsp_ready_flat;

    logic [NUM_CORES-1:0]                     core_req_ready_flat;
    logic [NUM_CORES-1:0]                     core_rsp_valid_flat;
    logic [NUM_CORES-1:0][LINE_BITS-1:0]      core_rsp_data_flat;
    logic [NUM_CORES-1:0][CORE_TAG_WIDTH-1:0] core_rsp_tag_flat;

    for (genvar c = 0; c < NUM_CORES; ++c) begin : g_core_flatten
        assign core_req_valid_flat[c] = core_bus_if[c].req_valid;
        assign core_req_rw_flat[c]    = core_bus_if[c].req_data.rw;
        assign core_req_addr_flat[c]  = core_bus_if[c].req_data.addr;
        assign core_req_data_flat[c]  = core_bus_if[c].req_data.data;
        assign core_req_tag_flat[c]   = core_bus_if[c].req_data.tag;
        assign core_rsp_ready_flat[c] = core_bus_if[c].rsp_ready;

        assign core_bus_if[c].req_ready     = core_req_ready_flat[c];
        assign core_bus_if[c].rsp_valid     = core_rsp_valid_flat[c];
        assign core_bus_if[c].rsp_data.data = core_rsp_data_flat[c];
        assign core_bus_if[c].rsp_data.tag  = core_rsp_tag_flat[c];
    end

    // Por ahora (paso 2) nadie produce una respuesta todavía -- eso es
    // paso 3/4. Default a 0 para no dejar core_rsp_valid_flat/
    // core_rsp_data_flat/core_rsp_tag_flat sin manejar (se reemplaza en
    // el próximo paso).
    assign core_rsp_valid_flat = '0;
    assign core_rsp_data_flat  = '0;
    assign core_rsp_tag_flat   = '0;

    // Descomposición de dirección por núcleo: banco (bits bajos), set,
    // tag -- ver comentario de direccionamiento más arriba.
    logic [NUM_CORES-1:0][BANK_BITS-1:0] core_bank_flat;
    logic [NUM_CORES-1:0][SET_BITS-1:0]  core_set_flat;
    logic [NUM_CORES-1:0][TAG_BITS-1:0]  core_tag_flat;
    for (genvar c = 0; c < NUM_CORES; ++c) begin : g_core_decomp
        assign core_bank_flat[c] = core_req_addr_flat[c][BANK_BITS-1:0];
        assign core_set_flat[c]  = core_req_addr_flat[c][BANK_BITS +: SET_BITS];
        assign core_tag_flat[c]  = core_req_addr_flat[c][BANK_BITS+SET_BITS +: TAG_BITS];
    end
    `UNUSED_VAR (core_set_flat)
    `UNUSED_VAR (core_tag_flat)

    // Salidas del árbitro de cada banco (índice de banco siempre constante)
    // -- consumidas por el ruteo per-núcleo más abajo.
    logic [NUM_BANKS-1:0]                bank_grant_valid;
    logic [NUM_BANKS-1:0][NUM_CORES-1:0] bank_grant_onehot;

    // ------------------------------------------------------------------
    // Bancos BRAM independientes (paso 1): cada banco, su propio tag array
    // y, por vía, su propia memoria síncrona de datos -- mismo patrón que
    // l1_cache.sv (hw/rtl/tfg_l1/l1_cache.sv: "NUM_WAYS memorias síncronas
    // independientes... lectura Y escritura registradas en el flanco de
    // reloj, para que el sintetizador infiera BRAM real"). Sin lógica de
    // acceso todavía: nadie lee ni escribe estos arrays en este paso.
    // ------------------------------------------------------------------
    for (genvar b = 0; b < NUM_BANKS; ++b) begin : g_bank

        tag_entry_t tag_array [NUM_SETS][NUM_WAYS];

        for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_way
            logic [LINE_BITS-1:0] mem [NUM_SETS];
        end

        // --------------------------------------------------------------
        // Paso 2: árbitro round-robin entre los núcleos que apuntan a
        // ESTE banco (`core_bank_flat[c]==b`) este ciclo. `grant_ready`
        // constante 1 -- todavía no hay FSM que diga "ocupado" (paso 3/4),
        // así que cada banco siempre puede "aceptar" un ganador nuevo.
        // --------------------------------------------------------------
        wire [NUM_CORES-1:0] bank_req_mask;
        for (genvar c = 0; c < NUM_CORES; ++c) begin : g_mask
            assign bank_req_mask[c] = core_req_valid_flat[c] && (core_bank_flat[c] == BANK_BITS'(b));
        end

        wire                  arb_valid;
        wire [CORE_BITS-1:0]  arb_index;
        wire [NUM_CORES-1:0]  arb_onehot;
        `UNUSED_VAR (arb_index)

        VX_generic_arbiter #(
            .NUM_REQS (NUM_CORES),
            .TYPE     ("R")
        ) bank_arb (
            .clk          (clk),
            .reset        (reset),
            .requests     (bank_req_mask),
            .grant_valid  (arb_valid),
            .grant_index  (arb_index),
            .grant_onehot (arb_onehot),
            .grant_ready  (1'b1)
        );

        assign bank_grant_valid[b]  = arb_valid;
        assign bank_grant_onehot[b] = arb_onehot;

    end

    // ------------------------------------------------------------------
    // Ruteo final de req_ready por núcleo: cada núcleo tiene a lo sumo UNA
    // petición en vuelo, así que como mucho UN banco lo va a haber
    // aceptado este ciclo -- este OR entre bancos es en la práctica un
    // mux, nunca una colisión real (mismo razonamiento que
    // docs/proposals/tfg_mesi_coherence_design.md documenta para el
    // árbitro de snoop_bus.sv). rsp_valid/rsp_data/rsp_tag quedan en 0
    // (ver arriba) hasta el paso 3/4 -- un write "aceptado" en este paso
    // no implica nada todavía del otro lado, solo que ganó el arbitraje.
    // ------------------------------------------------------------------
    for (genvar c = 0; c < NUM_CORES; ++c) begin : g_core_route
        logic req_r;
        always_comb begin
            req_r = 1'b0;
            for (int b = 0; b < NUM_BANKS; ++b)
                if (bank_grant_valid[b] && bank_grant_onehot[b][c])
                    req_r = 1'b1;
        end
        assign core_req_ready_flat[c] = req_r;
    end

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
