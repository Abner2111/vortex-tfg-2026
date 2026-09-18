# Implementación de la L1 — tag array, data array, hit/miss, write-back

**Status: EN CURSO.** A-4 (interfaces) y A-5 (implementación funcional en
aislamiento) completos. A-9 (integrar en el núcleo de Vortex de verdad) —
pendiente, no arrancado.

**Rama:** `l1_cache/definition_and_interfaces`, 3 commits (2026-09-11):
`a1d73574f` (tag array + data array + interfaces + andamiaje del
testbench), `689b29649` (hit/miss), `8e93d81ce` (write-back).

**Scope:** `hw/rtl/tfg_l1/{l1_cache.sv,VX_snoop_bus_if.sv}`,
`hw/unittest/l1_cache/{Makefile,VX_l1_cache_top.sv,main.cpp,waivers.vlt}`.

---

## 1. Contexto

Continuación de
[nn_kernel_roofline_tfg_evaluation.md](nn_kernel_roofline_tfg_evaluation.md):
con el core de Vortex aislado y el punto de inserción (`VX_mem_bus_if` en el
bypass del dcache) ya caracterizado, este documento cubre la implementación
en sí de la L1 de reemplazo — actividad **A-5** del anteproyecto (tag array,
data array sobre BRAM, hit/miss, stall, write-back, simulación aislada), más
la especificación de interfaces de **A-4** que quedó pendiente ahí.

## 2. A-4 — Interfaces

De las cuatro interfaces que pide A-4 (L1↔pipeline, L1↔snoop bus, L1↔L2,
L2↔árbitro global), solo hizo falta diseñar una nueva:

| Interfaz | Decisión |
|---|---|
| L1 ↔ pipeline | Reutiliza `VX_mem_bus_if` de Vortex (`hw/rtl/mem/VX_mem_bus_if.sv`) — el mismo protocolo que el core ya habla en el punto de bypass del dcache. |
| L1 ↔ L2 | Mismo `VX_mem_bus_if`, en sentido master (la L1 es master hacia L2 igual que el core lo es hacia la L1). |
| L2 ↔ árbitro global | Mismo `VX_mem_bus_if` otra vez — es como Vortex ya conecta su propio L2/L3 al árbitro, así que no hace falta tocarlo. |
| L1 ↔ snoop bus | **Nueva**: [`VX_snoop_bus_if.sv`](../../hw/rtl/tfg_l1/VX_snoop_bus_if.sv) — bus de snoop MESI (broadcast de petición + respuesta por-snooper: hit/estado/dirty/datos). Marcado como *draft* en el propio archivo — revisar con el asesor antes de que otro módulo dependa de sus anchos exactos. |

## 3. A-5 — Tag array y data array

