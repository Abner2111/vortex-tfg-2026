// A-14: integra l2_cache.sv en una unidad de cómputo real -- NUM_CORES
// VX_core (stock Vortex) con su propia l1_cache.sv cada uno (mismo splice
// que hw/unittest/core/VX_core_top.sv, A-9), coordinando coherencia entre
// sí vía snoop_bus.sv (A-7/A-8), compartiendo UNA l2_cache.sv (A-11), y la
// L2 saliendo por el árbitro global REAL de Vortex (VX_mem_bus_arb, sin
// modificar) antes de llegar a "memoria" (mockeada afuera, en C++).
//
// Por qué hace falta fan-out/arbitraje real y no cablear a mano como A-9:
// A-9 tenía un solo VX_core, así que DCR se cableaba a mano a los dos
// únicos oyentes (VX_kmu y VX_core). Con NUM_CORES>1 eso deja de ser
// válido eléctricamente -- N esclavos no pueden manejar `req_ready` del
// mismo bus a la vez -- y además VX_cta_dispatch.sv (el admisor de CTAs
// de cada VX_core) no filtra nada por CORE_ID: un `kmu_bus_if` compartido
// sin árbitro real simplemente no reparte el trabajo. Se usan los mismos
// módulos que el sistema real (VX_socket.sv): VX_dcr_arb (broadcast real
// de DCR) y VX_kmu_bus_arb (reparto round-robin de CTAs, 1 entrada -> N
// salidas) -- ninguno de los dos se modifica.
//
// Por qué L2 no participa de la coherencia: ver el comentario de cabecera
// de l2_cache.sv -- la coherencia vive enteramente entre las L1
// (snoop_bus.sv); L2 es una caché compartida sin noción de coherencia
// propia.
`include "VX_define.vh"

module compute_unit import VX_gpu_pkg::*; #(
    parameter NUM_CORES = 4,
    parameter NUM_BANKS = 4,

    // L1 (una por núcleo) -- mismos valores achicados de A-9, no los
    // defaults reales de l1_cache.sv (ver VX_core_top.sv: con
    // WORD_SIZE=DCACHE_WORD_SIZE fijo, 16 es el mínimo válido de línea).
    parameter TFG_L1_LINE_SIZE     = 16,
    parameter TFG_L1_MEM_TAG_WIDTH = 8,

    // L2 (compartida). LINE_SIZE de L2 = LINE_SIZE de la L1 (ver
    // l2_cache.sv: transferencias de línea completa, 1:1, sin merge) --
    // con TFG_L1_LINE_SIZE=16 fijo, BANK_SIZE tiene que ser >=
    // LINE_SIZE*NUM_WAYS*2 para que NUM_SETS (=BANK_SIZE/(LINE_SIZE*
    // NUM_WAYS)) no colapse a 1 (SET_BITS=0, ancho negativo en
    // l2_cache.sv) -- encontrado por el propio lint al armar este módulo.
    parameter TFG_L2_BANK_SIZE     = 64,
    parameter TFG_L2_NUM_WAYS      = 2,
    parameter TFG_L2_MEM_TAG_WIDTH = 8,

    parameter TFG_L1_MEM_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(TFG_L1_LINE_SIZE)
) (
    input wire clk,
    input wire reset,

    input wire start,
    output wire [NUM_CORES-1:0] busy,

    // DCR: broadcast a VX_kmu (puertos crudos, igual que A-9 -- VX_kmu no
    // es consumidor del bus de fan-out) y a los NUM_CORES VX_core (vía
    // VX_dcr_arb).
    input wire                          dcr_req_valid,
    input wire                          dcr_req_rw,
    input wire [VX_DCR_ADDR_WIDTH-1:0]  dcr_req_addr,
    input wire [VX_DCR_DATA_WIDTH-1:0]  dcr_req_data,
    output wire                         dcr_rsp_valid,
    output wire [VX_DCR_DATA_WIDTH-1:0] dcr_rsp_data,

    // icache: una por núcleo -- cada VX_core.icache_bus_if es independiente
    // (no hay cache de instrucciones compartida en este TFG).
    VX_mem_bus_if.master icache_bus_if [NUM_CORES],

    // Único puerto hacia "memoria", YA del otro lado del árbitro global
    // (VX_mem_bus_arb) -- ver comentario de cabecera.
    VX_mem_bus_if.master mem_bus_if,

    // Debug (solo test, no sintetizable): estado interno de cada L1, para
    // verificar un acceso de punta a punta sin saber de antemano qué
    // núcleo ejecuta el CTA (el reparto es round-robin).
    // Ya reducido por vía (ver g_core más abajo): found=alguna vía tiene
    // tag=2 válida; dirty/word0 son los de ESA vía.
    output wire [NUM_CORES-1:0]       dbg_dst_found,
    output wire [NUM_CORES-1:0]       dbg_dst_dirty,
    output wire [NUM_CORES-1:0][63:0] dbg_dst_word0
);
    // ------------------------------------------------------------------
    // KMU único + fan-out de DCR y de CTAs (ver comentario de cabecera)
    // ------------------------------------------------------------------
    VX_kmu_bus_if kmu_out_if [1] ();
    wire kmu_busy;
    `UNUSED_VAR (kmu_busy)

    VX_kmu #(
        .INSTANCE_ID (`SFORMATF(("kmu")))
    ) kmu (
        .clk           (clk),
        .reset         (reset),
        .dcr_req_valid (dcr_req_valid),
        .dcr_req_rw    (dcr_req_rw),
        .dcr_req_addr  (dcr_req_addr),
        .dcr_req_data  (dcr_req_data),
        .start         (start),
        .busy          (kmu_busy),
        .kmu_bus_if    (kmu_out_if[0])
    );

    VX_kmu_bus_if per_core_kmu_bus_if [NUM_CORES] ();

    VX_kmu_bus_arb #(
        .NUM_INPUTS  (1),
        .NUM_OUTPUTS (NUM_CORES),
        .DEST_LSB    (0)
    ) kmu_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (kmu_out_if),
        .bus_out_if (per_core_kmu_bus_if)
    );

    VX_dcr_bus_if dcr_in_if ();
    assign dcr_in_if.req_valid = dcr_req_valid;
    assign dcr_in_if.req_data  = '{rw: dcr_req_rw, addr: dcr_req_addr, data: dcr_req_data};
    assign dcr_rsp_valid       = dcr_in_if.rsp_valid;
    assign dcr_rsp_data        = dcr_in_if.rsp_data.data;

    VX_dcr_bus_if per_core_dcr_bus_if [NUM_CORES] ();

    VX_dcr_arb #(
        .NUM_REQS (NUM_CORES)
    ) dcr_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (dcr_in_if),
        .bus_out_if (per_core_dcr_bus_if)
    );

    // ------------------------------------------------------------------
    // Snoop bus: conecta las NUM_CORES l1_cache.sv entre sí (A-7/A-8) --
    // a diferencia de A-9 (un solo L1, atado en reposo), acá SÍ hace
    // falta coherencia real entre instancias.
    // ------------------------------------------------------------------
    // req_if[i]: la consulta PROPIA de l1_cache[i] (su modport .master,
    // l1_cache.snoop_mst_if) -- el bus la RECIBE (modport .snooper).
    // rsp_if[i]: el broadcast del bus HACIA l1_cache[i] (su modport
    // .snooper, l1_cache.snoop_bus_if) -- el bus lo EMITE (modport
    // .master). Ver el comentario de cabecera de snoop_bus.sv.
    VX_snoop_bus_if #(
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH),
        .LINE_SIZE  (TFG_L1_LINE_SIZE)
    ) l1_own_query_if [NUM_CORES] ();

    VX_snoop_bus_if #(
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH),
        .LINE_SIZE  (TFG_L1_LINE_SIZE)
    ) l1_broadcast_if [NUM_CORES] ();

    snoop_bus #(
        .NUM_L1     (NUM_CORES),
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH),
        .LINE_SIZE  (TFG_L1_LINE_SIZE)
    ) snoops (
        .clk    (clk),
        .reset  (reset),
        .req_if (l1_own_query_if),
        .rsp_if (l1_broadcast_if)
    );

    // line_lock: candado por línea entre las NUM_CORES l1_cache.sv (ver
    // VX_line_lock_if.sv / line_lock.sv, y tfg_cluster.sv para el porqué).
    VX_line_lock_if #(
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH)
    ) l1_lock_if [NUM_CORES] ();

    line_lock #(
        .NUM_L1     (NUM_CORES),
        .ADDR_WIDTH (TFG_L1_MEM_ADDR_WIDTH)
    ) lock (
        .clk    (clk),
        .reset  (reset),
        .req_if (l1_lock_if)
    );

    // ------------------------------------------------------------------
    // L2 compartida: un core_bus_if por L1.
    // ------------------------------------------------------------------
    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (TFG_L1_MEM_TAG_WIDTH)
    ) l1_to_l2_bus_if [NUM_CORES] ();

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (TFG_L2_MEM_TAG_WIDTH)
    ) l2_bank_bus_if [NUM_BANKS] ();

    l2_cache #(
        .NUM_CORES      (NUM_CORES),
        .NUM_BANKS      (NUM_BANKS),
        .BANK_SIZE      (TFG_L2_BANK_SIZE),
        .NUM_WAYS       (TFG_L2_NUM_WAYS),
        .LINE_SIZE      (TFG_L1_LINE_SIZE),
        .CORE_TAG_WIDTH (TFG_L1_MEM_TAG_WIDTH),
        .MEM_TAG_WIDTH  (TFG_L2_MEM_TAG_WIDTH)
    ) l2 (
        .clk         (clk),
        .reset       (reset),
        .core_bus_if (l1_to_l2_bus_if),
        .mem_bus_if  (l2_bank_bus_if)
    );

    // ------------------------------------------------------------------
    // Árbitro global (VX_mem_bus_arb, real, SIN modificar) -- fusiona los
    // NUM_BANKS puertos de L2 en el único mem_bus_if externo. El tag de
    // salida queda ensanchado en $clog2(NUM_BANKS) bits (ver
    // VX_bits_insert/VX_bits_remove adentro de VX_mem_bus_arb): quien
    // sirva mem_bus_if afuera tiene que ecoar ese tag tal cual.
    // ------------------------------------------------------------------
    localparam ARB_TAG_WIDTH = TFG_L2_MEM_TAG_WIDTH + `CLOG2(NUM_BANKS);

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (ARB_TAG_WIDTH)
    ) global_arb_out_if [1] ();

    VX_mem_bus_arb #(
        .NUM_INPUTS  (NUM_BANKS),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (TFG_L1_LINE_SIZE),
        .TAG_WIDTH   (TFG_L2_MEM_TAG_WIDTH),
        .TAG_SEL_IDX (0),
        .ARBITER     ("R")
    ) global_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (l2_bank_bus_if),
        .bus_out_if (global_arb_out_if)
    );

    `ASSIGN_VX_MEM_BUS_IF (mem_bus_if, global_arb_out_if[0]);

    // ------------------------------------------------------------------
    // NUM_CORES x (VX_core + l1_cache splice) -- mismo patrón exacto que
    // hw/unittest/core/VX_core_top.sv (A-9), replicado con genvar.
    // ------------------------------------------------------------------
    VX_gbar_bus_if gbar_bus_if [NUM_CORES] ();

    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_core

        // gbar: tie-off (este programa de prueba no usa barreras globales,
        // igual que A-9).
        assign gbar_bus_if[i].req_ready   = 1'b1;
        assign gbar_bus_if[i].rsp_valid   = 1'b0;
        assign gbar_bus_if[i].rsp_data.id = '0;

        if (DCACHE_NUM_REQS != 1) begin : g_check_num_reqs
            initial $fatal(1, "compute_unit (A-14): l1_cache.sv splice necesita DCACHE_NUM_REQS==1 (dio %0d)", DCACHE_NUM_REQS);
        end

        VX_mem_bus_if #(
            .DATA_SIZE (DCACHE_WORD_SIZE),
            .TAG_WIDTH (DCACHE_TAG_WIDTH)
        ) dcache_bus_if [DCACHE_NUM_REQS] ();

        l1_cache #(
            .CACHE_SIZE     (`VX_CFG_DCACHE_SIZE),
            .LINE_SIZE      (TFG_L1_LINE_SIZE),
            .NUM_WAYS       (`VX_CFG_DCACHE_NUM_WAYS),
            .WORD_SIZE      (DCACHE_WORD_SIZE),
            .CORE_TAG_WIDTH (DCACHE_TAG_WIDTH),
            .MEM_TAG_WIDTH  (TFG_L1_MEM_TAG_WIDTH)
        ) tfg_l1 (
            .clk          (clk),
            .reset        (reset),
            .core_bus_if  (dcache_bus_if[0]),
            .mem_bus_if   (l1_to_l2_bus_if[i]),
            .snoop_bus_if (l1_broadcast_if[i]),
            .snoop_mst_if (l1_own_query_if[i]),
            .lock_if      (l1_lock_if[i])
        );

        VX_core #(
            .INSTANCE_ID (`SFORMATF(("core%0d", i))),
            .CORE_ID     (i)
        ) core (
            .clk            (clk),
            .reset          (reset),
            .dcr_bus_if     (per_core_dcr_bus_if[i]),
            .dcache_bus_if  (dcache_bus_if),
            .icache_bus_if  (icache_bus_if[i]),
            .kmu_bus_if     (per_core_kmu_bus_if[i]),
            .gbar_bus_if    (gbar_bus_if[i]),
            .busy           (busy[i])
        );

        // Debug: igual técnica que A-9 (set=0/tag=2 para kDstAddr=0x2000
        // en esta config -- ver hw/unittest/core/VX_core_top.sv), pero
        // ahora reducida acá mismo (en vez de exponer las 4 vías crudas
        // hacia afuera): no se sabe de antemano qué núcleo ejecuta el
        // único CTA del test (reparto round-robin), así que el C++
        // escanea dbg_dst_found por núcleo en vez de por vía.
        logic       dst_found_w;
        logic       dst_dirty_w;
        logic [63:0] dst_word0_w;
        always_comb begin
            dst_found_w = 1'b0;
            dst_dirty_w = 1'b0;
            dst_word0_w = '0;
            for (int w = 0; w < 4; ++w) begin
                if (tfg_l1.tag_array[0][w].valid && (tfg_l1.tag_array[0][w].tag == 2)) begin
                    dst_found_w = 1'b1;
                    dst_dirty_w = tfg_l1.tag_array[0][w].dirty;
                    // mem_local (no mem_snoop): mismo dato en las dos
                    // copias espejadas, es la misma que alimenta el
                    // camino local de este debug peek.
                    case (w)
                        0: dst_word0_w = tfg_l1.g_data_way[0].mem_local[0][63:0];
                        1: dst_word0_w = tfg_l1.g_data_way[1].mem_local[0][63:0];
                        2: dst_word0_w = tfg_l1.g_data_way[2].mem_local[0][63:0];
                        default: dst_word0_w = tfg_l1.g_data_way[3].mem_local[0][63:0];
                    endcase
                end
            end
        end
        assign dbg_dst_found[i] = dst_found_w;
        assign dbg_dst_dirty[i] = dst_dirty_w;
        assign dbg_dst_word0[i] = dst_word0_w;

    end

endmodule
