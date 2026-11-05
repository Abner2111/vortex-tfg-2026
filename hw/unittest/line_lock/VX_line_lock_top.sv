// Wrapper de puertos planos para Verilator (las interfaces SV no cruzan
// limpio el límite C++/DPI) -- mismo patrón que
// hw/unittest/snoop_bus/VX_snoop_bus_top.sv. 4 núcleos fijos, puertos
// numerados en vez de arrays empaquetados (más simple de indexar desde
// main.cpp).

module VX_line_lock_top #(
    parameter ADDR_WIDTH = 8
) (
    input wire clk,
    input wire reset,

    input  wire                   req_valid0, req_valid1, req_valid2, req_valid3,
    input  wire [ADDR_WIDTH-1:0]  req_addr0,  req_addr1,  req_addr2,  req_addr3,
    output wire                   req_ready0, req_ready1, req_ready2, req_ready3,
    input  wire                   rel_valid0, rel_valid1, rel_valid2, rel_valid3,

    // Debug (solo test, no sintetizable): req_ready es un pulso
    // combinacional de un solo ciclo (cae apenas el slot queda
    // registrado) -- más fácil de verificar desde C++ con un tap
    // registrado y estable a "¿tengo el candado AHORA?".
    output wire dbg_slot_valid0, dbg_slot_valid1, dbg_slot_valid2, dbg_slot_valid3
);
    localparam NUM_L1 = 4;

    VX_line_lock_if #(.ADDR_WIDTH(ADDR_WIDTH)) lock_if [NUM_L1] ();

    assign lock_if[0].req_valid = req_valid0;
    assign lock_if[1].req_valid = req_valid1;
    assign lock_if[2].req_valid = req_valid2;
    assign lock_if[3].req_valid = req_valid3;

    assign lock_if[0].req_addr = req_addr0;
    assign lock_if[1].req_addr = req_addr1;
    assign lock_if[2].req_addr = req_addr2;
    assign lock_if[3].req_addr = req_addr3;

    assign req_ready0 = lock_if[0].req_ready;
    assign req_ready1 = lock_if[1].req_ready;
    assign req_ready2 = lock_if[2].req_ready;
    assign req_ready3 = lock_if[3].req_ready;

    assign lock_if[0].rel_valid = rel_valid0;
    assign lock_if[1].rel_valid = rel_valid1;
    assign lock_if[2].rel_valid = rel_valid2;
    assign lock_if[3].rel_valid = rel_valid3;

    line_lock #(
        .NUM_L1     (NUM_L1),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) dut (
        .clk    (clk),
        .reset  (reset),
        .req_if (lock_if)
    );

    assign dbg_slot_valid0 = dut.slot_valid[0];
    assign dbg_slot_valid1 = dut.slot_valid[1];
    assign dbg_slot_valid2 = dut.slot_valid[2];
    assign dbg_slot_valid3 = dut.slot_valid[3];

endmodule
