// Interfaces:
//   core_bus_if  : L1 <-> pipeline.  Reutiliza VX_mem_bus_if de Vortex
//                  (hw/rtl/mem/VX_mem_bus_if.sv) — mismo protocolo que el
//                  core ya habla en el punto de bypass del dcache
//                  (ver docs/proposals/nn_kernel_roofline_tfg_evaluation.md §5.3).
//   mem_bus_if   : L1 <-> L2.        Mismo VX_mem_bus_if, en el otro sentido
//                  (L1 es master hacia L2 igual que el core lo es hacia L1).
//   snoop_bus_if : L1 <-> snoop bus. VX_snoop_bus_if.sv (draft, A-4).

`include "VX_define.vh"

// Placeholder: clk/reset y los parámetros de tamaño todavía no los usa
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
module l1_cache import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",

    parameter CACHE_SIZE    = 4096,  // bytes
    parameter LINE_SIZE     = 64,    // bytes
    parameter NUM_WAYS      = 4,
    parameter WORD_SIZE     = 4,     // bytes por palabra del core
    parameter CORE_TAG_WIDTH = 8,
    parameter MEM_TAG_WIDTH  = 8
) (
    input wire clk,
    input wire reset,

    VX_mem_bus_if.slave      core_bus_if,
    VX_mem_bus_if.master     mem_bus_if,
    VX_snoop_bus_if.snooper  snoop_bus_if
);

    // ------------------------------------------------------------------
    // Tag array 
    //   NUM_WAYS vías por set, cada línea: {valid, dirty, mesi, tag}.
    //   Descompone core_bus_if.req_data.addr (dirección de palabra, ver
    //   VX_mem_bus_if.sv: ADDR_WIDTH = MEM_ADDR_WIDTH - CLOG2(DATA_SIZE))
    //   en {tag | set | word_offset} y hace el lookup combinacional de las
    //   NUM_WAYS vías del set indexado.
    //
    //   Política de reemplazo (qué vía se desaloja en un miss con el set
    //   lleno) queda para el hit/miss. El tag array solo
    //   expone `way_hit`/`hit_way`/`tag_hit` para que esa lógica decida.
    // ------------------------------------------------------------------
    // Mismo cómputo que VX_mem_bus_if.sv usa para su ADDR_WIDTH por defecto
    // (no se puede leer core_bus_if.req_data.addr con $bits: es una
    // referencia jerárquica y acá hace falta una constante de elaboración).
    localparam ADDR_WIDTH     = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(WORD_SIZE);
    localparam WORDS_PER_LINE = LINE_SIZE / WORD_SIZE;
    localparam NUM_SETS       = CACHE_SIZE / (LINE_SIZE * NUM_WAYS);
    localparam OFFSET_BITS    = `CLOG2(WORDS_PER_LINE);
    localparam SET_BITS       = `CLOG2(NUM_SETS);
    localparam TAG_BITS       = ADDR_WIDTH - SET_BITS - OFFSET_BITS;
    localparam WAY_BITS       = `LOG2UP(NUM_WAYS);

    typedef struct packed {
        logic                 valid;
        logic                 dirty;
        logic [1:0]           mesi;   // MESI_I/S/E/M, ver VX_snoop_bus_if.sv
        logic [TAG_BITS-1:0]  tag;
    } tag_entry_t;

    tag_entry_t tag_array [NUM_SETS][NUM_WAYS];

    wire [SET_BITS-1:0] req_set = core_bus_if.req_data.addr[OFFSET_BITS +: SET_BITS];
    wire [TAG_BITS-1:0]  req_tag = core_bus_if.req_data.addr[OFFSET_BITS+SET_BITS +: TAG_BITS];

    logic [NUM_WAYS-1:0] way_hit;
    for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_way_cmp
        assign way_hit[w] = tag_array[req_set][w].valid
                          && (tag_array[req_set][w].tag == req_tag);
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

    // Mismo lookup, para la petición que llega por snoop_bus_if.
    // Dirección de línea (ver mem_bus_if.req_data.addr): {tag,set}, mismo
    // orden de bits que arma el propio mem_bus_if.
    wire [SET_BITS-1:0] snoop_set = snoop_bus_if.snoop_addr[SET_BITS-1:0];
    wire [TAG_BITS-1:0] snoop_tag = snoop_bus_if.snoop_addr[SET_BITS +: TAG_BITS];

    logic [NUM_WAYS-1:0] snoop_way_hit;
    for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_snoop_way_cmp
        assign snoop_way_hit[w] = tag_array[snoop_set][w].valid
                                && (tag_array[snoop_set][w].tag == snoop_tag);
    end

    wire snoop_tag_hit;
    wire [WAY_BITS-1:0] snoop_hit_way;
    VX_onehot_encoder #(
        .N (NUM_WAYS)
    ) snoop_hit_way_enc (
        .data_in   (snoop_way_hit),
        .data_out  (snoop_hit_way),
        .valid_out (snoop_tag_hit)
    );

    // ¿esta petición de snoop le toca a este L1 y hace falta hacer algo?
    // (bloquea aceptar una petición local nueva ese mismo ciclo — ver
    // core_bus_if.req_ready más abajo)
    wire snoop_any_hit = snoop_bus_if.snoop_valid && snoop_tag_hit;
    // ¿hace falta flush (línea en M) antes de poder responder?
    wire snoop_flush_needed = snoop_any_hit
                            && (tag_array[snoop_set][snoop_hit_way].mesi == 2'b11);

    // Vía víctima para un miss: la primera invalida del set; si todas
    // están ocupadas, cae en la vía 0. Placeholder de reemplazo real —
    // no es LRU/PLRU, es "vía 0 siempre" en el caso de set lleno.
    // Reemplazar antes de A-12 si el TFG evalúa tasa de miss.
    logic [WAY_BITS-1:0] victim_way;
    always_comb begin
        victim_way = '0;
        for (int w = 0; w < NUM_WAYS; ++w)
            if (!tag_array[req_set][w].valid)
                victim_way = w[WAY_BITS-1:0];
    end

    // invalidar todas las líneas en reset. El resto de los writes (fill
    // tras un miss, marcar dirty en un write-hit, transiciones MESI por
    // snoop remoto) los maneja la FSM de hit/miss y el lado snooper (A-6)
    // más abajo, en este mismo always_ff para no tener dos procesos
    // manejando tag_array (dos always_ff separados escribiendo la misma
    // variable no es válido en SV/no sintetiza).
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int s = 0; s < NUM_SETS; ++s)
                for (int w = 0; w < NUM_WAYS; ++w)
                    tag_array[s][w].valid <= 1'b0;
        end else begin
            if (state == S_IDLE && core_bus_if.req_valid && core_bus_if.req_ready
                && tag_hit && core_bus_if.req_data.rw) begin
                // write-hit: la línea sigue siendo válida, solo se ensucia
                tag_array[req_set][hit_way].dirty <= 1'b1;
                tag_array[req_set][hit_way].mesi  <= 2'b11;  // MESI_M
            end
            if (state == S_MISS_WAIT && mem_bus_if.rsp_valid && mem_bus_if.rsp_ready) begin
                // fill: la línea que llega de mem_bus_if reemplaza a la víctima.
                // Si estaba dirty, S_WB ya la volcó a mem_bus_if antes de
                // llegar acá (ver arriba) — para este punto es seguro pisarla.
                tag_array[req_set_r][victim_way_r].valid <= 1'b1;
                tag_array[req_set_r][victim_way_r].dirty <= req_rw_r;
                tag_array[req_set_r][victim_way_r].mesi  <= req_rw_r ? 2'b11 : 2'b10; // M : E
                tag_array[req_set_r][victim_way_r].tag   <= req_tag_r;
            end
            // ---- lado snooper
            if (state == S_IDLE && snoop_bus_if.snoop_valid && snoop_tag_hit
                && tag_array[snoop_set][snoop_hit_way].mesi != 2'b11) begin
                // E o S (si estuviera en M, el flush se hace en S_SNOOP_WB/
                // S_SNOOP_POST_WB más abajo, acá no se toca todavía).
                if (snoop_bus_if.snoop_rw)
                    tag_array[snoop_set][snoop_hit_way].valid <= 1'b0;        // E->I, S->I
                else
                    tag_array[snoop_set][snoop_hit_way].mesi  <= 2'b01;      // E->S (S sigue S)
            end
            if (state == S_SNOOP_WB && mem_bus_if.rsp_valid && mem_bus_if.rsp_ready) begin
                // flush completo: M -> E (limpia, todavía exclusiva un instante)
                tag_array[snoop_set_r][snoop_way_r].dirty <= 1'b0;
                tag_array[snoop_set_r][snoop_way_r].mesi  <= 2'b10;  // E
            end
            if (state == S_SNOOP_POST_WB) begin
                // segundo paso: E->I si el remoto quería escribir, E->S si quería leer
                if (snoop_rw_r)
                    tag_array[snoop_set_r][snoop_way_r].valid <= 1'b0;
                else
                    tag_array[snoop_set_r][snoop_way_r].mesi  <= 2'b01;
            end
        end
    end


    // ------------------------------------------------------------------
    // Data array sobre BRAM
    //   NUM_WAYS memorias síncronas independientes (una por vía), cada una
    //   NUM_SETS x LINE_SIZE*8 bits. Lectura Y escritura registradas en el
    //   flanco de reloj — un read combinacional acá NO infiere BRAM en la
    //   mayoría de sintetizadores (Vivado/Yosys), solo LUTRAM o FFs.
    //   Confirmar la inferencia real en A-12.
    //
    //   data_wr_* lo maneja el hit/miss (fill-on-miss, write hit);
    //   acá solo se expone el puerto.
    //
    //   OJO — pendiente para el hit/miss: data_rd_data queda 1
    //   ciclo detrás de req_set/hit_way (por el read síncrono), así que
    //   hit_way hay que registrarlo un ciclo antes de indexar
    //   data_rd_data con él, si no, apunta a la vía equivocada.
    // ------------------------------------------------------------------
    localparam LINE_BITS = LINE_SIZE * 8;

    logic                  data_wr_en   [NUM_WAYS];
    logic [SET_BITS-1:0]   data_wr_set  [NUM_WAYS];
    logic [LINE_BITS-1:0]  data_wr_data [NUM_WAYS];
    logic [LINE_BITS-1:0]  data_rd_data [NUM_WAYS];

    // Mientras la FSM está ocupada (S_HIT/S_WB/S_MISS_WAIT/S_FILL), el bus
    // core_bus_if puede seguir cambiando de dirección sin que nos demos
    // cuenta (req_valid ya bajó, el resto del bus no está garantizado
    // estable) — si el read siguiera indexando por el `req_set` vivo,
    // data_rd_data se corrompería a mitad de un miss largo. Fuera de
    // S_IDLE, releer siempre el mismo set con el que se aceptó la
    // petición (req_set_r, congelado).
    // En S_IDLE, si hay un snoop con flush pendiente lo prioriza sobre una
    // petición local nueva (mismo criterio que el always_ff de más abajo) —
    // así data_rd_data[snoop_way_r] ya está listo un ciclo después, en
    // S_SNOOP_WB, igual que hit_way_r/victim_way_r quedan listos para
    // S_HIT/S_WB.
    wire [SET_BITS-1:0] array_set_addr =
        (state == S_IDLE)  ? (snoop_flush_needed ? snoop_set : req_set)
      : (state == S_SNOOP_WB || state == S_SNOOP_POST_WB) ? snoop_set_r
      : req_set_r;

    for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_way
        logic [LINE_BITS-1:0] mem [NUM_SETS];

        always_ff @(posedge clk) begin
            if (data_wr_en[w])
                mem[data_wr_set[w]] <= data_wr_data[w];
            data_rd_data[w] <= mem[array_set_addr];
        end
    end

    // data_wr_en/set/data los maneja la FSM de hit/miss (fsm_data_wr_*
    // más abajo) — un solo "ganador" por ciclo entre las NUM_WAYS vías.
    for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_wr_decode
        assign data_wr_en[w]   = fsm_data_wr_en && (fsm_data_wr_way == w[WAY_BITS-1:0]);
        assign data_wr_set[w]  = fsm_data_wr_set;
        assign data_wr_data[w] = fsm_data_wr_line;
    end


    // ------------------------------------------------------------------
    // Lógica de hit/miss
    //   FSM de una petición en vuelo a la vez (sin pipelining de misses
    //   concurrentes — ver nota de mem_bus_if.req_data.tag más abajo).
    //
    //   S_IDLE      -> acepta petición nueva; tag_hit ya es combinacional
    //                  este mismo ciclo (ver tag array), así que decide
    //                  S_HIT, S_WB o S_MISS_WAIT al vuelo (si hay miss y
    //                  la vía víctima está dirty, hay que sacarla primero).
    //   S_WB        -> vuelca la línea víctima (dirty) a mem_bus_if antes
    //                  de pedir la línea nueva — si no, esos datos se
    //                  pierden sin más. Solo se visita si victim_dirty.
    //   S_HIT       -> data_rd_data[hit_way_r] ya está listo (el read
    //                  síncrono del data array arrancó en S_IDLE). Sirve
    //                  la palabra pedida, o la mezcla con req_wdata_r si
    //                  era un write.
    //   S_MISS_WAIT -> pide la línea nueva completa a mem_bus_if (una
    //                  sola transacción: mem_bus_if.DATA_SIZE = LINE_SIZE).
    //   S_FILL      -> con la línea ya en mem_bus_if.rsp_data, la mezcla
    //                  con req_wdata_r si el miss era un write
    //                  (write-allocate) y la sirve.
    //   S_SNOOP_WB      -> otro L1 preguntó por una línea que tenemos
    //                  en M: hay que volcarla a mem_bus_if antes de poder
    //                  responder — mismo mecanismo que S_WB, pero
    //                  disparado por un evento remoto, no un miss local.
    //   S_SNOOP_POST_WB -> el flush ya terminó (M -> E, línea limpia). Acá
    //                  se aplica el paso final: E -> S si el remoto quería
    //                  leer, E -> I si quería escribir (ver tabla MESI en
    //                  docs/proposals/tfg_mesi_coherence_design.md §2).
    //   S_SNOOP_HIT     -> igual que S_HIT pero para un snoop que se
    //                  resuelve sin flush (E o S): un ciclo "de reporte",
    //                  usando snoop_resp_mesi_r/dirty_r -- capturados ANTES
    //                  de la escritura E->S/E->I/S->I en S_IDLE, para no
    //                  releer tag_array ya mutado en el mismo ciclo que se
    //                  arma la respuesta (esa carrera hacía que a veces se
    //                  reportara el estado post-transición en vez del que
    //                  tenía la línea cuando llegó el snoop).
    //   S_SNOOP_DONE    -> mismo motivo que S_SNOOP_HIT, pero para el path
    //                  de flush: el ciclo en que S_SNOOP_POST_WB decide la
    //                  escritura final no alcanza para reportar ready ese
    //                  mismo ciclo (la escritura es un always_ff registrado,
    //                  necesita un ciclo más para verse desde afuera) --
    //                  S_SNOOP_DONE es ese ciclo siguiente, ya con la
    //                  escritura confirmada.
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE, S_HIT, S_WB, S_MISS_WAIT, S_FILL,
        S_SNOOP_WB, S_SNOOP_POST_WB, S_SNOOP_HIT, S_SNOOP_DONE
    } state_t;
    state_t state;

    // petición latcheada al aceptarla en S_IDLE
    logic                     req_rw_r;
    logic [WAY_BITS-1:0]      hit_way_r;
    logic [SET_BITS-1:0]      req_set_r;
    logic [TAG_BITS-1:0]      req_tag_r;
    logic [OFFSET_BITS-1:0]   req_off_r;
    logic [WORD_SIZE*8-1:0]   req_wdata_r;
    logic [WORD_SIZE-1:0]     req_byteen_r;
    logic [CORE_TAG_WIDTH-1:0] req_ctag_r;
    logic                     mem_req_sent_r;
    logic [LINE_BITS-1:0]     fetched_line_r;  // línea recién llegada de mem_bus_if, para usar en S_FILL

    // vía víctima y su tag, congelados en S_IDLE — todo lo de abajo usa
    // estos registros, nunca `victim_way`/`tag_array[...].tag` en vivo
    // (que siguen al `req_set` vivo y ya no valen fuera de S_IDLE).
    logic [WAY_BITS-1:0]      victim_way_r;
    logic [TAG_BITS-1:0]      victim_tag_r;

    // snoop remoto latcheado al entrar a S_SNOOP_WB (mismo criterio que los
    // registros de arriba para un miss local: todo lo que S_SNOOP_WB/
    // S_SNOOP_POST_WB necesitan se congela acá, nunca se relee snoop_bus_if
    // en vivo fuera de S_IDLE — la petición remota no está garantizada
    // estable más allá de ese ciclo).
    logic [SET_BITS-1:0]      snoop_set_r;
    logic [WAY_BITS-1:0]      snoop_way_r;
    logic [TAG_BITS-1:0]      snoop_tag_r;
    logic                     snoop_rw_r;

    // snapshot del estado MESI/dirty de la línea ANTES de aplicar la
    // transición E->S/E->I/S->I -- lo que se le reporta al que preguntó en
    // S_SNOOP_HIT (ver comentario de S_SNOOP_HIT más arriba).
    logic [1:0]                snoop_resp_mesi_r;
    logic                      snoop_resp_dirty_r;

    // No acepta petición local nueva el ciclo en que hay que atender un
    // snoop remoto  (hit local en el tag array). 
    // Un miss de snoop (no le toca a este L1) no bloquea nada.
    assign core_bus_if.req_ready = (state == S_IDLE) && !snoop_any_hit;

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_IDLE;
            mem_req_sent_r <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (snoop_bus_if.snoop_valid && snoop_tag_hit) begin
                        // un evento remoto le toca a este L1: tiene prioridad sobre
                        // aceptar una petición local nueva este ciclo (ver
                        // core_bus_if.req_ready más arriba). La transición
                        // MESI en sí (E->S, E->I/S->I) la aplica el
                        // always_ff de tag_array de más arriba en paralelo;
                        // acá solo se decide si hace falta ir a S_SNOOP_WB
                        // (M) y, si es así, se latchean los registros.
                        if (tag_array[snoop_set][snoop_hit_way].mesi == 2'b11) begin
                            // M: hace falta flush antes de poder responder -> S_SNOOP_WB
                            snoop_set_r <= snoop_set;
                            snoop_way_r <= snoop_hit_way;
                            snoop_tag_r <= snoop_tag;
                            snoop_rw_r  <= snoop_bus_if.snoop_rw;
                            state       <= S_SNOOP_WB;
                        end else begin
                            // E o S: sin flush. Guarda el estado ANTES de la
                            // transición (E->S/E->I/S->I, aplicada en
                            // paralelo por el always_ff de tag_array) para
                            // reportarlo en S_SNOOP_HIT sin releer
                            // tag_array ya mutado.
                            snoop_resp_mesi_r  <= tag_array[snoop_set][snoop_hit_way].mesi;
                            snoop_resp_dirty_r <= tag_array[snoop_set][snoop_hit_way].dirty;
                            state <= S_SNOOP_HIT;
                        end
                    end else if (core_bus_if.req_valid && core_bus_if.req_ready) begin
                        req_rw_r     <= core_bus_if.req_data.rw;
                        hit_way_r    <= hit_way;
                        req_set_r    <= req_set;
                        req_tag_r    <= req_tag;
                        req_off_r    <= core_bus_if.req_data.addr[OFFSET_BITS-1:0];
                        req_wdata_r  <= core_bus_if.req_data.data;
                        req_byteen_r <= core_bus_if.req_data.byteen;
                        req_ctag_r   <= core_bus_if.req_data.tag;
                        victim_way_r <= victim_way;
                        victim_tag_r <= tag_array[req_set][victim_way].tag;
                        if (tag_hit)
                            state <= S_HIT;
                        else if (tag_array[req_set][victim_way].valid
                                  && tag_array[req_set][victim_way].dirty)
                            state <= S_WB;          // hay que desalojar algo sucio primero
                        else
                            state <= S_MISS_WAIT;   // vía libre o ya limpia, directo al refill
                    end
                end
                S_HIT: begin
                    if (core_bus_if.rsp_ready)
                        state <= S_IDLE;
                end
                S_WB: begin
                    if (mem_bus_if.req_valid && mem_bus_if.req_ready)
                        mem_req_sent_r <= 1'b1;
                    if (mem_bus_if.rsp_valid && mem_bus_if.rsp_ready) begin
                        mem_req_sent_r <= 1'b0;
                        state          <= S_MISS_WAIT;  // ahora sí, pedir la línea nueva
                    end
                end
                S_MISS_WAIT: begin
                    if (mem_bus_if.req_valid && mem_bus_if.req_ready)
                        mem_req_sent_r <= 1'b1;
                    if (mem_bus_if.rsp_valid && mem_bus_if.rsp_ready) begin
                        mem_req_sent_r <= 1'b0;
                        fetched_line_r <= mem_bus_if.rsp_data.data;
                        state          <= S_FILL;
                    end
                end
                S_FILL: begin
                    if (core_bus_if.rsp_ready)
                        state <= S_IDLE;
                end
                S_SNOOP_WB: begin
                    // mismo mecanismo que S_WB, pero volcando la línea que
                    // pidió el snoop (snoop_way_r/snoop_set_r/snoop_tag_r),
                    // no la víctima de un miss local. La transición
                    // M->E en sí la aplica el always_ff de tag_array.
                    if (mem_bus_if.req_valid && mem_bus_if.req_ready)
                        mem_req_sent_r <= 1'b1;
                    if (mem_bus_if.rsp_valid && mem_bus_if.rsp_ready) begin
                        mem_req_sent_r <= 1'b0;
                        state          <= S_SNOOP_POST_WB;
                    end
                end
                S_SNOOP_POST_WB: begin
                    // segundo paso (E->I o E->S, ver tag_array más arriba):
                    // cierra el M->S de libro en dos pasos explícitos. La
                    // escritura recién se ve desde afuera un ciclo después
                    // (always_ff registrado) -> reportar ready acá sería
                    // temprano; se reporta en S_SNOOP_DONE.
                    state <= S_SNOOP_DONE;
                end
                S_SNOOP_HIT: begin
                    state <= S_IDLE;
                end
                S_SNOOP_DONE: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- puerto hacia mem_bus_if (activo en S_WB, S_MISS_WAIT y S_SNOOP_WB) ----
    // dirección de línea: mem_bus_if.DATA_SIZE = LINE_SIZE, así que su
    // ADDR_WIDTH ya excluye los bits de offset dentro de línea — {tag,set}
    // es exactamente esa dirección. En S_WB es la dirección VIEJA (la
    // víctima, {victim_tag_r,req_set_r}); en S_MISS_WAIT es la NUEVA
    // ({req_tag_r,req_set_r}) — mismo set, tag distinto. En S_SNOOP_WB es la
    // línea que pidió el snoop ({snoop_tag_r,snoop_set_r}).
    assign mem_bus_if.req_valid       = (state == S_WB || state == S_MISS_WAIT || state == S_SNOOP_WB) && !mem_req_sent_r;
    assign mem_bus_if.req_data.rw     = (state == S_WB || state == S_SNOOP_WB);  // write-back escribe; el refill lee
    assign mem_bus_if.req_data.addr   = (state == S_WB)      ? {victim_tag_r, req_set_r}
                                       : (state == S_SNOOP_WB) ? {snoop_tag_r, snoop_set_r}
                                       : {req_tag_r, req_set_r};
    assign mem_bus_if.req_data.data   = (state == S_SNOOP_WB) ? data_rd_data[snoop_way_r]
                                                                : data_rd_data[victim_way_r];  // solo se usan en WB
    assign mem_bus_if.req_data.byteen = '1;
    assign mem_bus_if.req_data.attr   = '0;
    // TODO: con más de un miss en vuelo hace falta un tag real acá para
    // no confundir respuestas — con una sola petición a la vez alcanza con 0.
    assign mem_bus_if.req_data.tag    = '0;
    assign mem_bus_if.rsp_ready       = (state == S_WB || state == S_MISS_WAIT || state == S_SNOOP_WB);

    // ---- merge de escritura (write-hit o write-allocate en un miss) ----
    // reemplaza, dentro de la línea, solo la palabra en req_off_r según
    // byteen — el resto de la línea queda igual.
    function automatic logic [LINE_BITS-1:0] merge_word(
        input logic [LINE_BITS-1:0]    line_in,
        input logic [OFFSET_BITS-1:0]  word_off,
        input logic [WORD_SIZE*8-1:0]  wdata,
        input logic [WORD_SIZE-1:0]    byteen
    );
        logic [LINE_BITS-1:0] result;
        result = line_in;
        for (int b = 0; b < WORD_SIZE; ++b)
            if (byteen[b])
                result[(word_off*WORD_SIZE + b)*8 +: 8] = wdata[b*8 +: 8];
        return result;
    endfunction

    wire [LINE_BITS-1:0] hit_line_old  = data_rd_data[hit_way_r];
    wire [LINE_BITS-1:0] hit_line_new  = merge_word(hit_line_old, req_off_r, req_wdata_r, req_byteen_r);
    wire [LINE_BITS-1:0] fill_line_old = mem_bus_if.rsp_data.data;
    wire [LINE_BITS-1:0] fill_line_new = merge_word(fill_line_old, req_off_r, req_wdata_r, req_byteen_r);

    // ---- puerto de escritura hacia el data array ----
    logic                  fsm_data_wr_en;
    logic [WAY_BITS-1:0]   fsm_data_wr_way;
    logic [SET_BITS-1:0]   fsm_data_wr_set;
    logic [LINE_BITS-1:0]  fsm_data_wr_line;
    always_comb begin
        fsm_data_wr_en   = 1'b0;
        fsm_data_wr_way  = hit_way_r;
        fsm_data_wr_set  = req_set_r;
        fsm_data_wr_line = hit_line_new;
        if (state == S_HIT && req_rw_r) begin
            fsm_data_wr_en = 1'b1;              // write-hit: guarda la línea mezclada
        end else if (state == S_MISS_WAIT && mem_bus_if.rsp_valid && mem_bus_if.rsp_ready) begin
            fsm_data_wr_en   = 1'b1;            // fill: guarda la línea (mezclada si era write)
            fsm_data_wr_way  = victim_way_r;
            fsm_data_wr_line = req_rw_r ? fill_line_new : fill_line_old;
        end
    end

    // ---- respuesta hacia el pipeline ----
    // OJO: mem_bus_if.rsp_data solo vale durante el ciclo de S_MISS_WAIT
    // en que llega (rsp_valid alto); en S_FILL (un ciclo después) hay que
    // usar fetched_line_r, no fill_line_old/fill_line_new.
    wire [WORD_SIZE*8-1:0] hit_rsp_word  = hit_line_old[req_off_r*WORD_SIZE*8 +: WORD_SIZE*8];
    wire [WORD_SIZE*8-1:0] fill_rsp_word = fetched_line_r[req_off_r*WORD_SIZE*8 +: WORD_SIZE*8];

    assign core_bus_if.rsp_valid    = (state == S_HIT) || (state == S_FILL);
    assign core_bus_if.rsp_data.tag = req_ctag_r;
    assign core_bus_if.rsp_data.data = (state == S_HIT) ? hit_rsp_word : fill_rsp_word;


    // ------------------------------------------------------------------
    // Señal de stall hacia el pipeline
    //   Ya cableada como parte de la FSM de arriba: `core_bus_if.req_ready
    //   = (state == S_IDLE)` (línea ~206) — no acepta una petición nueva
    //   mientras hay un miss/refill en curso. No hace falta un bloque
    //   aparte: es inherente a que la FSM solo tiene una petición en
    //   vuelo a la vez.
    // ------------------------------------------------------------------


    // ------------------------------------------------------------------
    // Write-back
    //   Reemplazo de línea dirty (M) en un miss: resuelto con el estado
    //   S_WB de arriba (S_IDLE -> S_WB -> S_MISS_WAIT cuando la vía
    //   víctima está valid+dirty). Vuelca data_rd_data[victim_way_r] a
    //   {victim_tag_r,req_set_r} antes de pedir la línea nueva.
    //
    //   TODO (coherencia, fuera de este alcance): write-back disparado por
    //   un snoop de invalidación sobre una línea M (snoop_bus_if) — ese es
    //   un tercer disparador de write-back además del miss local, y
    //   necesita su propio camino porque puede llegar mientras la FSM ya
    //   está ocupada con otra cosa.
    // ------------------------------------------------------------------


    // ------------------------------------------------------------------
    // Lado snooper (A-6): responde a los eventos que llegan por
    // snoop_bus_if. La transición en sí ya la aplica el always_ff de más
    // arriba (S_IDLE/S_SNOOP_WB/S_SNOOP_POST_WB) — acá solo se arma la
    // respuesta que el bus necesita para saber qué pasó (ready/hit/state/
    // dirty). snoop_data se deja en cero: por diseño los datos siempre
    // viajan por mem_bus_if, nunca cache-a-cache directo (ver
    // docs/proposals/tfg_mesi_coherence_design.md §1.1).
    //
    // Todas las respuestas se arman en un estado de "reporte" de un ciclo
    // (S_SNOOP_HIT para E/S sin flush, S_SNOOP_DONE para M con flush) que
    // arranca DESPUÉS de que la escritura correspondiente ya se aplicó y
    // ya es visible — nunca releyendo tag_array en el mismo ciclo en que
    // se lo muta (esa carrera reportaba a veces el estado ya transicionado
    // en vez del que tenía la línea cuando llegó el snoop). Ver
    // snoop_resp_mesi_r/dirty_r (capturados en S_IDLE, antes de la
    // escritura) para el caso E/S.
    // ------------------------------------------------------------------
    assign snoop_bus_if.snoop_ready = (state == S_SNOOP_HIT) || (state == S_SNOOP_DONE);
    assign snoop_bus_if.snoop_hit   = (state == S_SNOOP_HIT) || (state == S_SNOOP_DONE);
    assign snoop_bus_if.snoop_state = (state == S_SNOOP_DONE) ? 2'b11  // M (antes del flush)
                                     : (state == S_SNOOP_HIT) ? snoop_resp_mesi_r
                                     : 2'b00;
    assign snoop_bus_if.snoop_dirty = (state == S_SNOOP_DONE)
                                     || (state == S_SNOOP_HIT && snoop_resp_dirty_r);
    assign snoop_bus_if.snoop_data  = '0;

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
endmodule
