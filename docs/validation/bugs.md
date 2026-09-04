# Registro bug — campagna di ri-certificazione FPGA-Neural

Formato per ogni voce: severità, sintomo, causa radice, evidenza (file:riga / comando/log
citabile), stato, test di regressione che lo blocca (se risolto) o che lo riprodurrebbe (se
aperto). Aggiornato incrementalmente man mano che avanzano gli aspetti C.1–C.14.

Severità: **CRITICA** (corrompe dati/hang in scenari raggiungibili), **MEDIA** (comportamento
scorretto in casi limite plausibili ma rari), **BASSA** (difetto reale ma senza impatto
funzionale pratico), **INFO** (non un bug: gap di copertura, ambiguità documentale/naming).

---

## Aperti

### BUG-001 (INFO, non ancora classificato) — `sim/top.v` non compila contro l'RTL corrente

- **Sintomo**: `iverilog` fallisce con `parameter FRAC_BITS not found in top.dut`.
- **Causa radice**: `sim/top.v` è un residuo della versione Q8.8 a virgola fissa del
  progetto, mai aggiornato dopo la conversione a INT8 puro (Fase 6, vedi
  `docs/validation/00-inventario.md` §0.2).
- **Evidenza**: `iverilog -g2012 -o /tmp/topcheck.out rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v sim/top.v` → 2 errori di elaborazione.
- **Impatto**: nessuno sulla regressione (il file non è referenziato da alcun testbench o
  tool) — è dead code, non un difetto funzionale del design.
- **Stato**: aperto, non corretto per policy §E (analisi separata dalla correzione). Azione
  proposta: rimuovere il file o aggiornarlo, decisione da confermare con l'utente.

### BUG-002 (da classificare, indagine formale in C.1) — guard `N_INPUTS % PARALLEL` non copre `N_INPUTS=0`

- **Sintomo potenziale**: se `N_INPUTS=0`, il guard elaboration-time in
  `rtl/neuron_parallel.v:71` (`if (N_INPUTS % PARALLEL != 0)`) non scatta (`0 % PARALLEL ==
  0` per ogni `PARALLEL`), ma `GROUPS = N_INPUTS / PARALLEL = 0` — la stessa condizione di
  hang (`group_index == GROUPS-1` mai soddisfatta) che il guard dichiara di prevenire nel
  proprio commento (righe 55-58).
- **Causa radice (ipotesi, non ancora confermata su hardware simulato)**: il guard controlla
  solo la divisibilità, non `N_INPUTS > 0` esplicitamente.
- **Evidenza**: lettura diretta di `rtl/neuron_parallel.v:55-73` — vedi
  `docs/validation/00-inventario.md` §0.6 per il testo esatto.
- **Stato**: **APERTO, non ancora verificato con un test reale**. Non è ancora chiaro se
  `N_INPUTS=0` sia una configurazione raggiungibile nella pratica (nessun layer con zero
  ingressi ha senso a livello di sistema) — da chiudere in C.1 con un test avversariale
  dedicato e un oracolo indipendente, prima di classificarlo come bug vero o come rischio
  teorico non rilevante.

---

## Risolti

(nessuno ancora in questa campagna — la Fase 0 è analisi/inventario, non correzione)

---

## Non-bug (falsi positivi trovati e chiusi durante l'analisi)

Voci che sono sembrate anomalie a un primo controllo automatico ma si sono rivelate corrette
per progetto una volta letto il codice/intento — riportate per trasparenza sul processo, non
perché siano difetti.

- **`neuron_parallel_guard_negative_{degenerate,nonmultiple}_tb.v` "falliscono a compilare"**:
  comportamento corretto e intenzionale (test negativi, la mancata compilazione è il PASS).
  Vedi `docs/validation/00-inventario.md` §0.5.
- **`graph_engine_bandwidth_tb.v` "nessun verdetto PASS/FAIL"**: è un benchmark per
  progetto, non un test di correttezza. Vedi §0.3/§0.5 dell'inventario.
