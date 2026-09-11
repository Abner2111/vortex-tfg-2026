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

    // invalidar todas las líneas en reset; los writes de fill/write-back
    // sobre tag_array[req_set][hit_way o víctima] los cablea el
    // hit/miss (necesita decidir primero qué vía se llena/desaloja).
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int s = 0; s < NUM_SETS; ++s)
                for (int w = 0; w < NUM_WAYS; ++w)
                    tag_array[s][w].valid <= 1'b0;
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

        // sin lógica de hit/miss todavía nadie escribe: tie-off para que
        // elabore. El TODO de hit/miss reemplaza estos tres assigns.
        assign data_wr_en[w]   = 1'b0;
        assign data_wr_set[w]  = '0;
        assign data_wr_data[w] = '0;
    end


    // ------------------------------------------------------------------
    // TODO (A-5): Lógica de hit/miss
    //   - comparar tag array vs. core_bus_if.req_data.addr
    //   - hit  -> servir desde data array (read) o escribir en sitio (write)
    //   - miss -> iniciar refill hacia mem_bus_if; si la vía víctima está
    //             dirty (M), primero hacer write-back (ver más abajo)
    // ------------------------------------------------------------------


    // ------------------------------------------------------------------
    // TODO (A-5): Señal de stall hacia el pipeline
    //   - core_bus_if.req_ready = 0 mientras haya un miss/refill/writeback
    //     en curso para esa dirección
    //   - respetar el protocolo valid/ready de VX_mem_bus_if: no bajar
    //     req_ready a mitad de una transacción ya aceptada
    // ------------------------------------------------------------------


    // ------------------------------------------------------------------
    // TODO (A-5): Write-back
    //   - reemplazo de línea dirty (M): volcar a mem_bus_if antes del refill
    //   - snoop de invalidación sobre línea M (snoop_bus_if): volcar y
    //     transicionar a I, entregar los datos si el snoop pide compartir
    // ------------------------------------------------------------------


    // Placeholder para que el módulo elabore mientras se completan los
    // bloques de arriba. Sin esto, Verilator/synth no tiene qué conectar
    // en las tres interfaces. Borrar a medida que cada bloque se implementa.
    assign core_bus_if.req_ready    = 1'b0;
    assign core_bus_if.rsp_valid    = 1'b0;
    assign core_bus_if.rsp_data     = '0;

    assign mem_bus_if.req_valid     = 1'b0;
    assign mem_bus_if.req_data      = '0;
    assign mem_bus_if.rsp_ready     = 1'b0;

    assign snoop_bus_if.snoop_ready = 1'b0;
    assign snoop_bus_if.snoop_hit   = 1'b0;
    assign snoop_bus_if.snoop_state = 2'b00;  // MESI_I — ver VX_snoop_bus_if.sv
    assign snoop_bus_if.snoop_dirty = 1'b0;
    assign snoop_bus_if.snoop_data  = '0;

/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
endmodule
