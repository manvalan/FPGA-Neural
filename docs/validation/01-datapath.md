# C.1 — Datapath aritmetico (`mac_unit`, `mac8`, `neuron_parallel`)

Data: 2026-09-04. Chiude i due punti aperti in Fase 0 (§0.4 copertura `mac_unit`/`mac8`,
§0.6 gap del guard `N_INPUTS=0`).

---

## 1.1 `mac_unit.v` — CERTIFICATO

**Metodo**: test esaustivo, non a campione. `mac_unit` è puramente combinazionale
(`x`, `w`, `acc_in` → `acc_out = acc_in + sign_extend(x*w)`), a `DATA_WIDTH=8` esistono
esattamente 256×256=65536 combinazioni possibili di `(x,w)` — tutte esercitate, non un
sottoinsieme casuale.

**Oracolo**: `tools/validation/mac_oracle.py`, reimplementazione Python indipendente
dell'aritmetica complemento-a-due da zero (non trascritta dall'RTL) — auto-verificata contro
6 casi derivati a mano prima di essere usata come oracolo per chiunque altro
(`python3 tools/validation/mac_oracle.py` → `ALL SELF-CHECKS PASSED`).

**Test**: `sim/mac_unit_tb.v`, due batterie:
1. Le 65536 combinazioni esaustive di `(x,w)`, `acc_in=0` (l'uso reale in `mac8.v`, dove
   `acc_in` è cablato a 0 per ogni istanza `mac_unit`).
2. 486 vettori a `acc_in` diverso da zero — inclusi i 4 valori limite (`0`, `±2³¹`, `±2³⁰`) e
   i 4 angoli di grandezza massima del prodotto (`±128×±128`, `±128×∓127`) — a copertura del
   **contratto di porta completo** del modulo, non solo di come viene usato oggi.

```
$ iverilog -g2012 -o /tmp/mac_unit_tb.out rtl/mac_unit.v sim/mac_unit_tb.v && vvp /tmp/mac_unit_tb.out
ALL TESTS PASSED (66022 vectors, 0 mismatches against independent Python oracle)
```

**Verdetto: CERTIFICATO.** 66022/66022 vettori, 0 mismatch, copertura esaustiva sullo
spazio degli input a INT8. Nessuna riserva.

---

## 1.2 `mac8.v` — adder tree bilanciato — CERTIFICATO

**Metodo**: `mac8.v` non aveva alcun test unitario dedicato (Fase 0, §0.4) — solo copertura
indiretta a un singolo `PARALLEL` tramite `neuron_parallel_tb.v`. Un bug di cablaggio
dell'albero (linea scambiata/duplicata/persa) a un `PARALLEL` diverso da quello usato dai
test esistenti sarebbe passato inosservato.

**Test**: `sim/mac8_tree_tb.v`, verificato a **PARALLEL=2, 8 (il default/omonimo del modulo)
e 32** — gli estremi realmente usati nei benchmark del progetto
(`docs/FPGA-Neural-Datapatch-Benchmark.md`), non un solo valore a piacere. Tre famiglie per
ciascun `PARALLEL` (939 vettori totali):
1. **Strutturale/avversariale**: `x=[1..PARALLEL]`, `w=1`, ordine sia ascendente che
   invertito. La somma attesa (`PARALLEL×(PARALLEL+1)/2`) torna corretta **solo se ogni
   linea è sommata esattamente una volta** — un modo efficace di scoprire un cablaggio
   scambiato che un test casuale potrebbe non notare (uno scambio+una linea persa possono
   annullarsi per caso su input casuali, mai su questo pattern esatto).
2. **300 coppie INT8 casuali per `PARALLEL`**, `acc_in` variato su un range realistico —
   riproduce il collegamento reale (`neuron_parallel.v`: `mac8.acc_in = acc`, l'accumulatore
   che cresce gruppo dopo gruppo, **non** cablato a 0 come si potrebbe erroneamente
   assumere).
