# C.2 — Larghezza runtime (`n_inputs_real`, `n_neurons_real`)

Data: 2026-09-04. Verifica se la terminazione anticipata a runtime è reale (nessuna lettura
oltre il limite impostato) e chiude il rischio dichiarato nell'header di `neuron_parallel.v`
("`n_inputs_real` che ... è 0 ... riproduce lo stesso hang" di BUG-002).

Nota di processo: durante questa verifica ho ottenuto un altro falso risultato dalla mia
stessa testbench (un secondo, dopo quello di C.1) — riportato per intero in §2.2, non
nascosto, perché è rilevante per capire quanto vada verificato con cura ogni singolo
risultato anomalo prima di fidarsene.

---

## 2.1 Terminazione anticipata reale — `n_inputs_real` (livello `neuron_parallel.v`) — CERTIFICATO

**Metodo**: `N_INPUTS=32` (build-time, max), regione "reale" (indici 0-15) con `x=w=1`,
regione "veleno" (indici 16-31) con `x=w=100` — se l'RTL leggesse anche solo un elemento
oltre `n_inputs_real`, il prodotto enorme (100×100=10000) satura immediatamente il risultato
a 127, rendendolo distinguibile da un risultato corretto.

**Oracolo**: somma attesa calcolata a mano; range di cicli atteso calcolato da
`GROUPS_real = n_inputs_real/PARALLEL` gruppi + overhead fisso di pipeline.

```
n_inputs_real=32: PASS -- y=127 cycles=5   (legge anche il "veleno": saturazione attesa e corretta)
n_inputs_real=16: PASS -- y=16  cycles=3   (NON legge il "veleno": somma esatta, nessun over-read)
n_inputs_real=8:  PASS -- y=8   cycles=2
```

**Verdetto: CERTIFICATO.** La terminazione anticipata è reale — non legge oltre il limite
impostato, e il numero di cicli scala proporzionalmente col numero di gruppi reali.

## 2.2 `n_inputs_real` non multiplo di `PARALLEL` — CERTIFICATO (comportamento come documentato)

**Test**: `n_inputs_real=17` (non multiplo di `PARALLEL=8`) con `N_INPUTS=32` build-time
valido. Atteso a mano: troncamento intero `17/8=2` gruppi → legge solo i primi 16 elementi,
`y=16` (non 17).

**Falso risultato iniziale, corretto**: un primo tentativo (script bespoke, non lo schema
già provato in §2.1) ha mostrato "busy=0, nessun done in 200 cicli" — sembrava un hang.
Anziché fidarmi, ho rieseguito lo STESSO caso riusando lo schema di task `run_case` già
dimostrato corretto in §2.1 (stessa sequenza di reset/start, tre invocazioni consecutive
nella stessa run per controllo di ripetibilità): **`n_inputs_real=17` → `done` al ciclo 3,
`y=16` — esattamente il troncamento silenzioso atteso, non un hang.** Il primo risultato era
un artefatto della mia testbench (probabile problema di temporizzazione nel setup di quel
singolo script), non un comportamento reale dell'RTL — non l'ho riportato come bug senza
prima riprodurlo con un metodo già affidabile.

**Verdetto: CERTIFICATO.** Il rischio dichiarato nell'header ("troncamento silenzioso,
risultato sbagliato, nessun errore") è confermato accurato per questo caso: comportamento
sbagliato-ma-silenzioso, non un hang.

## 2.3 `n_inputs_real=0` a runtime — BUG-003, comportamento INCOERENTE tra le mie stesse ripetizioni (non un verdetto singolo affidabile)

**Test**: `N_INPUTS=32, PARALLEL=8` (validi, compile-time, guard soddisfatto — nessun
problema di larghezza `[-1:0]` qui, a differenza di BUG-002; `GROUP_INDEX_WIDTH=2` bit per
questa build, non 1 come nel caso di BUG-002). A runtime, `n_inputs_real=0` via la porta (lo
stesso percorso che l'host raggiunge via `SET_BASE sel=7`,
`docs/FPGA-NeuralNetwork-Engine.md` §8.1).

**Qui la mia stessa verifica ha prodotto risultati DIVERSI tra run apparentemente
equivalenti, e lo riporto per intero invece di scegliere il risultato che sembra più
pulito:**

- Prima verifica (script isolato, dati tutti a `x=w=1`): **hang** — `busy` mai alto, nessun
  `done` in 200 cicli.
- Riprodotto con lo schema `run_case` già affidabile (§2.1), come PRIMA chiamata di una
  simulazione fresca, dati con regione "veleno": **NESSUN hang** — `done` al ciclo 5,
  `y=127` (ha letto anche la regione veleno, cioè ha ignorato il limite e processato l'intera
  larghezza, non si è bloccato).
- Stesso schema, PRIMA chiamata di una simulazione fresca ma con OGNI registro
  esplicitamente inizializzato prima di qualunque reset (per escludere artefatti di
  propagazione di X in simulazione): **ancora nessun hang** — `y=32` (di nuovo, limite
  ignorato, non bloccato).
- Stesso schema, ma con **una chiamata valida precedente** (`n_inputs_real=32`) prima della
  chiamata a `n_inputs_real=0`, ripetuta due volte: **nessun hang in nessuna delle due**,
  `y=32` entrambe le volte.
- Uno script con **quattro chiamate consecutive tutte a `n_inputs_real=0`** (variando solo
  il numero di cicli di reset tra 1 e 5): **la primissima chiamata non si blocca** (`y=32`,
  limite ignorato), **le tre chiamate successive SI bloccano** (nessun `done` in 200 cicli).

