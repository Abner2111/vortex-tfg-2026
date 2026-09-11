// TFG: jerarquía de memoria L1+L2 con coherencia MESI (derivado del TFG de
// Chacón Alfaro). Placeholder de l1_cache.sv (A-5) — estructura y puertos
// definidos, lógica interna pendiente. Cada bloque TODO es una actividad
// de A-5 en el anteproyecto.
//
// Interfaces (A-4):
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
    // tras un miss, marcar dirty en un write-hit) los maneja la FSM de
    // hit/miss más abajo, en este mismo always_ff para no tener dos
    // procesos manejando tag_array.
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
                // TODO (write-back): si tag_array[req_set_r][victim_way].dirty
                // ya estaba en 1 acá, esos datos se pierden — falta volcarlos
                // a mem_bus_if antes de este punto. Ver TODO de write-back.
                tag_array[req_set_r][victim_way].valid <= 1'b1;
                tag_array[req_set_r][victim_way].dirty <= req_rw_r;
                tag_array[req_set_r][victim_way].mesi  <= req_rw_r ? 2'b11 : 2'b10; // M : E
                tag_array[req_set_r][victim_way].tag   <= req_tag_r;
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

    for (genvar w = 0; w < NUM_WAYS; ++w) begin : g_data_way
        logic [LINE_BITS-1:0] mem [NUM_SETS];

        always_ff @(posedge clk) begin
            if (data_wr_en[w])
                mem[data_wr_set[w]] <= data_wr_data[w];
            data_rd_data[w] <= mem[req_set];
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
    //                  S_HIT o S_MISS_WAIT al vuelo.
    //   S_HIT       -> data_rd_data[hit_way_r] ya está listo (el read
    //                  síncrono del data array arrancó en S_IDLE). Sirve
    //                  la palabra pedida, o la mezcla con req_wdata_r si
    //                  era un write.
    //   S_MISS_WAIT -> pide la línea completa a mem_bus_if (una sola
    //                  transacción: mem_bus_if.DATA_SIZE = LINE_SIZE).
    //   S_FILL      -> con la línea ya en mem_bus_if.rsp_data, la mezcla
    //                  con req_wdata_r si el miss era un write
    //                  (write-allocate) y la sirve.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] { S_IDLE, S_HIT, S_MISS_WAIT, S_FILL } state_t;
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

    assign core_bus_if.req_ready = (state == S_IDLE);

    always_ff @(posedge clk) begin
        if (reset) begin
            state          <= S_IDLE;
            mem_req_sent_r <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (core_bus_if.req_valid && core_bus_if.req_ready) begin
                        req_rw_r     <= core_bus_if.req_data.rw;
                        hit_way_r    <= hit_way;
                        req_set_r    <= req_set;
                        req_tag_r    <= req_tag;
                        req_off_r    <= core_bus_if.req_data.addr[OFFSET_BITS-1:0];
                        req_wdata_r  <= core_bus_if.req_data.data;
                        req_byteen_r <= core_bus_if.req_data.byteen;
                        req_ctag_r   <= core_bus_if.req_data.tag;
                        state        <= tag_hit ? S_HIT : S_MISS_WAIT;
                    end
                end
                S_HIT: begin
                    if (core_bus_if.rsp_ready)
                        state <= S_IDLE;
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
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- puerto hacia mem_bus_if (solo activo en S_MISS_WAIT) ----
    // dirección de línea: mem_bus_if.DATA_SIZE = LINE_SIZE, así que su
    // ADDR_WIDTH ya excluye los bits de offset dentro de línea — {tag,set}
    // es exactamente esa dirección.
    assign mem_bus_if.req_valid       = (state == S_MISS_WAIT) && !mem_req_sent_r;
    assign mem_bus_if.req_data.rw     = 1'b0;               // el refill siempre lee
    assign mem_bus_if.req_data.addr   = {req_tag_r, req_set_r};
    assign mem_bus_if.req_data.data   = '0;
    assign mem_bus_if.req_data.byteen = '1;
    assign mem_bus_if.req_data.attr   = '0;
    // TODO: con más de un miss en vuelo hace falta un tag real acá para
    // no confundir respuestas — con una sola petición a la vez alcanza con 0.
    assign mem_bus_if.req_data.tag    = '0;
    assign mem_bus_if.rsp_ready       = (state == S_MISS_WAIT);

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
            fsm_data_wr_way  = victim_way;
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
    // TODO (A-5): Write-back
    //   - reemplazo de línea dirty (M): volcar a mem_bus_if antes del refill
    //   - snoop de invalidación sobre línea M (snoop_bus_if): volcar y
    //     transicionar a I, entregar los datos si el snoop pide compartir
    // ------------------------------------------------------------------


    // core_bus_if.req_ready/rsp_valid/rsp_data y mem_bus_if.req_valid/
    // req_data/rsp_ready ya los maneja la FSM de hit/miss de arriba.
    // snoop_bus_if sigue placeholder: la coherencia entre L1s es trabajo
    // aparte (fuera del alcance de este TODO).
    assign snoop_bus_if.snoop_ready = 1'b0;
    assign snoop_bus_if.snoop_hit   = 1'b0;
    assign snoop_bus_if.snoop_state = 2'b00;  // MESI_I — ver VX_snoop_bus_if.sv
    assign snoop_bus_if.snoop_dirty = 1'b0;
    assign snoop_bus_if.snoop_data  = '0;

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
endmodule
