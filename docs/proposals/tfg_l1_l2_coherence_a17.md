# A-17 — Prueba de integración de coherencia L1→L2

**Status: CERRADO, con un bug real encontrado y corregido.** Dos L1
reales + `snoop_bus.sv` real + `l2_cache.sv` real, conectados de punta a
punta por primera vez de esta forma — ni A-14 (que nunca forzaba un
flush real) ni A-11/A-16 (que probaban L2 contra mocks de C++) habían
ejercitado el camino de escritura de `l1_cache.sv` contra el
`core_bus_if` real de `l2_cache.sv`.

**Rama:** `l2/initial_implementation`.

**Scope:** `hw/rtl/tfg_l2/l2_cache.sv` (corrección real),
`hw/unittest/l1_l2_coherence/{Makefile,VX_l1_l2_top.sv,main.cpp,waivers.vlt}`
(nuevo).

## 1. Testbench

`hw/unittest/l1_l2_coherence/` — mismo patrón que
`hw/unittest/snoop_bus` (2 `l1_cache.sv` + `snoop_bus.sv` reales), pero
con `l2_cache.sv` real en el lugar donde ese testbench usaba un mock de
"memoria" plano. `l2_cache` recibe `NUM_CORES=2` (una por L1),
`NUM_BANKS=2`; lo que hay debajo de L2 (memoria real / árbitro global)
sigue mockeado en C++, fuera del alcance de esta prueba. Estímulos a
nivel de bus (no pasa por un `VX_core` real) — acotado a probar
coherencia L1→L2, no la integración de pipeline completa (eso ya lo
prueba A-14).

## 2. Escenarios

- **Escenario A (el que pide A-17 literal):** `core0` escribe `addrX`
  (I→M local). `core1` lee `addrX` → dispara snoop sobre `core0` (lo
  encuentra en M) → `core0` flushea (`SNP_WB`) a L2 real → M→S → `core1`
  trae la línea de L2 ya con el dato fresco.
- **Escenario B (caso límite — writeback *sin* snoop):** `core0` fuerza
  su propio desalojo local (llena las 2 vías del set con la línea
  dirty) — un writeback derecho a L2, sin que el snoop bus intervenga.
  `core1` lee esa misma línea después (su propio miss, nadie más la
  tiene) y la trae de L2.

En ambos se verifica que el dato leído es el más reciente — tanto del
lado que lo trae de L2 por primera vez como del lado que lo seguía
teniendo localmente (escenario A, `core0` releyendo en S).

## 3. El bug encontrado

**Síntoma:** los dos escenarios se colgaban — no fallaban por dato
incorrecto, nunca llegaba ninguna respuesta (timeout).

**Causa raíz:** dos contratos de bus que, por separado, eran correctos,
pero no calzaban entre sí al conectarlos de verdad:

- `l1_cache.sv`, en su `mem_bus_if` (hacia "lo que hay abajo"), espera
  `rsp_valid` para **cualquier** transacción — lectura o escritura, sin
  ningún gate por `rw` (`l1_cache.sv:453`, `S_WB`). Decisión tomada en
  A-9/A-14: el nivel caché↔memoria asume que quien está debajo confirma
  toda escritura antes de que el que la pidió siga adelante.
- `l2_cache.sv`, en su `core_bus_if` (hacia L1), **nunca** respondía una
  escritura (`bank_resp_valid = (...) && !req_rw_r`) — construido en
  A-11 copiando el contrato que `core_bus_if` tiene en `l1_cache.sv`
  hacia el pipeline (fire-and-forget), sin notar que ACÁ ese mismo
  nombre de puerto juega el rol de "memoria" desde la perspectiva de
  quien habla con él (`l1_cache.sv`), no el rol de "CPU".

Ninguna actividad anterior lo había ejercitado: A-14 nunca forzaba un
flush real (su único store se quedaba dirty dentro de L1, que es
write-back); A-11/A-16 probaban `l2_cache.sv` contra mocks de C++ que no
imponían el contrato de `l1_cache.sv`. Hacía falta conectar los DOS
módulos reales, con un flush real de por medio, para que apareciera.

**Corrección** (`hw/rtl/tfg_l2/l2_cache.sv`): `bank_resp_valid` ya no
excluye las escrituras — responde en `S_HIT`/`S_FILL` para cualquier
transacción, y el estado espera `resp_ready_sel` antes de volver a
`S_IDLE` en ambos casos (antes, una escritura salía de `S_HIT` sin
esperar nada).

**Verificación de no-regresión:** re-corridos `hw/unittest/l2_cache`
(4/4, A-11/A-14 paso 0) y `hw/unittest/compute_unit` (A-14) sin cambios
— ambos siguen en `PASSED`, idéntico resultado que antes de la
corrección. Los tests de L2 existentes nunca dependían de la AUSENCIA
de respuesta en una escritura (usan el flanco de `req_ready` para
detectar fin de escritura, no la ausencia de `rsp_valid`), así que
agregar el ack no los rompía — pero se confirmó, no se asumió.

## 4. Resultado final

```
l1_l2_coherence test: PASSED (124 ticks)
```

## 5. Lección para el resto del TFG

Este es el mismo patrón que ya aparecció en A-9 (L1↔pipeline) y en el
análisis de A-15 (prefetch, descartado): **un contrato de bus que es
internamente consistente en dos módulos probados por separado puede
seguir siendo incompatible cuando se conectan de verdad.** Cada vez que
este TFG sube un nivel de integración (L1 aislado → L1+pipeline → L1+L2
→ L1+L2+pipeline), vale la pena asumir que hay al menos un caso de este
tipo esperando, y buscarlo con una prueba que fuerce el camino menos
común (acá, un flush real) en vez de confiar en que "ya está probado
por partes".
