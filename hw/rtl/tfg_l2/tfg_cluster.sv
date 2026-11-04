// Reemplazo de hw/rtl/VX_cluster.sv -- mismo contrato externo (lo mínimo
// que necesita calzar para que Vortex.sv lo pueda instanciar en el lugar
// de un VX_cluster real, bajo `ifdef TFG_USE_CUSTOM_CLUSTER): dcr_bus_if
// (slave), mem_bus_if[TFG_L2_MEM_PORTS] (master), kmu_bus_if[1] (slave),
// busy. Sin los puertos opcionales de VX_cluster.sv (SCOPE_IO, PERF,
// raster, VM) -- este módulo solo soporta la config mínima objetivo del
// TFG (NUM_CLUSTERS==1, NUM_SOCKETS==1, sin gráficos/VM/perf).
//
// A diferencia de compute_unit.sv (A-14, scaffold de test aislado, con su
// propio VX_kmu local e icache mockeada por núcleo en C++), este módulo NO
// tiene VX_kmu propio -- en el sistema real el KMU vive una sola vez,
// arriba de todo (Vortex.sv), y reparte a cada cluster un kmu_bus_if ya
// arbitrado. compute_unit.sv NO es un wrapper de este módulo -- desde que
// este módulo ganó icache real (ver más abajo) ya no comparten el mismo
// contrato externo (compute_unit.sv sigue exponiendo icache_bus_if por
// núcleo; acá la icache quedó interna). Son dos artefactos independientes
// a propósito: compute_unit.sv sigue siendo la prueba de regresión de
// L1+L2+snoop_bus (A-14/A-17); este módulo es la pieza de integración real.
//
// icache: a diferencia de los testbenches aislados de A-9/A-14 (icache
// expuesta como puerto externo, mockeada en C++), acá hace falta la
// icache REAL de Vortex (VX_cache_cluster, sin modificar, mismo módulo
// e instanciación que VX_socket.sv usa) -- l1_cache.sv/l2_cache.sv son
// de datos solamente, nunca sirvieron instrucciones. El tráfico de
// icache y el de dcache/L2 se fusionan en un solo puerto de salida
// (VX_mem_bus_arb, prioridad "P" icache-primero) -- MISMO patrón que
// VX_socket.sv usa para fusionar icache+dcache+unidades socket-resident
// en sus L1_MEM_PORTS (ver VX_socket.sv: "Puerto 0 arbitra icache y
// dcache... prioridad fija icache primero"). Por eso TFG_L1_LINE_SIZE
// default es `VX_CFG_L1_LINE_SIZE (el tamaño de línea REAL, no el 16
// achicado de los testbenches) -- VX_mem_bus_arb exige el mismo
// DATA_SIZE en todas sus entradas, e icache siempre usa ese tamaño real.
`include "VX_define.vh"

module tfg_cluster import VX_gpu_pkg::*; #(
    parameter CLUSTER_ID = 0,
    parameter `STRING INSTANCE_ID = "",

    parameter NUM_BANKS = 4,
    // Debe calzar con L2_MEM_PORTS real de la config objetivo (ver
    // VX_gpu_pkg.sv: con L2_ENABLE=false, L2_MEM_PORTS =
    // min(L2_NUM_REQS, PLATFORM_MEMORY_NUM_BANKS); con NUM_SOCKETS=1 y
    // L1_MEM_PORTS=1 -- que YA asume icache+dcache fusionados en un
    // solo puerto, igual que hace este módulo -- da 1).
    // Nombre TFG_-prefijado (no L2_MEM_PORTS) a propósito: VX_gpu_pkg.sv
    // ya declara su propio localparam package-level L2_MEM_PORTS, y este
    // módulo hace `import VX_gpu_pkg::*` -- un parámetro propio con el
    // mismo nombre lo tapa silenciosamente (VARHIDDEN).
    parameter TFG_L2_MEM_PORTS = 1,

    parameter TFG_L1_LINE_SIZE     = `VX_CFG_L1_LINE_SIZE,
    parameter TFG_L1_MEM_TAG_WIDTH = 8,
    // Relativo a LINE_SIZE (no una constante fija): garantiza NUM_SETS
    // >= 4 en l2_cache.sv sin importar qué tan grande sea
    // TFG_L1_LINE_SIZE (encontrado en A-14: con LINE_SIZE=16 y un
    // BANK_SIZE fijo de 32, NUM_SETS colapsaba a 1 -- ancho negativo).
    parameter TFG_L2_BANK_SIZE     = TFG_L1_LINE_SIZE * 2 * 4,
    parameter TFG_L2_NUM_WAYS      = 2,
    parameter TFG_L2_MEM_TAG_WIDTH = 8,

    parameter TFG_L1_MEM_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(TFG_L1_LINE_SIZE)
) (
    input wire clk,
    input wire reset,

    VX_dcr_bus_if.slave  dcr_bus_if,
    VX_mem_bus_if.master mem_bus_if [TFG_L2_MEM_PORTS],
    VX_kmu_bus_if.slave  kmu_bus_if [1],

    output wire busy
);
    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM (CLUSTER_ID)
    `STATIC_ASSERT (TFG_L2_MEM_PORTS == 1,
        ("tfg_cluster: solo soporta TFG_L2_MEM_PORTS==1 (icache+L2 ya se fusionan en un solo puerto adentro)"))
    // A diferencia de VX_cluster.sv (que genera NUM_SOCKETS x VX_socket,
    // cada uno con SOCKET_SIZE núcleos), este módulo no replica la
    // jerarquía de sockets -- genera los núcleos del cluster en un solo
    // nivel plano. Válido solo cuando el cluster tiene un único socket
    // (si no, VX_socket.sv generaría L1_MEM_PORTS por socket y la fusión
    // icache+L2 de más abajo, pensada para UN solo puerto fusionado,
    // dejaría de calzar con el L2_MEM_PORTS real del sistema). NUM_CORES
    // se deriva de SOCKET_SIZE (no es un parámetro propio) para que no
    // pueda quedar desacoplado de VX_CFG_NUM_CORES/VX_CFG_SOCKET_SIZE --
    // Vortex.sv no le pasa un NUM_CORES explícito al instanciar (igual
    // que VX_cluster.sv tampoco lo recibe).
    `STATIC_ASSERT (NUM_SOCKETS == 1,
        ("tfg_cluster: solo soporta NUM_SOCKETS==1 (VX_CFG_NUM_CORES/VX_CFG_SOCKET_SIZE debe dar 1)"))
    localparam NUM_CORES = `VX_CFG_SOCKET_SIZE;

    // ------------------------------------------------------------------
    // Fan-out de CTAs y de DCR: el kmu_bus_if/dcr_bus_if que entran de
    // afuera ya vienen arbitrados UNA vez (Vortex.sv, entre clusters) --
    // acá se reparten una SEGUNDA vez, entre los NUM_CORES núcleos de
    // este cluster. Mismos módulos reales que VX_socket.sv usa para lo
    // mismo entre sus propios núcleos.
    // ------------------------------------------------------------------
    VX_kmu_bus_if per_core_kmu_bus_if [NUM_CORES] ();

    VX_kmu_bus_arb #(
        .NUM_INPUTS  (1),
        .NUM_OUTPUTS (NUM_CORES),
        .DEST_LSB    (0)
    ) kmu_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (kmu_bus_if),
        .bus_out_if (per_core_kmu_bus_if)
    );

    VX_dcr_bus_if per_core_dcr_bus_if [NUM_CORES] ();

    VX_dcr_arb #(
        .NUM_REQS (NUM_CORES)
    ) dcr_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (dcr_bus_if),
        .bus_out_if (per_core_dcr_bus_if)
    );

    // ------------------------------------------------------------------
    // icache REAL (VX_cache_cluster, sin modificar) -- compartida entre
    // los NUM_CORES núcleos, mismo patrón/parámetros que VX_socket.sv.
    // ------------------------------------------------------------------
    VX_mem_bus_if #(
        .DATA_SIZE (ICACHE_WORD_SIZE),
        .TAG_WIDTH (ICACHE_TAG_WIDTH)
    ) icache_bus_if [NUM_CORES] ();

    VX_mem_bus_if #(
        .DATA_SIZE (ICACHE_LINE_SIZE),
        .TAG_WIDTH (ICACHE_MEM_TAG_WIDTH)
    ) icache_mem_bus_if [1] ();

    VX_cache_cluster #(
        .INSTANCE_ID    (`SFORMATF(("%s-icache", INSTANCE_ID))),
        .NUM_UNITS      (`VX_CFG_NUM_ICACHES),
        .NUM_INPUTS     (NUM_CORES),
        .TAG_SEL_IDX    (0),
        .CACHE_SIZE     (`VX_CFG_ICACHE_SIZE),
        .LINE_SIZE      (ICACHE_LINE_SIZE),
        .NUM_BANKS      (1),
        .NUM_WAYS       (`VX_CFG_ICACHE_NUM_WAYS),
        .WORD_SIZE      (ICACHE_WORD_SIZE),
        .NUM_REQS       (1),
        .MEM_PORTS      (1),
        .CRSQ_SIZE      (`VX_CFG_ICACHE_CRSQ_SIZE),
        .MSHR_SIZE      (`VX_CFG_ICACHE_MSHR_SIZE),
        .MRSQ_SIZE      (`VX_CFG_ICACHE_MRSQ_SIZE),
        .MREQ_SIZE      (`VX_CFG_ICACHE_MREQ_SIZE),
        .LATENCY        (`VX_CFG_ICACHE_LATENCY),
        .TAG_WIDTH      (ICACHE_TAG_WIDTH),
        .WRITE_ENABLE   (0),
        .REPL_POLICY    (`VX_CFG_ICACHE_REPL_POLICY),
        .NC_ENABLE      (0),
        .CORE_OUT_BUF   (3),
        .MEM_OUT_BUF    (3)
    ) icache (
        .clk            (clk),
        .reset          (reset),
        .core_bus_if    (icache_bus_if),
        .mem_bus_if     (icache_mem_bus_if)
    );

    // ------------------------------------------------------------------
    // Snoop bus: conecta las NUM_CORES l1_cache.sv entre sí (A-7/A-8).
    // req_if[i]: la consulta PROPIA de l1_cache[i] (su modport .master,
    // l1_cache.snoop_mst_if) -- el bus la RECIBE (modport .snooper).
    // rsp_if[i]: el broadcast del bus HACIA l1_cache[i] (su modport
    // .snooper, l1_cache.snoop_bus_if) -- el bus lo EMITE (modport
    // .master). Ver el comentario de cabecera de snoop_bus.sv.
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // L2 compartida (datos): un core_bus_if por L1.
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
        .INSTANCE_ID    (`SFORMATF(("%s-l2", INSTANCE_ID))),
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

    // Árbitro global de L2 (VX_mem_bus_arb, real, SIN modificar) --
    // fusiona los NUM_BANKS puertos de L2 en uno solo. Tag ensanchado en
    // $clog2(NUM_BANKS) bits (VX_bits_insert/VX_bits_remove adentro).
    localparam L2_ARB_TAG_WIDTH = TFG_L2_MEM_TAG_WIDTH + `CLOG2(NUM_BANKS);

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (L2_ARB_TAG_WIDTH)
    ) l2_merged_if [1] ();

    VX_mem_bus_arb #(
        .NUM_INPUTS  (NUM_BANKS),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (TFG_L1_LINE_SIZE),
        .TAG_WIDTH   (TFG_L2_MEM_TAG_WIDTH),
        .TAG_SEL_IDX (0),
        .ARBITER     ("R")
    ) l2_global_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (l2_bank_bus_if),
        .bus_out_if (l2_merged_if)
    );

    // ------------------------------------------------------------------
    // Fusión final icache + L2: mismo patrón que VX_socket.sv usa para
    // icache+dcache ("Puerto 0 arbitra... prioridad fija icache
    // primero"). TFG_MEM_TAG_WIDTH ensancha al MAX de los dos tags de
    // entrada (igual criterio que SOCKET_MEM_TAG_WIDTH en VX_gpu_pkg.sv)
    // antes del `+1` final del propio árbitro 2->1.
    // ------------------------------------------------------------------
    localparam TFG_MEM_TAG_WIDTH = `MAX(ICACHE_MEM_TAG_WIDTH, L2_ARB_TAG_WIDTH);

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (TFG_MEM_TAG_WIDTH)
    ) final_arb_in_if [2] ();

    `ASSIGN_VX_MEM_BUS_IF_EX (final_arb_in_if[0], icache_mem_bus_if[0], TFG_MEM_TAG_WIDTH, ICACHE_MEM_TAG_WIDTH, UUID_WIDTH);
    `ASSIGN_VX_MEM_BUS_IF_EX (final_arb_in_if[1], l2_merged_if[0],      TFG_MEM_TAG_WIDTH, L2_ARB_TAG_WIDTH,    UUID_WIDTH);

    // VX_bits_insert (adentro de VX_mem_bus_arb) produce un data_out de
    // N+S bits, no N -- el output REAL de un árbitro ensanchador queda en
    // TAG_WIDTH + CLOG2(NUM_INPUTS), igual que ya se hizo arriba para
    // l2_global_arb (L2_ARB_TAG_WIDTH). Declarar el destino a TFG_MEM_TAG_WIDTH
    // en vez de este valor ensanchado truncaba el bit selector en el
    // camino de respuesta -- encontrado por un timeout real de
    // VX_scoreboard.sv en la Fase B (no por lint: con solo 2 entradas el
    // ancho declarado por error todavía "entraba", silencioso).
    localparam FINAL_ARB_TAG_WIDTH = TFG_MEM_TAG_WIDTH + `CLOG2(2);

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (FINAL_ARB_TAG_WIDTH)
    ) final_arb_out_if [1] ();

    VX_mem_bus_arb #(
        .NUM_INPUTS  (2),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (TFG_L1_LINE_SIZE),
        .TAG_WIDTH   (TFG_MEM_TAG_WIDTH),
        .TAG_SEL_IDX (0),
        .ARBITER     ("P")  // icache primero, igual que VX_socket.sv
    ) final_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (final_arb_in_if),
        .bus_out_if (final_arb_out_if)
    );

    // El puerto externo mem_bus_if está atado a lo que el caller real
    // (Vortex.sv: per_cluster_mem_bus_if, TAG_WIDTH(L3_TAG_WIDTH)) haya
    // declarado -- casi nunca va a coincidir con TFG_MEM_TAG_WIDTH (el
    // esquema de tags es puramente interno a este módulo, sin relación
    // con el ancho que el sistema real reserva en L3_TAG_WIDTH para su
    // propio fan-in global). Conectar final_arb directo al puerto externo
    // dejaba que Verilator truncara/extendiera implícitamente el tag en
    // el camino de respuesta -- silencioso, y corrompía el bit que
    // identifica a qué pedido pertenece cada respuesta (encontrado por
    // un timeout real de VX_scoreboard.sv en la Fase B, no por lint).
    // L3_TAG_WIDTH es un localparam package-level (VX_gpu_pkg), así que
    // es el mismo valor en todo el sistema real -- no depende del
    // caller puntual, se puede referenciar acá directo.
    `ASSIGN_VX_MEM_BUS_IF_EX (mem_bus_if[0], final_arb_out_if[0], L3_TAG_WIDTH, FINAL_ARB_TAG_WIDTH, UUID_WIDTH);

    // ------------------------------------------------------------------
    // NUM_CORES x (VX_core + l1_cache splice) -- mismo patrón de A-9/A-14.
    // ------------------------------------------------------------------
    VX_gbar_bus_if gbar_bus_if [NUM_CORES] ();

    wire [NUM_CORES-1:0] per_core_busy;
    wire [NUM_CORES-1:0] per_core_kmu_valid;

    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_core

        // gbar: tie-off (sin barreras globales en este alcance, igual que A-9/A-14).
        assign gbar_bus_if[i].req_ready   = 1'b1;
        assign gbar_bus_if[i].rsp_valid   = 1'b0;
        assign gbar_bus_if[i].rsp_data.id = '0;

        if (DCACHE_NUM_REQS != 1) begin : g_check_num_reqs
            initial $fatal(1, "tfg_cluster: l1_cache.sv splice necesita DCACHE_NUM_REQS==1 (dio %0d)", DCACHE_NUM_REQS);
        end

        VX_mem_bus_if #(
            .DATA_SIZE (DCACHE_WORD_SIZE),
            .TAG_WIDTH (DCACHE_TAG_WIDTH)
        ) dcache_bus_if [DCACHE_NUM_REQS] ();

        l1_cache #(
            .INSTANCE_ID    (`SFORMATF(("%s-l1%0d", INSTANCE_ID, i))),
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
            .snoop_mst_if (l1_own_query_if[i])
        );

        VX_core #(
            .INSTANCE_ID (`SFORMATF(("%s-core%0d", INSTANCE_ID, i))),
            .CORE_ID     (i)
        ) core (
            .clk            (clk),
            .reset          (reset),
            .dcr_bus_if     (per_core_dcr_bus_if[i]),
            .dcache_bus_if  (dcache_bus_if),
            .icache_bus_if  (icache_bus_if[i]),
            .kmu_bus_if     (per_core_kmu_bus_if[i]),
            .gbar_bus_if    (gbar_bus_if[i]),
            .busy           (per_core_busy[i])
        );

        assign per_core_kmu_valid[i] = per_core_kmu_bus_if[i].valid;

    end

    // ------------------------------------------------------------------
    // busy: mismo patrón que VX_cluster.sv (ver VX_cluster.sv:492-510) --
    // un OR crudo de per_core_busy se comería un ciclo de latencia (el
    // write de DCR, o un launch todavía resident en el skid del
    // kmu_arb, antes de que cualquier núcleo lo vea) y el host podría
    // pensar que ya terminó cuando en realidad el trabajo recién está
    // por llegar. launch_link_busy cubre exactamente eso.
    // ------------------------------------------------------------------
    wire launch_link_busy = kmu_bus_if[0].valid | (|per_core_kmu_valid);

    wire busy_r;
    `BUFFER_EX(busy_r, dcr_bus_if.req_valid | (|per_core_busy), 1'b1, 1, (NUM_CORES > 1));
    assign busy = busy_r | dcr_bus_if.req_valid | launch_link_busy;

endmodule
