# A-16 — Pruebas unitarias de la L2

**Status: CERRADO, reusando cobertura existente.** Las tres pruebas
pedidas ya estaban cubiertas por `hw/unittest/l2_cache/main.cpp` (A-11,
escalado a 4 núcleos/4 bancos en A-14 §paso 0) — no se escribió código
nuevo, este documento cierra A-16 referenciando esa cobertura bajo su
propio nombre, mismo criterio que ya se usó en A-10 (pruebas de L1,
reusando cobertura de A-5/A-6 donde ya existía).

**Rama:** `l2/initial_implementation`.

**Scope:** ninguno — documentación únicamente. `hw/rtl/tfg_l2/l2_cache.sv`
y `hw/unittest/l2_cache/` no se modificaron para este cierre.

## 1. Mapeo de las pruebas pedidas a la cobertura existente

| Prueba pedida (A-16) | Escenario(s) en `main.cpp` | Qué confirma |
|---|---|---|
| Accesos concurrentes a bancos distintos | Escenario 1 (2 núcleos, 2 bancos, mismo ciclo exacto) y Escenario 5 (4 núcleos, 4 bancos, mismo ciclo exacto) | Dos (o cuatro) escrituras a bancos distintos no se arbitran entre sí — todas responden sin esperarse, cada núcleo recupera su propio dato sin cruzarse con los demás. |
| Writebacks desde L1 | Escenarios 2 y 4 | Cada escritura que llega a `core_bus_if` de L2 ES un writeback de L1 en este diseño (L1 solo manda a L2 líneas completas, writeback o write-allocate) — el 2 prueba write-hit y write-miss-directo bajo contención; el 4 prueba que un writeback desalojado (eviction) se vuelca correctamente al nivel de abajo antes de perderse. |
| Miss que llega al árbitro global | Escenario 3 | Un read-miss real dispara exactamente 1 petición hacia `mem_bus_if` (el árbitro global, mockeado en este testbench aislado); una segunda lectura de la misma línea ya es un hit y no genera tráfico nuevo. |

Ningún caso quedó sin cubrir — las tres pruebas pedidas por A-16 ya
estaban, cada una, en al menos un escenario existente.

## 2. Corrida fresca (confirmación para este cierre)

```
l2_cache isolation test (4/4): PASSED (86 ticks)
```

Las 5 pruebas (los 4 escenarios originales de A-11 + el escenario 5
agregado en A-14 §paso 0 para N=4) pasan sin fallos.

## 3. Por qué no se agregó nada nuevo

A-14 (§paso 0) ya había subido este mismo suite de 2/2 núcleos/bancos
(alcance de A-11) a 4/4 — precisamente para poder confiar en
`l2_cache.sv` antes de integrarla en `compute_unit.sv`. Ese trabajo ya
ejercita las tres propiedades que A-16 pide, a la escala real que usa el
resto del TFG (4 núcleos). Escribir una segunda ronda de pruebas
casi-idénticas solo para que viva bajo el nombre "A-16" sería
duplicación sin valor nuevo — en cambio, este documento deja el mapeo
explícito para que la numeración del anteproyecto quede satisfecha sin
repetir trabajo.

Si en algún momento se necesita una prueba genuinamente nueva (por
ejemplo, **lecturas** concurrentes entre bancos, no solo escrituras —
el escenario 1 solo ejercita escrituras simultáneas, las lecturas de
confirmación corren secuenciales después), se puede agregar como un
escenario más en `hw/unittest/l2_cache/main.cpp` sin tocar nada del
diseño existente.
