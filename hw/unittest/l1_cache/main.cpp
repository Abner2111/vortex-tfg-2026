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
// TFG: prueba en aislamiento de l1_cache.sv (A-5, último punto: "compilar
// y simular en aislamiento con estímulos básicos"). Ejercita el datapath
// completo: write-miss -> fill (write-allocate) -> read-hit, emulando una
// L2 del lado de mem_bus_if a mano (acepta cualquier miss y responde un
// ciclo después). snoop_bus_if no se ejercita todavía (coherencia queda
// para cuando haya más de un L1).

#include "vl_simulator.h"
#include "VVX_l1_cache_top.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  vl_simulator<VVX_l1_cache_top> sim;
  uint64_t ticks = 0;
  ticks = sim.reset(ticks);

  sim->core_rsp_ready = 1;
  sim->mem_req_ready  = 0;
  sim->mem_rsp_valid  = 0;

  const uint32_t kAddr    = 0;
  const uint32_t kWrData  = 0xCAFEBABE;
  const uint32_t kByteen  = 0xF;
  const uint32_t kCoreTag = 5;

  // ---- 1) write-miss: debe pasar por mem_bus_if (fill) antes de responder ----
  sim->core_req_valid  = 1;
  sim->core_req_rw     = 1;
  sim->core_req_addr   = kAddr;
  sim->core_req_data   = kWrData;
  sim->core_req_byteen = kByteen;
  sim->core_req_tag    = kCoreTag;

  bool req_sent = false, mem_seen = false, rsp_fired = false;
  bool got_rsp = false;
  uint32_t rsp_data = 0, rsp_tag = 0;
  int cycles_since_mem_req = -1;

  // Emula una L2 simple: en cuanto ve mem_req_valid deja mem_req_ready en
  // alto para siempre (no hace falta bajarlo — el propio l1_cache deja de
  // pedir en cuanto lo acepta) y responde un ciclo después con la línea.
  // No se intenta detectar el hand-off exacto leyendo mem_req_valid
  // post-flanco: para cuando se lee, la FSM ya reaccionó a la aceptación
  // y el valid ya bajó, así que "ya lo vi" + "un ciclo después" alcanza.
  for (int i = 0; i < 20 && !got_rsp; ++i) {
    ticks = sim.step(ticks, 2);

    if (sim->core_req_ready && !req_sent) {
      req_sent = true;
      sim->core_req_valid = 0;
    }

    if (sim->mem_req_valid && !mem_seen) {
      mem_seen = true;
      sim->mem_req_ready = 1;
    }

    if (mem_seen && !rsp_fired) {
      if (cycles_since_mem_req < 0) {
        cycles_since_mem_req = 0;
      } else {
        sim->mem_rsp_valid = 1;
        sim->mem_rsp_data  = 0;  // "memoria" arranca en 0; el write-allocate mezcla kWrData encima
        sim->mem_rsp_tag   = 0;
        rsp_fired = true;
      }
    } else if (rsp_fired && sim->mem_rsp_valid) {
      sim->mem_rsp_valid = 0;  // un solo ciclo de respuesta alcanza
    }

    if (sim->core_rsp_valid) {
      got_rsp  = true;
      rsp_data = sim->core_rsp_data;
      rsp_tag  = sim->core_rsp_tag;
    }
  }

  if (!mem_seen || !got_rsp || rsp_tag != kCoreTag) {
    std::printf("write-miss: FAIL mem_seen=%d got_rsp=%d rsp_tag=%u (esperado %u)\n",
                mem_seen, got_rsp, rsp_tag, kCoreTag);
    return 1;
  }
  std::printf("write-miss: ok (mem_bus_if.req visto, core respondió, tag=%u)\n", rsp_tag);

  // ---- 2) read-hit sobre la misma dirección: debe traer kWrData de vuelta ----
  ticks = sim.step(ticks, 2);  // 1 ciclo de aire entre transacciones

  sim->core_req_valid  = 1;
  sim->core_req_rw     = 0;
  sim->core_req_addr   = kAddr;
  sim->core_req_byteen = kByteen;
  sim->core_req_tag    = kCoreTag + 1;

  req_sent = false;
  got_rsp  = false;
  for (int i = 0; i < 10 && !got_rsp; ++i) {
    ticks = sim.step(ticks, 2);
    if (sim->core_req_ready && !req_sent) {
      req_sent = true;
      sim->core_req_valid = 0;
    }
    if (sim->core_rsp_valid) {
      got_rsp  = true;
      rsp_data = sim->core_rsp_data;
    }
  }

  if (!got_rsp || rsp_data != kWrData) {
    std::printf("read-hit: FAIL, esperado 0x%08X, obtenido 0x%08X\n", kWrData, rsp_data);
    return 1;
  }
  std::printf("read-hit: ok, 0x%08X == 0x%08X\n", rsp_data, kWrData);

  std::printf("l1_cache isolation test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
