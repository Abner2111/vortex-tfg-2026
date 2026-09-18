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
// TFG: prueba en aislamiento de l1_cache.sv.
//
// Parte 1 (A-5, "compilar y simular en aislamiento con estímulos básicos"):
// ejercita el datapath completo, incluyendo write-back: con NUM_WAYS=2 en
// este testbench, escribir 3 direcciones que caen en el mismo set fuerza
// un desalojo de una línea dirty en la tercera. Un modelo de "memoria"
// persistente del lado de mem_bus_if (unordered_map) permite confirmar
// que el dato desalojado sobrevive: releerlo después trae lo escrito, no
// basura.
//
// Parte 2 (A-6, lado snooper): simula "el otro L1" pidiendo snoops sobre
// snoop_bus_if y verifica, con acceso directo a tag_array (dbg_mesi_way*/
// dbg_valid_way*, ver VX_l1_cache_top.sv), las transiciones E->S, S->I y
// M->E->S/M->E->I documentadas en
// docs/proposals/tfg_mesi_coherence_design.md. El lado master (I->E vs.
// I->S en un miss local) queda para A-7, no se prueba acá.

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

// MESI_I/S/E/M, mismos valores que VX_snoop_bus_if.sv (comentario ahí: los
// enums de la interfaz no cruzan limpio a Verilator/C++, se usan literales).
enum { MESI_I = 0, MESI_S = 1, MESI_E = 2, MESI_M = 3 };

