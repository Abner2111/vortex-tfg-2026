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

        // --------------------------------------------------------------
        // Paso 2/3: árbitro round-robin entre los núcleos que apuntan a
        // ESTE banco. Paso 3 acota el request mask a SOLO escrituras
        // (writebacks) -- un read todavía no tiene a dónde ir (eso es
        // paso 4), así que ni se arbitra: queda pendiente en core_bus_if
        // sin que este banco lo toque. `grant_ready` ahora SÍ depende de
        // `state == S_IDLE` -- recién acá aparece la FSM que puede estar
        // "ocupada".
        // --------------------------------------------------------------
        typedef enum logic [1:0] { S_IDLE, S_HIT, S_WB } state_t;
        state_t state;

        wire [NUM_CORES-1:0] bank_req_mask;
        for (genvar c = 0; c < NUM_CORES; ++c) begin : g_mask
            assign bank_req_mask[c] = core_req_valid_flat[c] && core_req_rw_flat[c]
                                    && (core_bank_flat[c] == BANK_BITS'(b))
                                    && (state == S_IDLE);
        end

        wire                  arb_valid;
        wire [CORE_BITS-1:0]  arb_index;
        wire [NUM_CORES-1:0]  arb_onehot;

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
            .grant_ready  (state == S_IDLE)
        );

        assign bank_grant_valid[b]  = arb_valid;
        assign bank_grant_onehot[b] = arb_onehot;

        // ---- tag lookup sobre el ganador del arbitraje (combinacional,
        // mismo patrón que l1_cache.sv) ----
        wire [SET_BITS-1:0] sel_set = core_set_flat[arb_index];
        wire [TAG_BITS-1:0] sel_tag = core_tag_flat[arb_index];

        logic [NUM_WAYS-1:0] way_hit;
        for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_way_cmp
            assign way_hit[w] = tag_array[sel_set][w].valid
                              && (tag_array[sel_set][w].tag == sel_tag);
        end

        wire tag_hit;
        wire [WAY_BITS-1:0] hit_way;
        VX_onehot_encoder #(
            .N (NUM_WAYS)
        ) hit_way_enc (
            .data_in   (way_hit),
            .data_out  (hit_way),
            .valid_out (tag_hit)
        );

        // Vía víctima: primera inválida del set, si no hay cae en la vía 0
        // -- mismo placeholder deliberado que l1_cache.sv (no es LRU/PLRU).
        logic [WAY_BITS-1:0] victim_way;
        always_comb begin
            victim_way = '0;
            for (int w = 0; w < NUM_WAYS; ++w)
                if (!tag_array[sel_set][w].valid)
                    victim_way = w[WAY_BITS-1:0];
        end

        // ---- registros latcheados al aceptar en S_IDLE ----
        logic                 req_rw_r;    // paso 3: siempre 1'b1 por ahora (solo writes)
        logic [WAY_BITS-1:0]  hit_way_r;
        logic [WAY_BITS-1:0]  victim_way_r;
        logic [SET_BITS-1:0]  req_set_r;
        logic [TAG_BITS-1:0]  req_tag_r;
        logic [LINE_BITS-1:0] req_wdata_r;
        logic                 tag_hit_r;
        `UNUSED_VAR (req_rw_r)

        always_ff @(posedge clk) begin
            if (reset) begin
                state <= S_IDLE;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (arb_valid) begin
                            req_rw_r     <= core_req_rw_flat[arb_index];
                            req_set_r    <= sel_set;
                            req_tag_r    <= sel_tag;
                            req_wdata_r  <= core_req_data_flat[arb_index];
                            hit_way_r    <= hit_way;
                            victim_way_r <= victim_way;
                            tag_hit_r    <= tag_hit;
                            if (tag_hit) begin
                                state <= S_HIT;  // write-hit: solo ensucia la línea
                            end else if (tag_array[sel_set][victim_way].valid
                                      && tag_array[sel_set][victim_way].dirty) begin
                                // víctima sucia: hay que desalojarla antes de poder
                                // asentar la línea nueva -- mecanismo real (hablar con
                                // mem_bus_if[b]/árbitro global) llega en el paso 5; por
                                // ahora este estado es un stub estructural.
                                state <= S_WB;
                            end else begin
                                // write-miss directo: el writeback YA trae la línea
                                // completa, no hace falta ir a buscar nada.
                                state <= S_HIT;
                            end
                        end
                    end
                    S_HIT: begin
                        // write: fire-and-forget, mismo contrato que el resto del
                        // sistema (ver l1_cache.sv) -- no espera ningún ready.
                        state <= S_IDLE;
                    end
                    S_WB: begin
                        // TODO (paso 5): volcar data_rd_data[victim_way_r] a
                        // mem_bus_if[b] antes de pasar a S_HIT. Por ahora, stub.
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end

        // ---- tag array: escritura ----
        always_ff @(posedge clk) begin
            if (reset) begin
                for (int s = 0; s < NUM_SETS; ++s)
                    for (int w = 0; w < NUM_WAYS; ++w)
                        tag_array[s][w].valid <= 1'b0;
            end else begin
                if (state == S_HIT) begin
                    if (tag_hit_r) begin
                        // write-hit: el dato ya se escribe vía fsm_data_wr_* más
                        // abajo -- acá solo hace falta ensuciar la línea.
                        tag_array[req_set_r][hit_way_r].dirty <= 1'b1;
                    end else begin
                        // write-miss directo: asienta la línea nueva completa.
                        tag_array[req_set_r][victim_way_r].valid <= 1'b1;
                        tag_array[req_set_r][victim_way_r].dirty <= 1'b1;
                        tag_array[req_set_r][victim_way_r].tag   <= req_tag_r;
                    end
                end
            end
        end

        // ---- data array: solo el puerto de ESCRITURA por ahora (un
        // writeback nunca necesita leer nada -- es la línea completa, sin
        // merge; el puerto de lectura llega en el paso 4, para hits/fills
        // de lectura). ----
        logic                  fsm_data_wr_en;
        logic [WAY_BITS-1:0]   fsm_data_wr_way;
        logic [SET_BITS-1:0]   fsm_data_wr_set;
        logic [LINE_BITS-1:0]  fsm_data_wr_line;
        always_comb begin
            fsm_data_wr_en   = (state == S_HIT);
            fsm_data_wr_way  = tag_hit_r ? hit_way_r : victim_way_r;
            fsm_data_wr_set  = req_set_r;
            fsm_data_wr_line = req_wdata_r;
        end

        for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_way
            logic [LINE_BITS-1:0] mem [NUM_SETS];
            wire wr_en = fsm_data_wr_en && (fsm_data_wr_way == w[WAY_BITS-1:0]);
            always_ff @(posedge clk) begin
                if (wr_en)
                    mem[fsm_data_wr_set] <= fsm_data_wr_line;
            end
        end

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
