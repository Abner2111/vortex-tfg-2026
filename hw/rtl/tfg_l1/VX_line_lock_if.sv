// TFG: candado por línea entre los NUM_L1 l1_cache.sv de un mismo cluster.
//
// Sin esto, nada impide que dos núcleos decidan "voy a buscar esta línea"
// al mismo tiempo: cada uno consulta el snoop bus (que SÍ serializa bien
// la consulta en sí), ve "nadie la tiene todavía" (verdad en ese instante,
// el fill del otro puede tardar muchos ciclos más en confirmar en su
// tag_array) y arranca su propio fetch independiente -- cada uno termina
// creyéndose dueño exclusivo con solo su propia palabra escrita, el resto
// todavía poison. Ver docs/proposals/tfg_mesi_coherence_design.md §9 y
// hw/rtl/tfg_l1/line_lock.sv.
//
// Protocolo (sin dato, sin respuesta -- más simple que VX_snoop_bus_if.sv):
// un l1_cache.sv pide el candado de una línea ANTES de consultar el snoop
// bus (req_valid/req_addr/req_ready); lo libera (rel_valid, un pulso) recién
// cuando su propio fill ya confirmó en su tag_array. Solo el camino de
// MISS pasa por acá -- un upgrade S->M sobre una línea que el propio
// núcleo ya tiene no vuelve a traer datos de memoria, no puede perder nada
// por esta carrera (ver l1_cache.sv, S_MISS_LOCK).
interface VX_line_lock_if #(
    parameter ADDR_WIDTH = 32
) ();

    logic                  req_valid;
    logic [ADDR_WIDTH-1:0] req_addr;
    logic                  req_ready;
    logic                  rel_valid;

    modport master (
        output req_valid,
        output req_addr,
        input  req_ready,
        output rel_valid
    );

    modport slave (
        input  req_valid,
        input  req_addr,
        output req_ready,
        input  rel_valid
    );

endinterface
