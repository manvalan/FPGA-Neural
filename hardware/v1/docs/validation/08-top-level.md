# C.8 — Top-level (`spi_neuron_top.v`)

Data: 2026-09-04.

---

## 8.1 Mux `seq_busy`/dispatch legittimo, pin `data_ready_n`/`irq_n` — CERTIFICATO

Il meccanismo di mux `mux_nm_*` (che decide se `neuron_memory` è pilotato da
`layer_sequencer` durante un `RUN_NETWORK` o direttamente da `spi_engine` per un `START`
manuale) è già coperto da `sim/spi_neuron_top_runnetwork_tb.v` (un `START` a singolo layer
funziona ancora correttamente dopo un `RUN_NETWORK` precedente — "mux sanity"). I pin
`data_ready_n`/`irq_n` sono coperti da 4 test dedicati in `sim/spi_neuron_top_irq_tb.v`
(idle, run valido, run non valido, `RESET` pulisce `irq_n`). Entrambi pre-esistenti,
riverificati PASS in Fase 0.

**Verdetto: CERTIFICATO** per questi aspetti.

---

## 8.2 `SET_NET_TYPE` durante un run in corso — BUG-007 CONFERMATO END-TO-END, CRITICO

**Analisi strutturale**: il mux della Porta C dell'arbitro (righe 394-397) sceglie tra
`graph_engine` e `layer_sequencer` in modo **puramente combinazionale** sul valore corrente
di `net_type`. `rtl/spi_engine.v` accetta `SET_NET_TYPE` **incondizionatamente**, senza
alcun controllo su `graph_busy`/`seq_busy`. Il commento "mutually exclusive by
construction" (riga 390) copre solo l'AVVIO simultaneo dei due motori, non una scrittura
di `net_type` che arriva a metà di un run già avviato.

**Verificato end-to-end su SPI reale** (`sim/spi_neuron_top_bug007_mid_run_net_type_tb.v`,
stesso grafo valido già certificato in `spi_neuron_top_graph_tb.v`, stesse routine SPI
provate):

```
--- starting graph RUN_NETWORK, then immediately SET_NET_TYPE(dense) before it completes ---
after 30 polls: last_status=0x01 (bit0=busy) -- expected 0x01 stuck if the hang reproduces
RESULT: HANG CONFIRMED -- STATUS.busy stuck, no done/err after 30 polls (vs. ~12-25us normal completion time for this graph)
--- recovery check: RESET, then a legitimate legacy dense START ---
RECOVERY RESULT: RESET DOES recover the system -- a subsequent legitimate dense op completed normally (status=0x02 after 2 polls)
```

`STATUS.busy` resta bloccato dopo un `SET_NET_TYPE` inviato subito dopo un `RUN_NETWORK` in
modalità grafo, per un tempo enormemente superiore al normale completamento di quel grafo
(~2.35ms osservati in un run più lungo, vs ~12-25µs normali) — un hang reale, non un
rallentamento. Le transazioni SPI stesse continuano a funzionare (il `SET_NET_TYPE`
avversariale e i successivi poll di `STATUS` completano regolarmente); è specificamente il
motore grafo a restare bloccato, in attesa di un `ram_ready` che non arriva più tramite il
percorso del mux ormai scollegato.

**Recupero verificato**: un `RESET` durante l'hang riporta il sistema a uno stato
pienamente funzionante (una successiva operazione dense legittima completa normalmente).
Non è un blocco permanente — ma senza un `RESET` di ripiego lato host, il polling da solo
non si sbloccherebbe mai.

**Verdetto: NON CERTIFICATO.** Vedi `docs/validation/bugs.md` BUG-007 — severità CRITICA
insieme a BUG-005, per raggiungibilità diretta con due soli opcode SPI documentati in
sequenza ravvicinata, uno scenario host plausibile.

---

## 8.3 Verdetto complessivo C.8

| Sotto-aspetto | Verdetto |
|---|---|
| Mux `seq_busy` per dispatch legittimo | **CERTIFICATO** |
| Pin `data_ready_n`/`irq_n` | **CERTIFICATO** |
| `SET_NET_TYPE` durante un run in corso | **NON CERTIFICATO** — BUG-007 (CRITICO, confermato end-to-end, recupero via RESET verificato) |
