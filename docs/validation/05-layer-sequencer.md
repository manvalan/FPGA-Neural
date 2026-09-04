# C.5 — Sequencer dense (`layer_sequencer.v`)

Data: 2026-09-04.

---

## 5.1 Catena layer, ping-pong, busy/done — CERTIFICATO (test pre-esistente, valido)

`sim/layer_sequencer_tb.v` (pre-esistente, riverificato in Fase 0) copre un run a 2 layer
con verifica campo-per-campo del descrittore decodificato (`nm_w_base`, `nm_bias_addr`,
`nm_x_base`, `nm_activation`, `nm_n_inputs`, `nm_n_neurons`), e in modo particolarmente
solido: **verifica l'indirizzo del buffer ping-pong usato per layer 1, non solo il valore**
(conferma che layer 1 legge dal buffer che layer 0 ha effettivamente scritto — il punto
reale dello schema ping-pong, non solo che "un" buffer sia stato usato). Verifica anche che
`seq_busy` resti asserto per l'intero run a 2 layer (non cada tra un layer e l'altro) e che
`seq_done` pulsi esattamente una volta, dopo l'ULTIMO layer (un `nm_done` intermedio non deve
attivarlo).

**Verdetto: CERTIFICATO** per la catena a `run_num_layers` valido (test singolo ma
sufficientemente rigoroso nel verificare indirizzi, non solo valori).

---

## 5.2 `run_num_layers=0` — BUG-005 CONFERMATO, CRITICO

**Ipotesi**, per analogia col guard mancante già visto in BUG-002/003/004: `run_num_layers`
è documentato "1..N_LAYERS" ma **non ha alcun guard**, né a compile-time né a runtime.
`layer_idx` (`rtl/layer_sequencer.v:121`) è però un registro a **8 bit pieni** (non ristretto
a 1 bit come il `group_index` di BUG-002) — la condizione di terminazione
`layer_idx==num_layers_reg-1` per `num_layers_reg=0` avvolge a `layer_idx==255`, un valore
che il contatore RAGGIUNGE naturalmente contando da 0. Ipotesi: non un hang, ma
un'esecuzione di 256 layer fasulli.

**Verificato empiricamente** (`sim/layer_sequencer_bug005_zero_layers_tb.v`, `neuron_memory`
sostituito da uno stub minimale che completa istantaneamente, per isolare il solo
comportamento di sequenziamento):

```
RESULT: run_num_layers=0 completed after 21761 cycles -- dut.layer_idx ended at 255
```

**Confermata l'ipotesi**: non un hang. Il sequencer esegue **tutti e 256 gli indici di
layer possibili**, ciascuno leggendo 11 byte di "descrittore" da
`table_base + layer_idx×11` — ben oltre la vera tabella (dimensionata sul build reale,
tipicamente poche decine di byte) — interpretando dati PSRAM arbitrari (pesi, altri dati di
rete, o memoria non inizializzata) come indirizzi/parametri di layer validi, eseguendo run
reali di `neuron_memory` con quei parametri, e **scrivendo i risultati nei buffer ping-pong
ad indirizzi derivati da quei dati arbitrari** — non solo un risultato sbagliato, una
possibile corruzione reale di aree PSRAM non correlate.

**Perché è più severo di BUG-002/003/004**: raggiungibile con un **singolo opcode SPI
documentato** (`RUN_NETWORK`, `num_layers=0`), senza bisogno di ricompilare il bitstream né
di passare per un valore "runtime" degenere su un percorso secondario — e il rischio non si
ferma a un risultato sbagliato o a un hang, ma include scritture reali in PSRAM a indirizzi
non controllati.

**Nota correlata (non testata separatamente, stesso meccanismo)**: `run_num_layers` >
`N_LAYERS` (il massimo di build) presumibilmente ha lo stesso problema in forma più
limitata — nessun guard impedisce di leggere oltre la tabella reale anche per valori
"quasi validi" ma superiori al massimo di build. Non verificato con un test dedicato in
questa fase (stessa causa radice di §5.2, non una scoperta separata).

**Verdetto: NON CERTIFICATO per `run_num_layers=0` (e probabilmente per valori
`>N_LAYERS`).** Vedi `docs/validation/bugs.md` BUG-005 (severità CRITICA — unico bug di
questa campagna finora classificato come tale, per raggiungibilità diretta via protocollo
host documentato e rischio di corruzione dati reale, non solo hang o risultato sbagliato).

---

## 5.3 Verdetto complessivo C.5

| Sotto-aspetto | Verdetto |
|---|---|
| Catena layer, ping-pong, busy/done (valori validi) | **CERTIFICATO** |
| `run_num_layers=0` | **NON CERTIFICATO** — BUG-005 (CRITICO, causa isolata con certezza) |
