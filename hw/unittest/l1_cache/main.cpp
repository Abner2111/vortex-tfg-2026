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
// completo, incluyendo write-back: con NUM_WAYS=2 en este testbench,
// escribir 3 direcciones que caen en el mismo set fuerza un desalojo de
// una línea dirty en la tercera. Un modelo de "memoria" persistente del
// lado de mem_bus_if (unordered_map) permite confirmar que el dato
// desalojado sobrevive: releerlo después trae lo escrito, no basura.
// snoop_bus_if no se ejercita todavía (coherencia queda para cuando haya
// más de un L1).

#include "vl_simulator.h"
#include "VVX_l1_cache_top.h"
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

using Sim = vl_simulator<VVX_l1_cache_top>;

// Corre hasta max_cycles ciclos: acepta cualquier petición hacia
// mem_bus_if contra `mem` (persistente entre llamadas, así que un
// write-back en una llamada lo ve la siguiente como un read-hit de
// "memoria"), y termina en cuanto el core recibe una respuesta.
static bool run_txn(Sim &sim, uint64_t &ticks, std::unordered_map<uint32_t, uint64_t> &mem,
                     uint32_t &out_data, uint32_t &out_tag, const char *label,
                     int max_cycles = 30) {
  enum { WAIT_REQ, DELAY, RESPONDING } mem_state = WAIT_REQ;
  uint32_t cap_addr = 0, cap_wdata = 0;
  bool cap_rw = false;
  bool got_rsp = false;

  // core_req_valid se deja en alto (puesto por do_write/do_read) durante
  // toda la transacción y solo lo baja el caller al final.
  //
  // Orden crítico de cada vuelta: decidir las entradas del lado mem_bus_if
  // ANTES de llamar a step(), usando el valor de mem_req_valid tal como
  // está en este momento (estable, sin haber avanzado el reloj todavía) —
  // así la decisión usa exactamente lo que el próximo flanco va a ver, sin
  // carrera. Al revés (leer después de step()) se pierde: si mem_req_ready
  // ya estaba en 1, el propio flanco que trae la petición nueva la acepta
  // sola, y para cuando este driver lee el resultado ya desapareció de
  // mem_req_valid sin haber sido capturada.
  std::printf("=== %s ===\n", label);
  for (int i = 0; i < max_cycles && !got_rsp; ++i) {
    switch (mem_state) {
      case WAIT_REQ:
        sim->mem_req_ready = 1;
        if (sim->mem_req_valid) {
          cap_addr  = sim->mem_req_addr;
          cap_rw    = sim->mem_req_rw;
          cap_wdata = sim->mem_req_data;
          mem_state = DELAY;
        }
        break;
      case DELAY: {
        sim->mem_req_ready = 0;
        if (cap_rw) mem[cap_addr] = cap_wdata;  // write-back: persiste
        auto it = mem.find(cap_addr);
        sim->mem_rsp_valid = 1;
        sim->mem_rsp_data  = (it != mem.end()) ? it->second : 0;
        sim->mem_rsp_tag   = 0;
        mem_state = RESPONDING;
        break;
      }
      case RESPONDING:
        sim->mem_rsp_valid = 0;
        mem_state = WAIT_REQ;
        break;
    }

    ticks = sim.step(ticks, 2);

    if (sim->core_rsp_valid) {
      got_rsp  = true;
      out_data = sim->core_rsp_data;
      out_tag  = sim->core_rsp_tag;
    }
  }
  sim->mem_rsp_valid = 0;  // no dejar colgado un pulso a medio disparar entre llamadas
  return got_rsp;
}

static bool do_write(Sim &sim, uint64_t &ticks, std::unordered_map<uint32_t, uint64_t> &mem,
                      uint32_t addr, uint32_t data, uint32_t tag, uint32_t &rsp_tag,
                      const char *label) {
  sim->core_req_valid  = 1;
  sim->core_req_rw     = 1;
  sim->core_req_addr   = addr;
  sim->core_req_data   = data;
  sim->core_req_byteen = 0xF;
  sim->core_req_tag    = tag;
  uint32_t rsp_data;
  bool ok = run_txn(sim, ticks, mem, rsp_data, rsp_tag, label);
  sim->core_req_valid = 0;
  return ok;
}

