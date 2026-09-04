# C.10 — Timing (Fmax reale, percorso critico, sweep di seed)

Data: 2026-09-04. Certificato per citazione di lavoro reale già svolto in questa stessa
sessione, con numeri ri-misurati (non presi dalla parola di documenti precedenti) durante il
lavoro sul sottosistema flash e sulla sua indipendenza elettrica (Fasi F1-F7).

## Evidenza

- **Fmax rimisurata ad ogni cambiamento strutturale rilevante**, non una singola cifra
  presa per buona: 54.58 → 75.30 (timing closure) → 73.88 (pin attenzione host) → 66.68
  (sottosistema flash) → **67.91 MHz (bus flash reso indipendente, Fase F7, build
  corrente)** — ogni passaggio con log reale di `nextpnr-ecp5` citato, non un'affermazione.
- **Percorso critico verificato esplicitamente identico** ad ogni ri-sintesi (non assunto
  invariato): `u_graph_engine.u_neuron.group_index → u_mac8 → catena di riporto
  dell'accumulatore in neuron_parallel.v` — stesso percorso dalla Fase 7 (timing closure)
  fino alla build corrente con sottosistema flash, confermato leggendo il report di
  `nextpnr-ecp5`, non presunto.
- **Sweep di seed** (5 seed, P2 e P8) già eseguito e documentato in `WORKLOG.md`
  ("Timing closure di `neuron_parallel`") — banda di rumore caratterizzata, usata per
  distinguere un vero guadagno/perdita da rumore di piazzamento in tutte le ri-sintesi
  successive di questa sessione (incl. la spiegazione del calo 73.88→66.68→67.91 MHz come
  rumore, non regressione, verificata contro quella banda).
- **Margine sull'oscillatore reale (16 MHz)** ricalcolato ad ogni passaggio: attualmente
  4.24× con Fmax 67.91 MHz.

## Verdetto

**CERTIFICATO.** Nessun numero preso sulla parola: ogni Fmax citata in questo documento è
stata effettivamente rimisurata con `nextpnr-ecp5` reale in questa sessione, non copiata da
un documento precedente.