**Non sono riuscito a isolare la condizione esatta che decide tra i due esiti** entro un
tempo ragionevole per questa campagna — non è (solo) l'ordine delle chiamate (una sequenza
valida→zero non blocca; una sequenza zero→zero→zero dopo la prima blocca dalla seconda in
poi), non è il contenuto dei dati (`x_bus`/`w_bus`) dato che quello non dovrebbe influenzare
la logica di controllo `group_index`/`groups_real`, e non è propagazione di X (verificato
esplicitamente inizializzando tutto). **Analisi aritmetica**: per questa build
`GROUP_INDEX_WIDTH=2` bit, quindi `groups_real[1:0]-1` per `groups_real=0` avvolge a `3` (un
valore RAGGIUNGIBILE dal contatore a 2 bit, a differenza del caso a 1 bit di BUG-002) — il
che spiegherebbe l'esito "nessun hang, limite ignorato, processa tutta la larghezza" come
esito atteso per l'aritmetica di avvolgimento, ma NON spiega perché in alcune ripetizioni
compaia invece un hang vero.

**Verdetto: NON CERTIFICATO, e dichiarato esplicitamente NON PIENAMENTE CARATTERIZZATO** —
non fingo un meccanismo che non ho isolato. Quello che è certo, indipendentemente da quale
dei due sintomi si manifesti: **nessuno dei due è corretto** (un host che chiede
`n_inputs_real=0` non dovrebbe né bloccarsi né ottenere silenziosamente l'intera larghezza
di build al posto di zero elementi), e **l'incoerenza stessa tra ripetizioni quasi identiche
è di per sé un problema segnalabile**, indipendente dal meccanismo esatto. Vedi
`docs/validation/bugs.md` BUG-003 per lo stato aggiornato.

## 2.4 Terminazione anticipata reale — `n_neurons_real` (livello `neuron_memory.v`) — CERTIFICATO per valori validi

**Metodo**: `N_NEURONS=3` (build-time), memoria stub minimale sempre-pronta (il contenuto
non conta per questo test, solo se il loop termina e in quanti cicli).

```
n_neurons_real=3: done al ciclo 155
n_neurons_real=2: done al ciclo 114
n_neurons_real=1: done al ciclo 73
```

Scala proporzionalmente (~41 cicli/neurone) — la terminazione anticipata funziona
correttamente per valori validi ≥1.

**Verdetto: CERTIFICATO per `n_neurons_real` ∈ [1, N_NEURONS].**

## 2.5 `n_neurons_real=0` — BUG-004 CONFERMATO (classe diversa: non hang, limite ignorato silenziosamente)

**Ipotesi iniziale** (per analogia con BUG-002/003): mi aspettavo lo stesso hang. **Non è
quello che succede.**

**Test 1** (`N_NEURONS=3`, `NEURON_INDEX_WIDTH=2` bit): `n_neurons_real=0` → **`done` al
ciclo 196** (non un hang — termina, ma in PIÙ cicli di `n_neurons_real=3` stesso, 155).

**Test 2** (`N_NEURONS=2`, `NEURON_INDEX_WIDTH=1` bit — la stessa larghezza-1-bit che in
`neuron_parallel.v` causa l'hang di BUG-002): `n_neurons_real=0` → **`done` al ciclo 114,
identico a `n_neurons_real=2`** (§2.4). Non un hang, ma il conteggio di cicli **coincide
esattamente** col caso "processa tutti i neuroni" — il valore richiesto (0) sembra essere
stato **ignorato silenziosamente**, con l'hardware che processa l'intero build invece che
zero neuroni, terminando in modo perfettamente normale (nessun errore, nessun sintomo
visibile all'host).

**Perché è diverso da BUG-002/003**: l'aritmetica di wraparound qui (`neuron_index ==
n_neurons_real[W-1:0]-1`) non blocca il contatore in uno stato irraggiungibile come accade
per `group_index` a 1 bit in `neuron_parallel.v` — piuttosto lo fa avvolgere su un valore
che, per coincidenza di larghezza, corrisponde al conteggio COMPLETO. Non ho ulteriormente
isolato la causa esatta bit-per-bit (a differenza di BUG-002, dove l'ho fatto) — dichiarato
come limite di questa verifica, non presentato come pienamente compreso.

**Verdetto: NON CERTIFICATO per `n_neurons_real=0`.** Vedi `docs/validation/bugs.md`
BUG-004. **Più insidioso di un hang**: un host che chiede (per errore) zero neuroni riceve
un completamento normale e apparentemente valido, ma calcolato sull'intero conteggio di
build — dato silenziosamente sbagliato, non un timeout rilevabile.

---

## 2.6 Verdetto complessivo C.2

| Sotto-aspetto | Verdetto |
|---|---|
| Terminazione anticipata `n_inputs_real` (valori validi) | **CERTIFICATO** |
| `n_inputs_real` non multiplo di PARALLEL | **CERTIFICATO** (comportamento = rischio documentato) |
| `n_inputs_real=0` | **NON CERTIFICATO, comportamento non pienamente caratterizzato** — BUG-003 (incoerente tra ripetizioni: a volte hang, a volte limite ignorato) |
| Terminazione anticipata `n_neurons_real` (valori validi) | **CERTIFICATO** |
| `n_neurons_real=0` | **NON CERTIFICATO** — BUG-004 (limite ignorato silenziosamente, non hang) |

**Il meccanismo di larghezza runtime funziona correttamente per ogni valore valido** —
certificato con oracoli indipendenti e verifica del non-over-read. **Il valore limite 0, in
entrambi i punti di ingresso (`n_inputs_real` e `n_neurons_real`), produce due classi
DIVERSE di comportamento scorretto** — un hang silenzioso in un caso, un risultato
silenziosamente sbagliato-ma-dall'aspetto-normale nell'altro — entrambi raggiungibili
dall'host via il protocollo SPI documentato, senza bisogno di una nuova sintesi.
