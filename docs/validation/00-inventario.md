# Fase 0 — Inventario reale della repo

Data: 2026-09-04. Metodo: lettura diretta dei file, non delle descrizioni in WORKLOG.md o
nei datasheet. Ogni claim qui sotto è verificato con un comando citato, rieseguibile.

---

## 0.1 Struttura dei file

| Area | File | Righe totali |
|---|---|---|
| `rtl/*.v` | 20 file | 7016 |
| `sim/*_tb.v` (testbench) | 33 file | 12934 |
| `sim/*.v` non-tb (modelli/benchmark) | 4 file: `flash_model.v`, `psram_model.v`, `flash_latency_bench.v`, `top.v` | — |
| `tools/` | `fpga_benchmark.py`, `netasm/` (assembler+parser+cli+frames, con test suite propria), `pinout/gen_lpf.py`, `flash_catalog/oracle.py`, **`run_regression.py` (nuovo, questa fase)** | — |
| `docs/` | 4 documenti `.md` + 2 PDF | — |

**Elenco RTL completo**: `act_buffer.v`, `crc32.v`, `flash_copy_engine.v`,
`flash_slot_manager.v`, `graph_engine.v`, `int8_memory_access.v`, `layer_sequencer.v`,
`layer.v`, `mac_unit.v`, `mac8.v`, `mem_arbiter.v`, `memory_interface.v`, `memory_model.v`,
`neuron_memory.v`, `neuron_parallel.v`, `psram_controller.v`, `spi_engine.v`,
`spi_flash_master.v`, `spi_neuron_top.v`, `spi_slave.v`.

### Discrepanza doc↔codice: conteggio testbench