3. **Avversariale**: tutte le linee al prodotto di grandezza massima (`±16384`/`∓16256`)
   simultaneamente, con `acc_in` ai bordi di `ACC_WIDTH=32` — conferma che l'eventuale
   wraparound complemento-a-due dell'albero è ben definito (non X/indefinito), pur essendo
   una magnitudine ben oltre quanto un layer reale (`N_INPUTS≤256`) accumulerebbe mai
   (dichiarato, non presentato come condizione operativa reale).

```
$ iverilog -g2012 -o /tmp/mac8_tb.out rtl/mac_unit.v rtl/mac8.v sim/mac8_tree_tb.v && vvp /tmp/mac8_tb.out
ALL TESTS PASSED (939 vectors across PARALLEL=2/8/32, 0 mismatches against independent Python oracle)
```

**Verdetto: CERTIFICATO** a PARALLEL=2/8/32. **Riserva dichiarata**: non verificato ad ogni
altro `PARALLEL` usato nel progetto (es. 4, 16) — il rischio residuo è basso (la costruzione
dell'albero è generica via `$clog2(PARALLEL)`, identica per ogni potenza di due, e 3 valori
distinti già la esercitano a profondità diverse: 1, 3, 5 livelli), ma non è "esaustivo su
tutti i PARALLEL" nello stesso senso in cui §1.1 lo è su `(x,w)`.

---

## 1.3 Saturazione INT8 / attivazione — CERTIFICATO CON RISERVA (test pre-esistente, riverificato)

`sim/neuron_parallel_saturation_bounds_tb.v` (già presente prima di questa campagna) copre
gli 8 valori di bordo dichiarati nel task di timing-closure (126, 127, 128, 129, -128, -129,
-1, 0) per `ACT_NONE` e `ACT_RELU`, con oracolo **calcolato a mano** (non derivato dal
codice) — verificato bit-esatto per confermare che la riscrittura a bit-test delle
comparazioni di saturazione (da confronti aritmetici `>127`/`<-128` a riduzioni AND/OR)
durante la timing closure non ha alterato il comportamento.

Ri-eseguito da zero in questa campagna (non solo citato dal WORKLOG): **PASS**, invariato.

**Riserva**: il test usa `N_INPUTS=PARALLEL=1` (una sola corsia MAC), per raggiungere ogni
valore di bordo esattamente con una singola tripla `(x,w,bias)` scelta a mano. Non esercita
l'interazione tra l'albero a più corsie (§1.2, ora certificato separatamente) e la
saturazione finale nello stesso run — cioè non c'è un test che porti un accumulo
multi-gruppo/multi-corsia esattamente a uno di questi bordi. Rischio basso (la saturazione
opera sul valore finale di `acc+bias`, indipendentemente da come quel valore è stato
costruito), ma non è stato verificato esplicitamente in questa campagna.

---

## 1.4 Guard `N_INPUTS % PARALLEL != 0` — CERTIFICATO CON RISERVA GRAVE (BUG-002 confermato)

### Cosa funziona (già coperto, riverificato)

`sim/neuron_parallel_guard_negative_{nonmultiple,degenerate}_tb.v`: due test negativi che
provano che il guard blocca l'elaborazione per `N_INPUTS % PARALLEL != 0` (incl. il caso
degenere "PARALLEL > N_INPUTS" per N_INPUTS≥1, dove il resto della divisione coincide con
N_INPUTS stesso, quindi è comunque non-zero). Rieseguiti da zero: **entrambi falliscono a
compilare come previsto** — è il PASS.

### BUG-002 — confermato reale, su ENTRAMBI i piani di verifica (non solo ipotizzato)

**Il finding aperto in Fase 0 §0.6 era corretto nell'ipotesi ma la mia prima verifica
empirica era sbagliata per un bug nella MIA testbench** — narrativa completa perché è
rilevante per la fiducia nel resto della campagna:

