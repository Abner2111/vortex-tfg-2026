// Baseline de comparación para tfg_cluster.sv: mismo contrato externo
// (dcr_bus_if, mem_bus_if[1], kmu_bus_if[1], busy), mismo icache real
// (VX_cache_cluster, sin modificar), pero el camino de DATOS NO usa
// l1_cache.sv/snoop_bus.sv/l2_cache.sv -- cada núcleo accede memoria
// directo, mergeado por un árbitro round-robin real (VX_mem_bus_arb,
// ARBITER="R", sin modificar), sin ningún nivel de caché ni coherencia.
//
// Propósito: aislar qué le cuesta/aporta la jerarquía L1+L2 MESI real
// de tfg_cluster.sv, corriendo el MISMO kernel a la MISMA config
// (NUM_CORES/WARPS/THREADS/SOCKET_SIZE) con y sin ella -- comparar
// ciclos/IPC entre los dos (`TFG_USE_CUSTOM_CLUSTER` vs
// `TFG_USE_BASELINE_CLUSTER`), no un gate de síntesis.
//
// La única pieza nueva (no existe en tfg_cluster.sv, que acá no hace
// falta) es el adaptador de ancho palabra->línea de abajo -- el
// árbitro final (icache+datos, mismo patrón que VX_socket.sv/
// tfg_cluster.sv) exige el mismo DATA_SIZE en todos sus puertos, e
// icache siempre habla a nivel de línea; sin este adaptador, el
// dcache_bus_if de cada núcleo (nivel palabra) no calzaría. No es una
// caché: no hay tag array, no hay estado retenido entre accesos --
// `word_off_r` es el único registro, y solo alinea la respuesta un
// ciclo después del request (el propio dcache_bus_if admite un solo
// pedido en vuelo a la vez, mismo criterio que l1_cache.sv).
`include "VX_define.vh"

module tfg_cluster_baseline import VX_gpu_pkg::*; #(
    parameter CLUSTER_ID = 0,
    parameter `STRING INSTANCE_ID = "",

    // Ver tfg_cluster.sv: mismo criterio y mismo motivo de nombre
    // TFG_-prefijado (VARHIDDEN contra el L2_MEM_PORTS de VX_gpu_pkg.sv).
    parameter TFG_L2_MEM_PORTS = 1,

    parameter TFG_L1_LINE_SIZE = `VX_CFG_L1_LINE_SIZE
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
        ("tfg_cluster_baseline: solo soporta TFG_L2_MEM_PORTS==1 (icache+datos ya se fusionan en un solo puerto adentro)"))
    `STATIC_ASSERT (NUM_SOCKETS == 1,
        ("tfg_cluster_baseline: solo soporta NUM_SOCKETS==1 (VX_CFG_NUM_CORES/VX_CFG_SOCKET_SIZE debe dar 1)"))
    localparam NUM_CORES = `VX_CFG_SOCKET_SIZE;

    // ------------------------------------------------------------------
    // Fan-out de CTAs y de DCR -- idéntico a tfg_cluster.sv.
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
    // icache REAL -- idéntica a tfg_cluster.sv (no es lo que se está
    // comparando acá, solo el camino de datos).
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
    // Datos: sin caché -- cada núcleo, adaptado a ancho de línea (ver
    // comentario de cabecera), mergeado por un árbitro round-robin real
    // directo a memoria.
    // ------------------------------------------------------------------
    localparam WORDS_PER_LINE      = TFG_L1_LINE_SIZE / DCACHE_WORD_SIZE;
    localparam OFFSET_BITS         = `CLOG2(WORDS_PER_LINE);
    localparam LINE_BITS           = TFG_L1_LINE_SIZE * 8;
    localparam WORD_BITS           = DCACHE_WORD_SIZE * 8;
    // Mismo valor que el DCACHE_ADDR_WIDTH de VX_gpu_pkg.sv (import
    // VX_gpu_pkg::*) -- prefijo TFG_ para no tapar ese nombre
    // (VARHIDDEN, mismo motivo que TFG_L2_MEM_PORTS en tfg_cluster.sv).
    localparam TFG_DCACHE_ADDR_WIDTH = `VX_CFG_MEM_ADDR_WIDTH - `CLOG2(DCACHE_WORD_SIZE);
    localparam DCACHE_ARB_TAG_WIDTH = DCACHE_TAG_WIDTH + `CLOG2(NUM_CORES);

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (DCACHE_TAG_WIDTH)
    ) wide_dcache_bus_if [NUM_CORES] ();

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (DCACHE_ARB_TAG_WIDTH)
    ) dcache_merged_if [1] ();

    VX_mem_bus_arb #(
        .NUM_INPUTS  (NUM_CORES),
        .NUM_OUTPUTS (1),
        .DATA_SIZE   (TFG_L1_LINE_SIZE),
        .TAG_WIDTH   (DCACHE_TAG_WIDTH),
        .TAG_SEL_IDX (0),
        .ARBITER     ("R")
    ) dcache_rr_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (wide_dcache_bus_if),
        .bus_out_if (dcache_merged_if)
    );

    // ------------------------------------------------------------------
    // Fusión final icache + datos -- mismo patrón que tfg_cluster.sv
    // (icache primero, prioridad fija).
    // ------------------------------------------------------------------
    localparam TFG_MEM_TAG_WIDTH = `MAX(ICACHE_MEM_TAG_WIDTH, DCACHE_ARB_TAG_WIDTH);

    VX_mem_bus_if #(
        .DATA_SIZE (TFG_L1_LINE_SIZE),
        .TAG_WIDTH (TFG_MEM_TAG_WIDTH)
    ) final_arb_in_if [2] ();

    `ASSIGN_VX_MEM_BUS_IF_EX (final_arb_in_if[0], icache_mem_bus_if[0], TFG_MEM_TAG_WIDTH, ICACHE_MEM_TAG_WIDTH, UUID_WIDTH);
    `ASSIGN_VX_MEM_BUS_IF_EX (final_arb_in_if[1], dcache_merged_if[0],  TFG_MEM_TAG_WIDTH, DCACHE_ARB_TAG_WIDTH, UUID_WIDTH);

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
        .ARBITER     ("P")  // icache primero, igual que tfg_cluster.sv/VX_socket.sv
    ) final_arb (
        .clk        (clk),
        .reset      (reset),
        .bus_in_if  (final_arb_in_if),
        .bus_out_if (final_arb_out_if)
    );

    // Ver tfg_cluster.sv para el motivo exacto de este ensanchado final
    // (L3_TAG_WIDTH real, no TFG_MEM_TAG_WIDTH -- encontrado por un
    // timeout real de VX_scoreboard.sv en Fase B).
    `ASSIGN_VX_MEM_BUS_IF_EX (mem_bus_if[0], final_arb_out_if[0], L3_TAG_WIDTH, FINAL_ARB_TAG_WIDTH, UUID_WIDTH);

    // ------------------------------------------------------------------
    // NUM_CORES x (VX_core + adaptador de ancho, sin caché).
    // ------------------------------------------------------------------
    VX_gbar_bus_if gbar_bus_if [NUM_CORES] ();

    wire [NUM_CORES-1:0] per_core_busy;
    wire [NUM_CORES-1:0] per_core_kmu_valid;

    for (genvar i = 0; i < NUM_CORES; ++i) begin : g_core

        assign gbar_bus_if[i].req_ready   = 1'b1;
        assign gbar_bus_if[i].rsp_valid   = 1'b0;
        assign gbar_bus_if[i].rsp_data.id = '0;

        if (DCACHE_NUM_REQS != 1) begin : g_check_num_reqs
            initial $fatal(1, "tfg_cluster_baseline: el adaptador necesita DCACHE_NUM_REQS==1 (dio %0d)", DCACHE_NUM_REQS);
        end

        VX_mem_bus_if #(
            .DATA_SIZE (DCACHE_WORD_SIZE),
            .TAG_WIDTH (DCACHE_TAG_WIDTH)
        ) dcache_bus_if [DCACHE_NUM_REQS] ();

        // Adaptador palabra->línea (ver comentario de cabecera): sin
        // tag array de coherencia, pero SÍ hace falta recordar
        // `word_off` por tag (no un solo registro) -- sin l1_cache.sv
        // de por medio reteniendo al core (core_bus_if.req_ready=
        // state==S_IDLE hasta que la transacción completa entera), acá
        // el árbitro/memoria real puede aceptar un pedido NUEVO antes
        // de que la respuesta del anterior llegue (pipelining real,
        // mismo criterio que l2_cache.sv ya usa contra memoria real) --
        // un solo registro se pisaría con el offset del pedido
        // siguiente antes de que la respuesta del primero lo necesite.
        wire [OFFSET_BITS-1:0] word_off = dcache_bus_if[0].req_data.addr[OFFSET_BITS-1:0];
        logic [OFFSET_BITS-1:0] word_off_table [2**DCACHE_TAG_WIDTH];

        always_ff @(posedge clk) begin
            if (dcache_bus_if[0].req_valid && dcache_bus_if[0].req_ready)
                word_off_table[dcache_bus_if[0].req_data.tag] <= word_off;
        end

        wire [OFFSET_BITS-1:0] rsp_word_off = word_off_table[wide_dcache_bus_if[i].rsp_data.tag];

        // data/byteen: colocar la palabra angosta en su posición dentro
        // de la línea ancha vía índice de part-select (`+:`), NO un
        // shift (`<<`) de una cantidad variable -- mismo idioma que
        // l1_cache.sv's merge_word ya usa para esto exacto (multiplicar
        // un índice angosto por una constante como shift amount es un
        // footgun clásico de ancho en Verilog; como índice de
        // part-select, en cambio, el ancho del resultado lo fija el
        // propio `+:`, sin ambigüedad).
        logic [LINE_BITS-1:0]         req_data_wide;
        logic [TFG_L1_LINE_SIZE-1:0]  req_byteen_wide;
        always_comb begin
            req_data_wide   = '0;
            req_byteen_wide = '0;
            req_data_wide[word_off*WORD_BITS +: WORD_BITS]                  = dcache_bus_if[0].req_data.data;
            req_byteen_wide[word_off*DCACHE_WORD_SIZE +: DCACHE_WORD_SIZE]  = dcache_bus_if[0].req_data.byteen;
        end

        assign wide_dcache_bus_if[i].req_valid       = dcache_bus_if[0].req_valid;
        assign dcache_bus_if[0].req_ready            = wide_dcache_bus_if[i].req_ready;
        assign wide_dcache_bus_if[i].req_data.rw     = dcache_bus_if[0].req_data.rw;
        assign wide_dcache_bus_if[i].req_data.addr   = dcache_bus_if[0].req_data.addr[TFG_DCACHE_ADDR_WIDTH-1:OFFSET_BITS];
        assign wide_dcache_bus_if[i].req_data.tag    = dcache_bus_if[0].req_data.tag;
        assign wide_dcache_bus_if[i].req_data.attr   = dcache_bus_if[0].req_data.attr;
        assign wide_dcache_bus_if[i].req_data.data   = req_data_wide;
        assign wide_dcache_bus_if[i].req_data.byteen = req_byteen_wide;

        assign dcache_bus_if[0].rsp_valid       = wide_dcache_bus_if[i].rsp_valid;
        assign wide_dcache_bus_if[i].rsp_ready  = dcache_bus_if[0].rsp_ready;
        assign dcache_bus_if[0].rsp_data.tag    = wide_dcache_bus_if[i].rsp_data.tag;
        assign dcache_bus_if[0].rsp_data.data   = wide_dcache_bus_if[i].rsp_data.data[rsp_word_off*WORD_BITS +: WORD_BITS];

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
    // busy -- idéntico criterio a tfg_cluster.sv (ver ahí el motivo de
    // launch_link_busy).
    // ------------------------------------------------------------------
    wire launch_link_busy = kmu_bus_if[0].valid | (|per_core_kmu_valid);

    wire busy_r;
    `BUFFER_EX(busy_r, dcr_bus_if.req_valid | (|per_core_busy), 1'b1, 1, (NUM_CORES > 1));
    assign busy = busy_r | dcr_bus_if.req_valid | launch_link_busy;

endmodule
