# Pruebas unitarias de l1_cache.sv en aislamiento (A-10) — estado

**Status: CERRADO.** Las cuatro categorías de prueba (hit, miss, stall,
write-back) están cubiertas en `hw/unittest/l1_cache/main.cpp`, corriendo
en aislamiento total (sin `snoop_bus.sv`, sin `VX_core`) contra el mismo
testbench de A-5/A-6 (`VX_l1_cache_top.sv`). Suite completa: **PASSED**.

**Rama:** `l1_cache/core_integration`.

**Scope:** `hw/unittest/l1_cache/main.cpp` (sin cambios en RTL).

## 1. Qué cubre cada categoría

La mayoría de las categorías ya estaban cubiertas por el trabajo de A-5
(datapath básico) y A-6 (snooper) — lo que agrega A-10 puntualmente es la
categoría de **stall**, que no estaba ejercitada: hasta ahora todas las
pruebas corrían con `mem_req_ready=1` y `core_rsp_ready=1` constantes
(memoria y consumidor siempre listos).

| Categoría | Escenario(s) | Qué confirma |
|---|---|---|
| **Hit** | "read addr1" (parte 1); "[stall] read addr1" (parte 3) | Un hit no reconsulta `mem_bus_if`, devuelve el dato correcto en el primer intento. |
| **Miss** | "write addr0/addr1/addr2" (parte 1, miss de escritura con fill); "[MESI] read addr0 (miss -> E)" (parte 2, miss de lectura) | Write-allocate y read-fill traen la línea de `mem_bus_if` y resuelven con el dato correcto. |
| **Write-back** | "write addr2 (eviction)" + "read addr0 (post-eviction)" (parte 1); escenarios M->E->S / M->E->I (parte 2, flush disparado por snoop) | Una línea dirty desalojada (por reemplazo local o por snoop remoto) se vuelca a memoria antes de perderse — releída, trae lo escrito, no basura. |
| **Stall** | tres escenarios nuevos (parte 3, ver §2) | La FSM espera sin perder ni corromper la transacción en vuelo cuando cualquiera de los dos lados del bus hace backpressure. |

## 2. Escenarios de stall (nuevos en A-10)

Se extendió `run_txn()` (ya usado por `do_write`/`do_read` desde A-5) con
dos parámetros opcionales, ambos en 0 por defecto (sin cambiar el
comportamiento de las pruebas existentes):

- `mem_stall_cycles`: mantiene `mem_req_ready=0` los N ciclos que haya una
  petición pendiente hacia `mem_bus_if` — simula un L2/memoria lento.
- `rsp_stall_cycles`: mantiene `core_rsp_ready=0` las primeras N vueltas
  del loop — simula un consumidor lento del lado del core.

Tres escenarios, cada uno con 5 ciclos de stall:

1. **Stall de memoria durante un miss/fill** — read-miss donde el "L2"
   tarda 5 ciclos en aceptar el pedido de línea. Confirma que la FSM no
   reintenta ni abandona la petición mientras espera.
2. **Stall de memoria durante un write-back** — eviction (mismo mecanismo
   que la parte 1) donde el "L2" tarda 5 ciclos en aceptar el flush de la
   línea dirty desalojada. Confirma que el dato no se pierde aunque el
   volcado se demore.
3. **Stall del consumidor sobre un read-hit** — el core tarda 5 ciclos en
   levantar `core_rsp_ready` sobre una respuesta ya lista. Confirma que la
   cache sostiene `rsp_valid`/`rsp_data` estables (no los pisa, no avanza
   de estado) hasta que el consumidor por fin acepta — mismo criterio que
   usa `l1_cache.sv` para decidir cuándo salir de `S_HIT`/`S_FILL`.

Las tres pasan con el dato final correcto, lo que confirma indirectamente
que ningún stall corrompe `tag_array`/data array ni descarta la petición
en vuelo (si lo hiciera, el dato final habría llegado mal o la prueba
nunca habría respondido dentro de `max_cycles`).

## 3. Resultado de la corrida completa

```
l1_cache isolation test: PASSED (224 ticks)
```

Las 11 pruebas (2 de la parte 1 + 3 escenarios MESI de la parte 2, cada
uno con 1-2 sub-chequeos + 3 escenarios de stall de la parte 3) pasan sin
fallos, en aislamiento total — sin `snoop_bus.sv` real (el lado master del
snoop está mockeado como "nadie más la tiene", igual que desde A-6) y sin
`VX_core` (ver A-9 para esa integración,
[tfg_core_integration_progress.md](tfg_core_integration_progress.md)).

## 4. Qué queda fuera de A-10 (por diseño)

- Coherencia multi-L1 real (dos `l1_cache.sv` conectados por
  `snoop_bus.sv`) — eso es A-7/A-8, probado en
  `hw/unittest/snoop_bus/main.cpp`, no en este testbench de un solo L1.
- Tráfico generado por un `VX_core` real — eso es A-9.
- Síntesis/timing — A-12.
