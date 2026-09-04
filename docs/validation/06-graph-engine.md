# C.6 — Motore grafo (`graph_engine.v`, `act_buffer.v`)

Data: 2026-09-04.

---

## 6.1 Gather, padding, guard `src_id<out_id` — CERTIFICATO (test pre-esistenti, riverificati)

`sim/graph_engine_tb.v` (grafo calcolato a mano, §3 dell'esempio del manuale, con verifica
diretta del contenuto di `act_buffer` via riferimento gerarchico, non solo dell'output
finale) e `sim/graph_engine_guard_tb.v` (4 test: `src_id>=out_id` auto-riferimento,
`out_id>=N_TOTAL`, `n_conn_padded==0`, percorso di recovery dopo un `err`) — entrambi
pre-esistenti, riverificati PASS in Fase 0. Copertura solida su happy-path e sui casi
avversari già identificati dal progetto.

**Verdetto: CERTIFICATO** per questi aspetti (copertura pre-esistente adeguata).

---

## 6.2 `num_neurons_graph=0` — stessa causa radice di BUG-005, ma protezione incidentale diversa

**Analisi strutturale**: `neuron_idx` (`rtl/graph_engine.v:159`) è un registro a 16 bit
PIENI, e la condizione di terminazione (righe 527/561)
`neuron_idx==num_neurons_graph-16'd1` per `num_neurons_graph=0` avvolge a `65535` — un
valore che il contatore RAGGIUNGE naturalmente, stessa struttura esatta di BUG-005
(`layer_idx`). Stessa causa radice: nessun guard su `num_neurons_graph`, né a compile-time
né a runtime.

**Verificato empiricamente, con una riserva esplicita**: `sim/graph_engine_bug006_zero_neurons_probe_tb.v`,
finestra di osservazione limitata a 5000 cicli (**non fatto girare fino a completamento
reale** — fino a 65536 iterazioni con la logica di gather di questo modulo, più costosa per
iterazione del semplice dispatch di `layer_sequencer`, sarebbe stato impraticabile per il
budget di tempo di questa campagna; dichiarato come limite esplicito, non nascosto).

```
RESULT: err fired at cycle 58 (neuron_idx=0) -- the src_id<out_id/N_TOTAL guard caught
the garbage descriptor data before completion.
```

**Differenza da BUG-005**: `graph_engine` possiede già un guard **a runtime, per-edge**
(`src_id>=out_id` o `out_id>=N_TOTAL` → `err`, §6.1) che **non è stato progettato per
proteggere da `num_neurons_graph=0`** ma **lo cattura come effetto collaterale**: con un
pattern di dati "spazzatura" non banale (non tutto a zero, un pattern a rampa), il guard
esistente ha fermato l'esecuzione dopo sole 58 cicli, al primissimo neurone fasullo letto,
molto prima di avvicinarsi alle 65536 iterazioni possibili. `layer_sequencer.v` **non ha
alcun guard equivalente** — da qui la severità molto più alta di BUG-005.

**Non è una garanzia**: questo test usa UN pattern di dati specifico. Non è stato
dimostrato che OGNI possibile contenuto PSRAM causi un arresto altrettanto rapido — esiste
in linea di principio un pattern di dati "sfortunato" che rispetti `src_id<out_id` e
`out_id<N_TOTAL` per molte iterazioni consecutive prima di violarli (o non violarli mai, se
i byte casuali formano per caso una sequenza monotona valida) facendo procedere
l'esecuzione molto più a lungo. Il buco strutturale (nessun guard esplicito su
`num_neurons_graph`) resta reale.

**Verdetto: NON CERTIFICATO per `num_neurons_graph=0` in senso assoluto** (stesso buco
strutturale di BUG-005), **ma il rischio pratico osservato è marcatamente più basso**
grazie al guard esistente per altri scopi. Non registrato come nuovo bug allo stesso
livello di severità di BUG-005 — vedi `docs/validation/bugs.md` per la voce dedicata a
severità ridotta (INFO/BASSA, non CRITICA), con la riserva sulla mancata verifica
esaustiva su ogni pattern di dati.

---

## 6.3 Verdetto complessivo C.6

| Sotto-aspetto | Verdetto |
|---|---|
| Gather, padding, guard `src_id<out_id`/`out_id<N_TOTAL`/`n_conn_padded==0` | **CERTIFICATO** |
| `num_neurons_graph=0` | **NON CERTIFICATO in senso assoluto**, rischio pratico basso osservato (guard esistente incidentale), non equiparato a BUG-005 |
