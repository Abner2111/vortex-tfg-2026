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
// Paso 2: acceso simultáneo de los N núcleos a bancos distintos --
// direccionamiento banco-intercalado + árbitro round-robin independiente
// por banco (listo).
//
// Paso 3: interfaz hacia L1 para recibir writebacks -- camino de
// escritura completo (write-hit, write-miss directo; eviction real todavía
// stub, ver S_WB) (listo).
//
// Paso 4: interfaz hacia L1 para atender misses -- camino de LECTURA
// (hit-read desde el data array propio; S_MISS_WAIT/S_FILL como stub)
// (listo).
//
// Paso 5: interfaz hacia el árbitro global para misses que no encuentra en
// L2 -- completa S_WB (volcar la víctima sucia) y S_MISS_WAIT (pedir la
// línea nueva) de verdad contra mem_bus_if[b]. Mismo contrato que
// l1_cache.sv ya usa para SU propio mem_bus_if (hacia esta misma L2, antes
// de este paso, y hacia el árbitro global ahora): a diferencia de
// core_bus_if (donde un write es fire-and-forget, sin respuesta -- ver el
// fix de A-9 en l1_cache.sv), mem_bus_if SÍ espera `rsp_valid` para
// CUALQUIER transacción, lectura o escritura -- quien está debajo tiene
// que confirmar que la escritura realmente se completó antes de que el
// que la pidió siga adelante. Reconstruye los bits de banco (constantes,
// `b`) al armar la dirección: tag_r/set_r solos no alcanzan para no
// colisionar con la misma línea de otro banco.
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

    // Salidas del árbitro y de la respuesta de cada banco (índice de banco
    // siempre constante) -- consumidas por el ruteo per-núcleo más abajo.
    logic [NUM_BANKS-1:0]                     bank_grant_valid;
    logic [NUM_BANKS-1:0][NUM_CORES-1:0]      bank_grant_onehot;
    logic [NUM_BANKS-1:0]                     bank_resp_valid;
    logic [NUM_BANKS-1:0][CORE_BITS-1:0]      bank_resp_core;
    logic [NUM_BANKS-1:0][LINE_BITS-1:0]      bank_resp_data;
    logic [NUM_BANKS-1:0][CORE_TAG_WIDTH-1:0] bank_resp_ctag;

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
        typedef enum logic [2:0] { S_IDLE, S_HIT, S_WB, S_MISS_WAIT, S_FILL } state_t;
        state_t state;

        // Paso 4: ya no se acota a solo writes -- un read-miss de L1
        // también tiene que poder arbitrar para entrar.
        wire [NUM_CORES-1:0] bank_req_mask;
        for (genvar c = 0; c < NUM_CORES; ++c) begin : g_mask
            assign bank_req_mask[c] = core_req_valid_flat[c]
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
        logic                      req_rw_r;
        logic [CORE_BITS-1:0]      req_core_r;
        logic [WAY_BITS-1:0]       hit_way_r;
        logic [WAY_BITS-1:0]       victim_way_r;
        logic [SET_BITS-1:0]       req_set_r;
        logic [TAG_BITS-1:0]       req_tag_r;
        logic [TAG_BITS-1:0]       victim_tag_r;
        logic [LINE_BITS-1:0]      req_wdata_r;
        logic [CORE_TAG_WIDTH-1:0] req_ctag_r;
        logic                      tag_hit_r;
        logic [LINE_BITS-1:0]      fetched_line_r;
        logic                      mem_req_sent_r;  // paso 5: ya mandamos el req a mem_bus_if[b], esperando rsp

        // núcleo que ganó este banco y está esperando la respuesta (S_HIT
        // de lectura / S_FILL) -- las escrituras son fire-and-forget y no
        // lo necesitan, pero no cuesta nada latchearlo siempre.
        wire resp_ready_sel = core_rsp_ready_flat[req_core_r];

        // mem_bus_if[b] es un puerto dedicado de este banco (a diferencia
        // de l1_cache.sv, no hay un segundo camino -- snoop -- compitiendo
        // por él), así que no hace falta ningún árbitro acá: solo tracking
        // de "ya mandé el req, esperando la respuesta" para no reafirmar
        // req_valid de más una vez aceptado.
        wire mem_req_fire = mem_bus_if[b].req_valid && mem_bus_if[b].req_ready;
        wire mem_rsp_fire = mem_bus_if[b].rsp_valid && mem_bus_if[b].rsp_ready;

        always_ff @(posedge clk) begin
            if (reset) begin
                state          <= S_IDLE;
                mem_req_sent_r <= 1'b0;
            end else begin
                case (state)
                    S_IDLE: begin
                        if (arb_valid) begin
                            req_rw_r     <= core_req_rw_flat[arb_index];
                            req_core_r   <= arb_index;
                            req_set_r    <= sel_set;
                            req_tag_r    <= sel_tag;
                            req_wdata_r  <= core_req_data_flat[arb_index];
                            req_ctag_r   <= core_req_tag_flat[arb_index];
                            hit_way_r    <= hit_way;
                            victim_way_r <= victim_way;
                            victim_tag_r <= tag_array[sel_set][victim_way].tag;
                            tag_hit_r    <= tag_hit;
                            if (tag_hit) begin
                                state <= S_HIT;  // hit (lectura o escritura)
                            end else if (tag_array[sel_set][victim_way].valid
                                      && tag_array[sel_set][victim_way].dirty) begin
                                state <= S_WB;  // víctima sucia: desalojarla primero
                            end else if (core_req_rw_flat[arb_index]) begin
                                // write-miss directo: el writeback YA trae la línea
                                // completa, no hace falta ir a buscar nada.
                                state <= S_HIT;
                            end else begin
                                state <= S_MISS_WAIT;  // read-miss: pedirla al árbitro global
                            end
                            `TRACE(2, ("%t: %s-bank%0d S_IDLE->grant: core=%0d, addr={%0h,%0h,%0d}, rw=%0d, tag_hit=%0d\n", $time, INSTANCE_ID, b, arb_index, sel_tag, sel_set, b, core_req_rw_flat[arb_index], tag_hit))
                        end
                    end
                    S_HIT: begin
                        // A-17: a diferencia de core_bus_if (L1<->pipeline,
                        // write fire-and-forget), este core_bus_if es el
                        // lado MEMORIA desde la perspectiva de quien nos
                        // habla (l1_cache.sv, vía su propio mem_bus_if) --
                        // l1_cache.sv espera rsp_valid para CUALQUIER
                        // transacción de mem_bus_if, lectura o escritura
                        // (ver l1_cache.sv S_WB, sin gate por rw). Si acá
                        // no se ackeara la escritura, l1_cache.sv se queda
                        // esperando para siempre -- encontrado integrando
                        // L1 real contra L2 real por primera vez (A-17;
                        // A-14 nunca forzó un flush real, A-11/A-16 solo
                        // probaron contra mocks de C++ que no dependían de
                        // este ack). Por eso lectura Y escritura esperan
                        // resp_ready_sel por igual.
                        if (resp_ready_sel)
                            state <= S_IDLE;
                    end
                    S_WB: begin
                        // mem_bus_if[b].req_data.rw == (state==S_WB) siempre
                        // -- este estado SOLO manda escrituras (el volcado
                        // del víctima sucio). A diferencia de S_MISS_WAIT
                        // (una lectura real, con datos que sí hay que
                        // esperar), acá no hay nada que recibir de vuelta:
                        // el harness de simulación stock (sim/rtlsim/
                        // processor.cpp: "if (!mem_rsp->write) { ...
                        // mem_rsp_valid = 1; }") directamente NUNCA levanta
                        // rsp_valid para una escritura real hacia memoria --
                        // es fire-and-forget por diseño en ese límite, no
                        // una demora. Esperar mem_rsp_fire acá colgaba esta
                        // L2 para siempre en el primer writeback real
                        // (encontrado en Fase B -- A-11/A-14/A-16/A-17 nunca
                        // habían forzado un desalojo sucio hasta la memoria
                        // de verdad, solo contra mocks de C++ o sin L3/DRAM
                        // real de por medio).
                        if (mem_req_fire) begin
                            // si lo pendiente era un write, ya tiene los datos
                            // (req_wdata_r) -- asienta directo; si era un read,
                            // ahora sí hace falta ir a buscar la línea nueva.
                            state <= req_rw_r ? S_HIT : S_MISS_WAIT;
                        end
                    end
                    S_MISS_WAIT: begin
                        if (mem_req_fire) begin
                            mem_req_sent_r <= 1'b1;
                            `TRACE(2, ("%t: %s-bank%0d S_MISS_WAIT req sent: addr={%0h,%0h,%0d}\n", $time, INSTANCE_ID, b, req_tag_r, req_set_r, b))
                        end
                        if (mem_rsp_fire) begin
                            mem_req_sent_r <= 1'b0;
                            fetched_line_r <= mem_bus_if[b].rsp_data.data;
                            state          <= S_FILL;
                            `TRACE(2, ("%t: %s-bank%0d S_MISS_WAIT->S_FILL: addr={%0h,%0h,%0d}\n", $time, INSTANCE_ID, b, req_tag_r, req_set_r, b))
                        end
                    end
                    S_FILL: begin
                        if (resp_ready_sel)
                            state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end

        // ---- tag array: escritura (un read-hit no toca nada acá -- solo
        // lee, ver el puerto de lectura del data array más abajo) ----
        always_ff @(posedge clk) begin
            if (reset) begin
                for (int s = 0; s < NUM_SETS; ++s)
                    for (int w = 0; w < NUM_WAYS; ++w)
                        tag_array[s][w].valid <= 1'b0;
            end else begin
                if (state == S_HIT && req_rw_r) begin
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
                if (state == S_MISS_WAIT && mem_rsp_fire) begin
                    // fill de lectura: línea limpia recién traída del árbitro global.
                    tag_array[req_set_r][victim_way_r].valid <= 1'b1;
                    tag_array[req_set_r][victim_way_r].dirty <= 1'b0;
                    tag_array[req_set_r][victim_way_r].tag   <= req_tag_r;
                end
            end
        end

        // ---- data array: puerto de escritura (writebacks, paso 3) +
        // puerto de lectura (hits de lectura, paso 4 -- el fill de un
        // read-miss, paso 5, también lo va a usar). Lectura síncrona, 1
        // ciclo de latencia -- mismo motivo que l1_cache.sv: hit_way_r ya
        // viene registrado un ciclo antes de indexar con él en S_HIT.
        logic                  fsm_data_wr_en;
        logic [WAY_BITS-1:0]   fsm_data_wr_way;
        logic [SET_BITS-1:0]   fsm_data_wr_set;
        logic [LINE_BITS-1:0]  fsm_data_wr_line;
        always_comb begin
            fsm_data_wr_en   = 1'b0;
            fsm_data_wr_way  = tag_hit_r ? hit_way_r : victim_way_r;
            fsm_data_wr_set  = req_set_r;
            fsm_data_wr_line = req_wdata_r;
            if (state == S_HIT && req_rw_r) begin
                fsm_data_wr_en = 1'b1;
            end else if (state == S_MISS_WAIT && mem_rsp_fire) begin
                // fill de lectura: la línea recién llegada del árbitro
                // global también tiene que asentarse en el data array --
                // si no, el tag_array dice "válida" pero la próxima
                // lectura (ya un hit) lee lo que hubiera antes ahí.
                fsm_data_wr_en   = 1'b1;
                fsm_data_wr_way  = victim_way_r;
                fsm_data_wr_line = mem_bus_if[b].rsp_data.data;
            end
        end

        // Fuera de S_IDLE, releer siempre el set con el que se aceptó la
        // petición (req_set_r, congelado) -- mismo motivo que l1_cache.sv:
        // sel_set/arb_index ya no valen una vez que el banco está ocupado.
        wire [SET_BITS-1:0] array_set_addr = (state == S_IDLE) ? sel_set : req_set_r;
        logic [LINE_BITS-1:0] data_rd_data [NUM_WAYS];

        for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_way
            logic [LINE_BITS-1:0] mem [NUM_SETS];
            wire wr_en = fsm_data_wr_en && (fsm_data_wr_way == w[WAY_BITS-1:0]);
            always_ff @(posedge clk) begin
                if (wr_en)
                    mem[fsm_data_wr_set] <= fsm_data_wr_line;
                data_rd_data[w] <= mem[array_set_addr];
            end
        end

        // ---- respuesta hacia el núcleo que ganó este banco (ruteada por
        // índice fuera del generate de bancos, ver más abajo) -- lectura
        // Y escritura responden por igual (A-17, ver el comentario de
        // S_HIT más arriba: este core_bus_if es "memoria" desde la
        // perspectiva de l1_cache.sv, que espera ack de cualquier
        // transacción vía su propio mem_bus_if). ----
        assign bank_resp_valid[b] = (state == S_HIT) || (state == S_FILL);
        assign bank_resp_core[b]  = req_core_r;
        assign bank_resp_data[b]  = (state == S_HIT) ? data_rd_data[hit_way_r] : fetched_line_r;
        assign bank_resp_ctag[b]  = req_ctag_r;

        // ---- puerto propio hacia mem_bus_if[b] (árbitro global) ----
        // Dirección: reinserta los bits de banco (constantes, `b`) para
        // reconstruir la dirección GLOBAL de línea -- tag/set por sí solos
        // colisionarían con la misma línea servida por OTRO banco. En
        // S_WB es la dirección VIEJA (la víctima); en S_MISS_WAIT, la NUEVA.
        assign mem_bus_if[b].req_valid      = ((state == S_WB) || (state == S_MISS_WAIT)) && !mem_req_sent_r;
        assign mem_bus_if[b].req_data.rw    = (state == S_WB);
        assign mem_bus_if[b].req_data.addr  = (state == S_WB)
                                             ? {victim_tag_r, req_set_r, BANK_BITS'(b)}
                                             : {req_tag_r,    req_set_r, BANK_BITS'(b)};
        assign mem_bus_if[b].req_data.data  = data_rd_data[victim_way_r];  // solo se usa en S_WB
        assign mem_bus_if[b].req_data.byteen = '1;
        assign mem_bus_if[b].req_data.attr   = '0;
        // TODO (igual que l1_cache.sv): con más de un miss en vuelo por
        // banco haría falta un tag real -- un solo request a la vez por
        // banco alcanza con 0.
        assign mem_bus_if[b].req_data.tag    = '0;
        assign mem_bus_if[b].rsp_ready       = (state == S_WB) || (state == S_MISS_WAIT);

        // Debug temporal (Fase B, bloqueante de S_WB tras el primer
        // writeback real a memoria): confirma si mem_bus_if[b].rsp_valid
        // llega alguna vez después de un req de escritura -- señal de
        // ENTRADA real de este módulo, no hace falta tocar nada stock.
        logic mem_req_was_write_r;
        always_ff @(posedge clk) begin
            if (mem_req_fire) mem_req_was_write_r <= mem_bus_if[b].req_data.rw;
            if (mem_bus_if[b].rsp_valid) begin
                `TRACE(2, ("%t: %s-bank%0d mem_bus_if rsp_valid: was_write=%0d, state=%0d\n", $time, INSTANCE_ID, b, mem_req_was_write_r, state))
            end
        end

    end

    // ------------------------------------------------------------------
    // Ruteo final por núcleo: cada núcleo tiene a lo sumo UNA petición en
    // vuelo, así que como mucho UN banco lo va a haber aceptado o le va a
    // estar respondiendo en un momento dado -- este OR entre bancos es en
    // la práctica un mux, nunca una colisión real (mismo razonamiento que
    // docs/proposals/tfg_mesi_coherence_design.md documenta para el
    // árbitro de snoop_bus.sv).
    // ------------------------------------------------------------------
    for (genvar c = 0; c < NUM_CORES; ++c) begin : g_core_route
        logic                      req_r;
        logic                      rsp_v;
        logic [LINE_BITS-1:0]      rsp_d;
        logic [CORE_TAG_WIDTH-1:0] rsp_t;
        always_comb begin
            req_r = 1'b0;
            rsp_v = 1'b0;
            rsp_d = '0;
            rsp_t = '0;
            for (int b = 0; b < NUM_BANKS; ++b) begin
                if (bank_grant_valid[b] && bank_grant_onehot[b][c])
                    req_r = 1'b1;
                if (bank_resp_valid[b] && (bank_resp_core[b] == CORE_BITS'(c))) begin
                    rsp_v = 1'b1;
                    rsp_d = bank_resp_data[b];
                    rsp_t = bank_resp_ctag[b];
                end
            end
        end
        assign core_req_ready_flat[c] = req_r;
        assign core_rsp_valid_flat[c] = rsp_v;
        assign core_rsp_data_flat[c]  = rsp_d;
        assign core_rsp_tag_flat[c]   = rsp_t;
    end

endmodule
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