**Tag array** ([l1_cache.sv:33-124](../../hw/rtl/tfg_l1/l1_cache.sv#L33-L124)):
`NUM_WAYS` vías por set, cada línea `{valid, dirty, mesi, tag}`. Descompone
`core_bus_if.req_data.addr` en `{tag | set | word_offset}` y hace el lookup
combinacional de las vías del set indexado (`way_hit`/`hit_way`/`tag_hit`,
vía un `VX_onehot_encoder` reutilizado de `hw/rtl/libs/` en vez de escribir
un encoder propio). Selección de víctima: primera vía inválida del set, si
no hay ninguna cae en la vía 0 — **placeholder deliberado**, no es LRU/PLRU
real (comentado en el código, con nota de revisar antes de A-12 si el TFG
mide tasa de miss).

**Data array** ([l1_cache.sv:125-176](../../hw/rtl/tfg_l1/l1_cache.sv#L125-L176)):
`NUM_WAYS` memorias síncronas independientes (lectura *y* escritura
registradas en el flanco de reloj — necesario para que el sintetizador
infiera BRAM real en vez de LUTRAM/FFs; **la inferencia real todavía no se
confirmó**, queda para A-12).

## 4. A-5 — Lógica de hit/miss

FSM de 5 estados, una petición en vuelo a la vez —
[l1_cache.sv:177-348](../../hw/rtl/tfg_l1/l1_cache.sv#L177-L348):

```
S_IDLE ─┬─ hit ────────────────────────► S_HIT ──────► S_IDLE
        ├─ miss, víctima limpia ───────► S_MISS_WAIT ─► S_FILL ─► S_IDLE
        └─ miss, víctima dirty ───────► S_WB ────────► S_MISS_WAIT ─► S_FILL ─► S_IDLE
```

- **S_IDLE**: acepta petición nueva; `tag_hit` ya es combinacional este
  mismo ciclo (tag array), decide el siguiente estado al vuelo.
- **S_HIT**: sirve `data_rd_data[hit_way_r]` (o lo mezcla con la palabra
  entrante si era un write) — ver §5 sobre el desfase de un ciclo del read
  síncrono.
- **S_WB**: vuelca la línea víctima dirty a `mem_bus_if` antes de pedir la
  línea nueva (write-back — ver §6).
- **S_MISS_WAIT**: pide la línea nueva completa (una sola transacción,
  `mem_bus_if.DATA_SIZE = LINE_SIZE`).
- **S_FILL**: mezcla la línea que llegó con el write pendiente si aplica
  (write-allocate) y responde.

**`core_bus_if.req_ready = (state == S_IDLE)`** — la señal de stall queda
resuelta como parte de la FSM, sin bloque aparte (el anteproyecto la lista
como actividad separada, pero es inherente a que la FSM solo acepta una
petición a la vez).

## 5. Bug real encontrado: `data_rd_data` se corrompía a mitad de un miss largo

Antes de escribir hit/miss, el read síncrono del data array indexaba
directo por `req_set` (derivado del bus **en vivo**). Mientras la FSM está
ocupada varios ciclos (miss, write-back), `core_bus_if.req_valid` ya bajó
pero nada garantiza que el resto del bus (`req_data.addr`) se quede
estable — si el pipeline externo cambia de dirección mientras tanto,
`data_rd_data` empieza a leer un set distinto sin que la FSM se entere.

Fix: `array_set_addr` ([l1_cache.sv:155](../../hw/rtl/tfg_l1/l1_cache.sv#L155)) —
usa `req_set` (vivo) solo en `S_IDLE`; el resto del tiempo usa `req_set_r`
(congelado, registrado al aceptar la petición). Encontrado y corregido
*antes* de escribir write-back, porque write-back depende de que
`data_rd_data[victim_way_r]` siga siendo válido varios ciclos mientras se
espera la respuesta del volcado.

## 6. A-5 — Write-back

[l1_cache.sv:284-294](../../hw/rtl/tfg_l1/l1_cache.sv#L284-L294): en `S_WB`,
`mem_bus_if` hace una escritura (`rw=1`) a la dirección **vieja** de la
víctima (`{victim_tag_r, req_set_r}`) con el dato `data_rd_data[victim_way_r]`
— la línea que se está por pisar. Solo se visita cuando la vía víctima está
`valid && dirty`; si está limpia o inválida, salta directo a `S_MISS_WAIT`.

**Pendiente, fuera de este alcance**: write-back disparado por un snoop de
invalidación sobre una línea M (`snoop_bus_if`) — un tercer disparador
además del miss local, que puede llegar mientras la FSM ya está ocupada con
otra cosa. Necesita su propio camino, no cablear ahora.

## 7. Test: `hw/unittest/l1_cache/`

Config de prueba deliberadamente chica (`CACHE_SIZE=32, LINE_SIZE=8,
NUM_WAYS=2, WORD_SIZE=4` — 2 sets, 2 vías, `LINE_BITS=64` cabe en un
escalar de Verilator) para que el modelo de memoria del lado de
`mem_bus_if` sea manejable desde C++ sin arrays anchos. **No son los
defaults reales de `l1_cache.sv`** (`4096/64/4/4`), que nunca se
ejercitaron.

| # | Transacción | Qué ejercita | Verificación |
|---|---|---|---|
| 1 | `write addr0` | write-miss → fill (write-allocate), vía 0 | responde |
| 2 | `write addr1` | write-miss al mismo set → fill en vía 1 | responde |
| 3 | `write addr2 (eviction)` | write-miss con el set lleno → dispara `S_WB` | responde |
| 4 | `read addr0 (post-eviction)` | miss nuevo tras el desalojo — sirve de lo que el write-back guardó | **compara el dato contra lo escrito en #1** |
| 5 | `read addr1` | línea nunca tocada, sigue en la otra vía | hit puro, compara contra #2 |

`PASSED (48 ticks)` — los 5 pasos encadenados en una corrida.

### Tres bugs de timing encontrados en el propio testbench (no en el RTL)

Todos la misma familia: decidir una señal de protocolo leyendo un valor
**después** del flanco de reloj, cuando ese valor ya refleja el resultado
del flanco (no lo que había *antes* de aplicarlo) — un desfase de un ciclo
que hace que una aceptación válida (`valid && ready` ambos en 1) se
detecte tarde y se pierda:

1. Bajar `core_req_valid` apenas se leía `core_req_ready==1` post-flanco
   —para entonces la aceptación ya había pasado (o era el flanco
   `S_FILL→S_IDLE` del turno anterior, no una aceptación nueva). Fix:
   sostener `core_req_valid` durante toda la transacción, dejar que el
   caller lo baje al final.
2. `mem_rsp_valid` quedaba pegado en 1 entre llamadas (el loop cortaba
   apenas veía `core_rsp_valid`, sin dejar que el estado `RESPONDING` lo
   bajara). Fix: limpiarlo explícitamente al salir de `run_txn`.
3. Con `mem_req_ready` fijo en 1, una petición nueva que llegaba justo
   cuando el driver todavía procesaba la respuesta anterior se aceptaba
   sola del lado RTL y desaparecía de `mem_req_valid` antes de que el
   driver llegara a capturarla. Fix de fondo: reordenar el loop para
   decidir las entradas del lado `mem_bus_if` **antes** de llamar a
   `step()` (usando el valor tal como está, estable, sin haber avanzado el
   reloj), no después — el patrón correcto para cualquier testbench
   ciclo-exacto.

## 8. Qué está verificado y qué no

**Verificado**: el módulo compila, elabora y pasa el test funcional
descrito arriba — pero **en aislamiento total**: un testbench en C++ hecho
a mano emula tanto el lado del core como el lado de memoria.

**No verificado — brechas reales**:

- Nunca se instanció en el núcleo de Vortex de verdad (reemplazar el
  bypass del dcache con `-DVX_CFG_DCACHE_DISABLE`) — eso es la actividad
  **A-9**, no arrancada.
- Parámetros de test chicos a propósito, no los defaults reales del módulo.
- Direcciones de test elegidas a mano, no tráfico real de un kernel
  corriendo en el core SIMT.
- Sin síntesis — ni inferencia de BRAM confirmada, ni área, ni timing.
- Registros sin reset explícito (`victim_way_r`, `req_set_r`, `hit_way_r`,
  etc. — solo `state` y `mem_req_sent_r` se resetean). Funciona en
  simulación porque la FSM garantiza que se escriben antes de leerse; vale
  la pena que un linter de síntesis lo confirme antes de sintetizar.
- Un solo request en vuelo — sin comparar throughput contra el dcache real
  de Vortex (que sí pipeliniza con bancos).
- `core_bus_if` es de **1 lane** (una petición coalescida a la vez, sin
  arreglo `[NUM_REQS]`) — si hace falta más de un puerto para calzar con un
  socket real (`DCACHE_NUM_REQS` > 1), hay que instanciar varias copias o
  extender el módulo; no está hecho.

## 9. Mapeo a los objetivos del anteproyecto

| Trabajo de hoy | Objetivo / actividad |
|---|---|
| §2 (interfaces) | **A-4** completo, salvo la revisión con el asesor que pide el propio anteproyecto. |
| §3-6 (tag array, data array, hit/miss, stall, write-back) | **A-5** completo en aislamiento. |
| §7 (test funcional con desalojo real) | Cubre el "compilar y simular en aislamiento con estímulos básicos" que cierra A-5. |
| §8 (brechas) | Define el contenido real de **A-9** (integración) y adelanta lo que **A-12** (síntesis) va a tener que confirmar. |

## 10. Pendientes

- **A-9**: instanciar `l1_cache.sv` en el punto de bypass del dcache de un
  build real de Vortex; conectar la señal de stall; verificar que el
  núcleo la respeta.
- Confirmar inferencia de BRAM real (A-12).
- Reemplazar la política de víctima placeholder por LRU/PLRU si el TFG
  termina midiendo tasa de miss.
- Write-back disparado por snoop (coherencia entre L1s, cuando haya más de
  un core).
- Revisar `VX_snoop_bus_if.sv` con el asesor — sigue siendo *draft*.
- Decidir si hace falta más de 1 lane en `core_bus_if` para el socket real.