// Simula "el otro L1" pidiendo un snoop de coherencia sobre `addr` (dirección
// de LÍNEA, no de palabra -- ver l1_cache.sv: snoop_set/snoop_tag decodifican
// snoop_bus_if.snoop_addr igual que mem_bus_if.req_data.addr, sin los bits de
// offset dentro de línea). Si el snoopeado tiene la línea en M, dispara un
// flush real por mem_bus_if (mismo mecanismo que un write-back de miss local)
// antes de poder responder -- por eso este helper corre la misma máquina de
// estados WAIT_REQ/DELAY/RESPONDING que run_txn del lado mem_bus_if.
//
// snoop_valid se mantiene alto (decidido antes de cada step(), nunca leído
// después) hasta ver snoop_ready, igual criterio que core_req_valid en
// run_txn -- ver el comentario de "orden crítico" ahí arriba.
static bool do_snoop(Sim &sim, uint64_t &ticks, std::unordered_map<uint32_t, uint64_t> &mem,
                      uint32_t addr, bool rw, bool &out_hit, uint32_t &out_state, bool &out_dirty,
                      const char *label, int max_cycles = 30) {
  enum { WAIT_REQ, DELAY, RESPONDING } mem_state = WAIT_REQ;
  uint32_t cap_addr = 0, cap_wdata = 0;
  bool cap_rw = false;
  bool got_rsp = false;

  sim->snoop_valid = 1;
  sim->snoop_addr  = addr;
  sim->snoop_rw    = rw ? 1 : 0;

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
        if (cap_rw) mem[cap_addr] = cap_wdata;  // flush del snoopeado: persiste
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

    if (sim->snoop_ready) {
      got_rsp   = true;
      out_hit   = sim->snoop_hit;
      out_state = sim->snoop_state;
      out_dirty = sim->snoop_dirty;
    }
  }
  sim->snoop_valid   = 0;
  sim->mem_rsp_valid = 0;
  return got_rsp;
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

  // ------------------------------------------------------------------
  // Parte 2 (A-6): lado snooper. Cada escenario arranca de un reset propio
  // -- cache limpio, sin depender de en qué vía haya quedado algo de la
  // parte 1. `occupied()` lee las dos vías del set 0 sin asumir cuál usa
  // la política de víctima (placeholder documentado en l1_cache.sv, no es
  // parte de lo que A-6 verifica) -- solo importa que exactamente una
  // quede válida, con el estado MESI esperado.
  //
  // kAddr0 (word 0, tag=0/set=0) reutilizado; kLineAddr0 es la misma
  // dirección pero en formato de línea (sin los OFFSET_BITS bajos), que es
  // el formato que espera snoop_bus_if.snoop_addr -- igual que
  // mem_bus_if.req_data.addr (ver l1_cache.sv).
  // ------------------------------------------------------------------
  const uint32_t kLineAddr0 = kAddr0 >> 1;  // OFFSET_BITS=1 en este testbench

  auto occupied = [&](bool &valid, uint32_t &mesi) {
    if (sim->dbg_valid_way0)      { valid = true;  mesi = sim->dbg_mesi_way0; }
    else if (sim->dbg_valid_way1) { valid = true;  mesi = sim->dbg_mesi_way1; }
    else                          { valid = false; mesi = 0; }
  };

  bool sh; uint32_t sstate; bool sdirty;
  bool ov; uint32_t omesi;

  // --- Escenario 1: I->E (miss local de lectura), luego E->S (snoop
  //     remoto de lectura), luego S->I (snoop remoto de escritura). ---
  ticks = sim.reset(ticks);
  sim->core_rsp_ready = 1;
  sim->mem_req_ready  = 1;
  sim->mem_rsp_valid  = 0;

  if (!do_read(sim, ticks, mem, kAddr0, 20, rsp_data, rsp_tag, "[MESI] read addr0 (miss -> E)")) {
    std::printf("FAIL: read addr0 (escenario 1) nunca respondió\n"); ++fails;
  } else {
    occupied(ov, omesi);
    if (!ov || omesi != MESI_E) {
      std::printf("FAIL: tras el miss, debería quedar en E (valid=%d,mesi=%d)\n", ov, omesi);
      ++fails;
    } else {
      std::printf("I->E: ok, línea en E tras el miss local\n");
    }
  }

  if (!do_snoop(sim, ticks, mem, kLineAddr0, /*rw=*/false, sh, sstate, sdirty,
                "[MESI] snoop remoto de lectura sobre addr0 (E)")) {
    std::printf("FAIL: snoop de lectura (E) nunca respondió\n"); ++fails;
  } else if (!sh || sstate != MESI_E || sdirty) {
    std::printf("FAIL: snoop esperaba hit=1,state=E(%d),dirty=0 -- llegó hit=%d,state=%d,dirty=%d\n",
                MESI_E, sh, sstate, sdirty);
    ++fails;
  } else {
    occupied(ov, omesi);
    if (!ov || omesi != MESI_S) {
      std::printf("FAIL: tras el snoop de lectura, debería quedar en S (valid=%d,mesi=%d)\n", ov, omesi);
      ++fails;
    } else {
      std::printf("E->S: ok, snoop reportó E, línea quedó en S\n");
    }
  }

  if (!do_snoop(sim, ticks, mem, kLineAddr0, /*rw=*/true, sh, sstate, sdirty,
                "[MESI] snoop remoto de escritura sobre addr0 (S)")) {
    std::printf("FAIL: snoop de escritura (S) nunca respondió\n"); ++fails;
  } else if (!sh || sstate != MESI_S || sdirty) {
    std::printf("FAIL: snoop esperaba hit=1,state=S(%d),dirty=0 -- llegó hit=%d,state=%d,dirty=%d\n",
                MESI_S, sh, sstate, sdirty);
    ++fails;
  } else {
    occupied(ov, omesi);
    if (ov) {
      std::printf("FAIL: tras el snoop de escritura, la línea debería quedar invalidada\n");
      ++fails;
    } else {
      std::printf("S->I: ok, snoop reportó S, línea quedó invalidada\n");
    }
  }

  // --- Escenario 2: M->E->S (snoop remoto de lectura sobre línea sucia:
  //     primero flush -- M->E -- y después se comparte -- E->S). ---
  ticks = sim.reset(ticks);
  sim->core_rsp_ready = 1;
  sim->mem_req_ready  = 1;
  sim->mem_rsp_valid  = 0;
  mem.clear();

  const uint32_t kDataM1 = 0x11112222;
  if (!do_write(sim, ticks, mem, kAddr0, kDataM1, 21, rsp_tag, "[MESI] write addr0 (miss -> M)")) {
    std::printf("FAIL: write addr0 (escenario 2) nunca respondió\n"); ++fails;
  } else {
    occupied(ov, omesi);
    if (!ov || omesi != MESI_M) {
      std::printf("FAIL: tras el write-miss, debería quedar en M (valid=%d,mesi=%d)\n", ov, omesi);
      ++fails;
    }
  }

  if (!do_snoop(sim, ticks, mem, kLineAddr0, /*rw=*/false, sh, sstate, sdirty,
                "[MESI] snoop remoto de lectura sobre addr0 (M, flush)")) {
    std::printf("FAIL: snoop de lectura (M) nunca respondió\n"); ++fails;
  } else if (!sh || sstate != MESI_M || !sdirty) {
    std::printf("FAIL: snoop esperaba hit=1,state=M(%d),dirty=1 -- llegó hit=%d,state=%d,dirty=%d\n",
                MESI_M, sh, sstate, sdirty);
    ++fails;
  } else {
    occupied(ov, omesi);
    if (!ov || omesi != MESI_S) {
      std::printf("FAIL: tras el flush+share, debería quedar en S (valid=%d,mesi=%d)\n", ov, omesi);
      ++fails;
    } else if (mem[kLineAddr0] != kDataM1) {
      std::printf("FAIL: el flush no volcó el dato sucio a memoria (mem[0x%x]=0x%lx, esperado 0x%x)\n",
                  kLineAddr0, (unsigned long)mem[kLineAddr0], kDataM1);
      ++fails;
    } else {
      std::printf("M->E->S: ok, flush volcó el dato y la línea quedó en S\n");
    }
  }

  // --- Escenario 3: M->E->I (snoop remoto de escritura sobre línea sucia:
  //     flush igual que arriba, pero termina invalidando en vez de compartir). ---
  ticks = sim.reset(ticks);
  sim->core_rsp_ready = 1;
  sim->mem_req_ready  = 1;
  sim->mem_rsp_valid  = 0;
  mem.clear();

  const uint32_t kDataM2 = 0x33334444;
  if (!do_write(sim, ticks, mem, kAddr0, kDataM2, 22, rsp_tag, "[MESI] write addr0 (miss -> M), otra vez")) {
    std::printf("FAIL: write addr0 (escenario 3) nunca respondió\n"); ++fails;
  }

  if (!do_snoop(sim, ticks, mem, kLineAddr0, /*rw=*/true, sh, sstate, sdirty,
                "[MESI] snoop remoto de escritura sobre addr0 (M, flush+invalidar)")) {
    std::printf("FAIL: snoop de escritura (M) nunca respondió\n"); ++fails;
  } else if (!sh || sstate != MESI_M || !sdirty) {
    std::printf("FAIL: snoop esperaba hit=1,state=M(%d),dirty=1 -- llegó hit=%d,state=%d,dirty=%d\n",
                MESI_M, sh, sstate, sdirty);
    ++fails;
  } else {
    occupied(ov, omesi);
    if (ov) {
      std::printf("FAIL: tras el flush+invalidar, la línea debería quedar invalidada\n");
      ++fails;
    } else if (mem[kLineAddr0] != kDataM2) {
      std::printf("FAIL: el flush no volcó el dato sucio a memoria (mem[0x%x]=0x%lx, esperado 0x%x)\n",
                  kLineAddr0, (unsigned long)mem[kLineAddr0], kDataM2);
      ++fails;
    } else {
      std::printf("M->E->I: ok, flush volcó el dato y la línea quedó invalidada\n");
    }
  }

  if (fails) {
    std::printf("l1_cache isolation test: FAILED (%d fallo(s))\n", fails);
    return 1;
  }
  std::printf("l1_cache isolation test: PASSED (%lu ticks)\n", (unsigned long)ticks);
  return 0;
}
