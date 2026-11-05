// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// TFG: line_lock.sv aislado (4 "núcleos" de mentira -- flat req/addr/
// ready/release, sin ningún l1_cache real de por medio). Ver
// hw/rtl/tfg_l1/VX_line_lock_if.sv y line_lock.sv para el porqué --
// encontrado con `sgemm` (reuso real cross-core) perdiendo datos cuando
// dos o más núcleos hacen miss sobre la MISMA línea al mismo tiempo, ver
// docs/proposals/tfg_cluster_baseline_comparison.md.
//
// Se verifica contra dbg_slot_valid* (un tap registrado y estable), no
// contra req_ready -- req_ready es un pulso combinacional de un solo
// ciclo (cae apenas el slot queda registrado), más difícil de atrapar
// desde C++ en el instante exacto que sostener el estado real del slot.

#include "vl_simulator.h"
#include "VVX_line_lock_top.h"
#include <cstdio>

using Sim = vl_simulator<VVX_line_lock_top>;

static void tie_off(Sim &sim) {
  sim->req_valid0 = 0; sim->req_valid1 = 0; sim->req_valid2 = 0; sim->req_valid3 = 0;
  sim->rel_valid0 = 0; sim->rel_valid1 = 0; sim->rel_valid2 = 0; sim->rel_valid3 = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Sim sim;
  uint64_t ticks = 0;
  tie_off(sim);
  ticks = sim.reset(ticks);

  int fails = 0;
  auto check = [&](bool cond, const char *what) {
    if (!cond) { std::printf("FAIL: %s\n", what); ++fails; }
    else       { std::printf("ok: %s\n", what); }
  };

  // ---- Escenario 1: un pedido solo se otorga ya ----
  std::printf("=== core0 pide addr=0xA, sola ===\n");
  sim->req_valid0 = 1;
  sim->req_addr0  = 0xA;
  ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid0 == 1, "core0 se otorga al instante (sin contencion)");
  sim->req_valid0 = 0;

  // ---- Escenario 2: otro nucleo pidiendo la MISMA direccion mientras el
  // primero la tiene queda bloqueado hasta el release ----
  std::printf("=== core1 pide la MISMA addr=0xA mientras core0 la tiene ===\n");
  sim->req_valid1 = 1;
  sim->req_addr1  = 0xA;
  for (int i = 0; i < 5; ++i) ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid1 == 0, "core1 queda bloqueado (core0 todavia tiene addr=0xA)");

  std::printf("=== core0 libera addr=0xA ===\n");
  sim->rel_valid0 = 1;
  ticks = sim.step(ticks, 2);
  sim->rel_valid0 = 0;
  for (int i = 0; i < 5; ++i) ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid0 == 0, "core0 ya no tiene addr=0xA (liberada)");
  check(sim->dbg_slot_valid1 == 1, "core1 se otorga recien despues del release de core0");
  sim->req_valid1 = 0;
  sim->rel_valid1 = 1;
  ticks = sim.step(ticks, 2);
  sim->rel_valid1 = 0;
  ticks = sim.step(ticks, 2);

  // ---- Escenario 3: pedidos simultaneos a la MISMA direccion nueva, el
  // indice mas bajo gana (prioridad fija, mismo criterio que
  // snoop_bus.sv) -- el perdedor queda bloqueado hasta el release del
  // ganador, no solo "un ciclo mas" ----
  std::printf("=== core0 y core2 piden la MISMA addr=0xB EXACTAMENTE el mismo ciclo ===\n");
  sim->req_valid0 = 1; sim->req_addr0 = 0xB;
  sim->req_valid2 = 1; sim->req_addr2 = 0xB;
  ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid0 == 1, "core0 (indice mas bajo) gana el empate");
  check(sim->dbg_slot_valid2 == 0, "core2 pierde el empate, queda esperando");

  for (int i = 0; i < 5; ++i) ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid2 == 0, "core2 sigue bloqueado (core0 todavia tiene addr=0xB)");

  sim->req_valid0 = 0;
  sim->rel_valid0 = 1;
  ticks = sim.step(ticks, 2);
  sim->rel_valid0 = 0;
  for (int i = 0; i < 5; ++i) ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid2 == 1, "core2 se otorga recien despues del release de core0");
  sim->req_valid2 = 0;
  sim->rel_valid2 = 1;
  ticks = sim.step(ticks, 2);
  sim->rel_valid2 = 0;
  ticks = sim.step(ticks, 2);

  // ---- Escenario 4: direcciones DISTINTAS otorgan en paralelo, sin
  // bloquearse entre si ----
  std::printf("=== core0 (addr=0xC) y core1 (addr=0xD), mismo ciclo, direcciones distintas ===\n");
  sim->req_valid0 = 1; sim->req_addr0 = 0xC;
  sim->req_valid1 = 1; sim->req_addr1 = 0xD;
  ticks = sim.step(ticks, 2);
  check(sim->dbg_slot_valid0 == 1, "core0 se otorga (direccion propia, sin conflicto)");
  check(sim->dbg_slot_valid1 == 1, "core1 se otorga en el MISMO ciclo (direccion distinta)");
  sim->req_valid0 = 0; sim->rel_valid0 = 1;
  sim->req_valid1 = 0; sim->rel_valid1 = 1;
  ticks = sim.step(ticks, 2);
  tie_off(sim);

  if (fails) {
    std::printf("line_lock test: FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("line_lock test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
