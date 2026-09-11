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
// TFG: pruebas en aislamiento para l1_cache.sv (A-5, último punto:
// "compilar y simular en aislamiento con estímulos básicos"). Mientras
// l1_cache.sv sea placeholder (TODOs, req_ready fijo en 0), este test solo
// prueba que el módulo elabora y corre en Verilator sin errores. A medida
// que se implementen tag array / hit-miss / stall / write-back, reemplazar
// los TODO de abajo por asserts reales sobre el comportamiento esperado.

#include "vl_simulator.h"
#include "VVX_l1_cache_top.h"
#include <cassert>
#include <cstdio>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  vl_simulator<VVX_l1_cache_top> sim;

  uint64_t ticks = 0;
  ticks = sim.reset(ticks);

  // Estímulo básico #1: una petición de lectura del "pipeline"
  sim->core_req_valid  = 1;
  sim->core_req_rw     = 0;
  sim->core_req_addr   = 0x100;
  sim->core_req_byteen = 0xF;
  sim->core_req_tag    = 0;
  ticks = sim.step(ticks, 4);

  // TODO: una vez implementado el hit/miss real, verificar aquí que un
  // miss en frío genera exactamente una petición hacia mem_bus_if
  // (mem_req_valid == 1) con la dirección de línea correspondiente.
  assert(sim->mem_req_valid == 0 || sim->mem_req_valid == 1);  // placeholder: no revienta con X

  sim->core_req_valid = 0;
  ticks = sim.step(ticks, 4);

  // Estímulo básico #2: una petición de escritura
  sim->core_req_valid  = 1;
  sim->core_req_rw     = 1;
  sim->core_req_addr   = 0x100;
  sim->core_req_data   = 0xDEADBEEF;
  sim->core_req_byteen = 0xF;
  sim->core_req_tag    = 1;
  ticks = sim.step(ticks, 4);

  // TODO: una vez implementado write-back, verificar que una escritura
  // sobre una línea M ya presente NO genera tráfico hacia mem_bus_if
  // (queda dirty en la L1 hasta el reemplazo o el snoop).

  sim->core_req_valid = 0;
  ticks = sim.step(ticks, 4);

  std::printf("l1_cache isolation smoke test: elaborated and ran %lu ticks\n",
              (unsigned long)ticks);
  return 0;
}