static bool do_read(Sim &sim, uint64_t &ticks, std::unordered_map<uint32_t, uint64_t> &mem,
                     uint32_t addr, uint32_t tag, uint32_t &rsp_data, uint32_t &rsp_tag,
                     const char *label) {
  sim->core_req_valid  = 1;
  sim->core_req_rw     = 0;
  sim->core_req_addr   = addr;
  sim->core_req_byteen = 0xF;
  sim->core_req_tag    = tag;
  bool ok = run_txn(sim, ticks, mem, rsp_data, rsp_tag, label);
  sim->core_req_valid = 0;
  return ok;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  Sim sim;
  uint64_t ticks = 0;
  ticks = sim.reset(ticks);

  sim->core_rsp_ready = 1;
  sim->mem_req_ready  = 1;  // el modelo de "L2" siempre puede aceptar
  sim->mem_rsp_valid  = 0;

  std::unordered_map<uint32_t, uint64_t> mem;

  // Direcciones (word) elegidas para caer las tres en el mismo set con
  // NUM_WAYS=2: mismo bit de set (bit 1 = 0), tag distinto (bits altos).
  const uint32_t kAddr0 = 0;  // tag=0, set=0
  const uint32_t kAddr1 = 4;  // tag=1, set=0
  const uint32_t kAddr2 = 8;  // tag=2, set=0 -- fuerza desalojo al llegar

  const uint32_t kData0 = 0xAAAA0000;
  const uint32_t kData1 = 0xBBBB0000;
  const uint32_t kData2 = 0xCCCC0000;

  uint32_t rsp_tag = 0, rsp_data = 0;
  int fails = 0;

  // 1) llenar las 2 vías del set con líneas dirty (write-miss + fill).
  if (!do_write(sim, ticks, mem, kAddr0, kData0, 1, rsp_tag, "write addr0")) {
    std::printf("FAIL: write addr0 nunca respondió\n"); ++fails;
  }
  if (!do_write(sim, ticks, mem, kAddr1, kData1, 2, rsp_tag, "write addr1")) {
    std::printf("FAIL: write addr1 nunca respondió\n"); ++fails;
  }

  // 2) tercer write al mismo set: fuerza write-back de la vía víctima
  //    (dirty) antes de traer la línea nueva.
  if (!do_write(sim, ticks, mem, kAddr2, kData2, 3, rsp_tag, "write addr2 (eviction)")) {
    std::printf("FAIL: write addr2 (con desalojo) nunca respondió\n"); ++fails;
  }

  // 3) releer addr0: ya no está en la L1 (se desalojó en el paso 2), así
  //    que esto es un miss nuevo — pero el write-back del paso 2 debió
  //    haber guardado kData0 en el modelo de memoria. Si el dato vuelve
  //    distinto (o 0), el write-back está mal o no ocurrió.
  if (!do_read(sim, ticks, mem, kAddr0, 9, rsp_data, rsp_tag, "read addr0 (post-eviction)")) {
    std::printf("FAIL: read addr0 (post-desalojo) nunca respondió\n"); ++fails;
  } else if (rsp_data != kData0) {
    std::printf("FAIL: read addr0 post-desalojo trajo 0x%08X, esperado 0x%08X "
                "(el write-back perdió el dato)\n", rsp_data, kData0);
    ++fails;
  } else {
    std::printf("write-back: ok, addr0 desalojado y recuperado igual: 0x%08X\n", rsp_data);
  }

  // 4) addr1 nunca se tocó (sigue en la otra vía) -> debe seguir siendo hit.
  if (!do_read(sim, ticks, mem, kAddr1, 10, rsp_data, rsp_tag, "read addr1")) {
    std::printf("FAIL: read addr1 nunca respondió\n"); ++fails;
  } else if (rsp_data != kData1) {
    std::printf("FAIL: read addr1 trajo 0x%08X, esperado 0x%08X\n", rsp_data, kData1);
    ++fails;
  } else {
    std::printf("read addr1 (nunca desalojado): ok, 0x%08X\n", rsp_data);
  }

  if (fails) {
    std::printf("l1_cache isolation test: FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("l1_cache isolation test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