1. Primo tentativo: un test con `repeat(50) @(posedge clk); if (done) ... else "HANG"` ha
   riportato "hang" per `N_INPUTS=0`. **Metodologicamente invalido**: `done` è un impulso di
   **un solo ciclo** (`rtl/neuron_parallel.v:207/227`, `done <= 0` incondizionato subito dopo
   averlo asserito), quindi un controllo tardivo e singolo di `done` mostra sempre 0 **anche
   quando tutto funziona correttamente** — confermato riproducendo lo stesso falso "HANG" su
   una config nota-buona (`N_INPUTS=2, PARALLEL=2`, valida, mai dovrebbe fallire).
2. Corretto il metodo: osservare `done` **ogni ciclo** (non un controllo singolo tardivo).
   Sulla config nota-buona, ora **PASS correttamente** (`done` pulsa al ciclo giusto, `y=5`
   coerente col calcolo a mano). Sul caso `N_INPUTS=0`: **confermato, `busy` non si alza mai
   e `done` non pulsa mai in 200 cicli** — non è più un'ipotesi, è un fatto osservato con un
   metodo verificato corretto prima su un caso di controllo.
3. **Causa architetturale trovata** (non solo il sintomo): `x_bus`/`w_bus` sono dichiarati
   `[DATA_WIDTH*N_INPUTS-1:0]` — per `N_INPUTS=0` questo è `[-1:0]`, che **non collassa a
   larghezza zero**: sia Icarus che Yosys lo trattano come un vettore a **2 bit** reali
   (larghezza = |MSB-LSB|+1 = |-1-0|+1 = 2), lasciato **non pilotato**. Confermato dai
   warning di Yosys stesso: `Wire ...x_bus[1] is used but has no driver` (×2 per x_bus/w_bus).
4. **Confermato anche in sintesi reale**, non solo in simulazione (§A.4): `yosys synth_ecp5`
   elabora `neuron_parallel #(.N_INPUTS(0), .PARALLEL(2))` con **0 problemi segnalati** dal
   CHECK pass — lo stesso silenzio che permette al guard di non scattare in simulazione si
   ripete identico sul secondo piano di verifica indipendente.

**Test di regressione permanente**: `sim/neuron_parallel_bug002_n_inputs_zero_tb.v` —
riproduce il sintomo esatto in modo deterministico, PASSA oggi confermando che il bug è
ancora presente (non è un'asserzione che questo comportamento sia desiderabile — il file
stesso lo dichiara esplicitamente in testa, con l'istruzione di riscriverlo, non
allentarlo, quando il bug verrà corretto).

**Verdetto: NON CERTIFICATO per `N_INPUTS=0`.** Il guard copre correttamente ogni
combinazione `N_INPUTS≥1` non multipla di `PARALLEL` (incl. il caso degenere
`PARALLEL>N_INPUTS≥1`), ma **non copre `N_INPUTS=0`**, che produce un `start` silenziosamente
inefficace (non l'hang "busy alto per sempre" descritto nel commento originale del guard —
un sintomo diverso, osservato per la prima volta in questa campagna) su entrambi i piani di
verifica. Vedi `docs/validation/bugs.md` BUG-002 per severità e fix proposto.

---

## 1.5 Verdetto complessivo C.1

| Sotto-aspetto | Verdetto |
|---|---|
| `mac_unit.v` | **CERTIFICATO** (esaustivo, 66022 vettori, 0 riserve) |
| `mac8.v` (adder tree) | **CERTIFICATO** (939 vettori, PARALLEL=2/8/32; riserva: non esaustivo su ogni PARALLEL) |
| Saturazione/attivazione | **CERTIFICATO CON RISERVA** (test pre-esistente valido; riserva: non testato in combinazione con l'albero multi-corsia) |
| Guard `N_INPUTS%PARALLEL` | **NON CERTIFICATO per N_INPUTS=0** — BUG-002 confermato su sim + sintesi reale |

**Il datapath aritmetico di base (moltiplicazione, estensione di segno, albero di somma) è
solido** — certificato esaustivamente dove possibile. **Il guard di protezione attorno ad
esso ha un buco reale e confermato**, non un rischio teorico: `N_INPUTS=0` produce hardware
sintetizzabile (0 errori Yosys) che silenziosamente non fa nulla quando l'host tenta di
avviarlo.