Il prompt di questa campagna cita "la regressione dichiarata (22 testbench)". Il conteggio
reale via `find sim -name "*_tb.v" | wc -l` è **33** (più 1 file benchmark mal nominato con
suffisso `_tb.v`, vedi §0.3) — il numero 22 è superato da fasi successive del progetto
(sottosistema flash e Tipo #2 grafo, aggiunti dopo). Non è un errore nel senso di un bug: è
un documento/prompt che descrive uno stato precedente. Il numero corrente verificato è 33.

---

## 0.2 Codice morto/orfano trovato

### `sim/top.v` — **DEAD, non compila contro l'RTL corrente**

```
$ iverilog -g2012 -o /tmp/topcheck.out rtl/neuron_parallel.v rtl/mac8.v rtl/mac_unit.v sim/top.v
sim/top.v:17: error: parameter `FRAC_BITS` not found in `top.dut`.
2 error(s) during elaboration.
```

`sim/top.v` istanzia `neuron_parallel` con `.DATA_WIDTH(16)` e `.FRAC_BITS(8)` — un residuo
della versione a virgola fissa Q8.8 del progetto, prima che fosse convertito a INT8 puro
(coerente con `WORKLOG.md`, Fase 6: "rimosso FRAC\_BITS e funzione q8\_8"). Il modulo
`neuron_parallel.v` corrente non ha più un parametro `FRAC_BITS`. Il file è tracciato in git
(`git log --oneline -- sim/top.v` → `d4ae241 test: validate parametric 32x4 layer with
parallelism 8`, un commit storico) ma **non è referenziato da nessun testbench, script, o
tool di questo repo** — non partecipa alla regressione, non compila. Non toccato in questa
fase (nessuna modifica, per policy §E del prompt di certificazione — la rimozione, se
voluta, è una decisione separata dall'analisi).

### Nessun altro modulo RTL orfano

Ogni file in `rtl/*.v` è raggiungibile da almeno un testbench (direttamente o
transitivamente) — vedi matrice §0.4. Nessun modulo istanziato da zero testbench e da
nessun altro modulo RTL.

### Due file "memory model" distinti — non un bug, ma nome ambiguo

`rtl/memory_model.v` (interfaccia generica `req/wr/addr/wdata/rdata` con `READ_LATENCY`
parametrico, usato solo da `sim/memory_interface_tb.v` per isolare `memory_interface.v` dal
timing reale della PSRAM) è un modulo diverso da `sim/psram_model.v` (interfaccia
pin-accurate `ce_n/oe_n/we_n/lb_n/ub_n`, usato da praticamente tutti i test di integrazione
reali). Non è un bug — sono stub di fedeltà diversa per scopi diversi — ma il nome simile
(`memory_model` vs `psram_model`) e la collocazione di uno stub-solo-per-test dentro `rtl/`
anziché `sim/` è una scelta organizzativa che vale la pena segnalare per chi legge la repo
la prima volta.

---

## 0.3 Convenzione di naming inconsistente: benchmark con suffisso `_tb.v`

`sim/graph_engine_bandwidth_tb.v` ha il suffisso `_tb.v` (come i 33 testbench veri) ma è in
realtà un **benchmark** — stampa numeri misurati (`edges/sec`, `bandwidth`), non ha verdetto
PASS/FAIL, per progetto (stesso stile dichiarato di `sim/flash_latency_bench.v`, che invece
**non** ha il suffisso `_tb.v` e quindi non viene raccolto insieme ai testbench veri da un
comando generico `find sim -name "*_tb.v"`). Questa incoerenza di naming ha causato una
classificazione errata al primo giro del regression runner (§0.5) — corretta dopo aver letto
l'intento dichiarato nell'header del file, non assumendolo.

---

## 0.4 Matrice modulo → testbench (istanziazione diretta)

Costruita via analisi statica delle istanziazioni (`^\s*modulo\s+(#\(|nomeistanza\s*\()`),
non a memoria.

| Modulo RTL | Testbench che lo istanziano direttamente |
|---|---|
| `act_buffer` | `act_buffer_tb` |
| `crc32_byte` (in `crc32.v`) | `crc32_tb` |
| `flash_copy_engine` | `flash_copy_engine_{erase,load,save}_tb` |
| `flash_slot_manager` | `flash_slot_manager_tb`, `flash_slot_manager_raw_tb` |
| `graph_engine` | `graph_engine_tb`, `graph_engine_guard_tb`, `graph_engine_bandwidth_tb` |
| `int8_memory_access` | 10 testbench (tutti quelli con path PSRAM reale) |
| `layer_sequencer` | `layer_sequencer_tb` |
| `layer` | `layer_tb`, `parametric_tb` |
| **`mac_unit`** | **nessuno — 0 istanziazioni dirette in `sim/`** |
| **`mac8`** | **nessuno — 0 istanziazioni dirette in `sim/`** |
| `mem_arbiter` | 4 testbench (i 4 test flash con path PSRAM) |
| `memory_interface` | 12 testbench |
| `memory_model` | `memory_interface_tb` (solo questo) |
| `neuron_memory` | `neuron_memory_tb`, `neuron_memory_multi_tb` |
| `neuron_parallel` | 5 testbench (incl. i 2 negativi, §0.5) |
| `psram_controller` | 13 testbench |
| `spi_engine` | `spi_engine_tb` |
| `spi_flash_master` | `spi_flash_master_tb` |
| `spi_neuron_top` | 5 testbench (`_tb`, `_graph_tb`, `_irq_tb`, `_runnetwork_tb`, `_flash_tb`) |
| `spi_slave` | `spi_slave_tb`, `spi_engine_tb` |

### Finding da riportare in C.1 (Datapath aritmetico)

**`mac_unit.v` e `mac8.v` non hanno un testbench unitario dedicato.** Sono esercitati solo
indirettamente, come sotto-componenti di `neuron_parallel` nei test di livello superiore
(`neuron_parallel_tb`, `neuron_parallel_saturation_bounds_tb`, ecc.). Questo significa che
un comportamento scorretto isolato di `mac_unit`/`mac8` (es. estensione di segno errata sul
prodotto INT8×INT8, prima dell'accumulo) sarebbe rilevabile solo se si propaga fino
all'uscita finale del layer con un pattern di input che lo renda visibile — non c'è un
oracolo che verifichi `mac_unit` da solo. **Non certificabile come "coperto" fino a C.1.**

---

## 0.5 Regressione: eseguita da zero con harness nuovo, non fidandosi del WORKLOG

**Non esisteva alcuno script di regressione riproducibile nella repo** prima di questa fase
— ogni precedente affermazione "N testbench, tutti PASS" in `WORKLOG.md` è stata prodotta
assemblando a mano la lista file `iverilog` per ciascun test, mai da un harness unico
rieseguibile. Questo è di per sé un gap reale (nessuna prova automatizzata, riproducibile,
del claim di regressione) — colmato creando **`tools/run_regression.py`**: risolve le
dipendenze di ogni testbench per analisi statica delle istanziazioni (non a memoria/elenco
scritto a mano), compila con `iverilog -g2012` ed esegue con `vvp`, classifica il risultato.

**Primo run**: 2 falsi negativi e 1 "sconosciuto" — non erano bug, erano un **blind spot del
mio stesso harness**, corretto leggendo il codice sorgente dei test incriminati (non
assumendo):
- `neuron_parallel_guard_negative_{degenerate,nonmultiple}_tb.v` sono **test negativi
  dichiarati**: il loro header dice esplicitamente "This file must FAIL TO
  COMPILE/ELABORATE. That failure is the test" — verificano che il guard
  `N_INPUTS % PARALLEL != 0` di `rtl/neuron_parallel.v:71-72` blocchi l'elaborazione
  istanziando un modulo inesistente (`neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL`)
  quando la condizione è violata. Il fallimento di compilazione **è** il PASS.
- `graph_engine_bandwidth_tb.v` è un benchmark (§0.3), nessun verdetto per progetto.

Corretto l'harness (whitelist esplicita per questi 3 casi, letta dal codice sorgente stesso
dei test, non inventata) e rilanciato:

```
$ python3 tools/run_regression.py
TOTAL: 34  PASS: 33  FAIL/ERROR: 0  OTHER/UNKNOWN: 1
```

**33/33 testbench reali PASS, 0 regressioni, 1 benchmark eseguito correttamente senza
verdetto (per progetto).** Il claim del WORKLOG ("tutti i testbench passano") è **confermato
vero** da un run indipendente e da zero — non solo creduto sulla parola.

`tools/netasm/tests/test_netasm.py` (20 test) verificato separatamente, anch'esso da zero:
**20/20 PASS**, invariato.

---

## 0.6 Osservazione preliminare, da verificare formalmente in C.1

Leggendo `rtl/neuron_parallel.v:70-73`, il guard elaboration-time è **un solo** controllo:

```verilog
if (N_INPUTS % PARALLEL != 0) begin : PARAMETER_ERROR_N_INPUTS_NOT_MULTIPLE_OF_PARALLEL
    neuron_parallel_requires_N_INPUTS_multiple_of_PARALLEL invalid_parameter_combination();
end
```

Il commento del progetto dice che questo guard copre **sia** "N_INPUTS non multiplo di
PARALLEL" **sia** il caso degenere "PARALLEL > N_INPUTS" (con `GROUPS=0`, hang documentato).
Ma matematicamente: se `N_INPUTS == 0`, allora `N_INPUTS % PARALLEL == 0` per qualunque
`PARALLEL != 0` — il guard **non scatta**, eppure `GROUPS = 0/PARALLEL = 0`, la stessa
condizione di hang che il guard dichiara di prevenire. **Non ancora verificato se
`N_INPUTS=0` sia un caso raggiungibile/rilevante nella pratica** (nessun layer con zero
ingressi ha senso semantico, ma nessun controllo esplicito lo esclude) — portato come
finding aperto da chiudere formalmente in C.1 con un test avversariale dedicato e un
oracolo indipendente, non certificato né come bug né come non-bug qui.

---

## 0.7 Artefatti fuori dal codice sorgente (non toccati)

- `docs/FPGANeuralDatasheet.pdf` e `docs/FPGANeuralDatasheetEN.pdf`: comparsi come file non
  tracciati, non generati da alcun processo di build di questo repo (il datasheet LaTeX vive
  in `DataSheet/`, una directory separata non versionata — vedi memoria di progetto).
  Probabile sottoprodotto del meccanismo di invio file usato in questa sessione. Non fanno
  parte della fonte di verità RTL/documentazione; non modificati né cancellati (non è una
  decisione di questa fase).
- `FPGA-Neural/` (progetto KiCad): non tracciato per policy di progetto pre-esistente
  (vedi memoria), non toccato.

---

## 0.8 Prossimi passi

Procedo con gli aspetti C.1–C.14 uno alla volta, ciascuno con: analisi statica, test
avversari con oracolo indipendente (§A.1/A.3), verdetto tracciato. Il finding aperto di
§0.6 (`N_INPUTS=0`) va chiuso in C.1. `mac_unit`/`mac8` senza test unitario (§0.4) va colmato
in C.1 prima di poter certificare il datapath aritmetico.
