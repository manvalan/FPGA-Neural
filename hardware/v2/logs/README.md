# Formato dei log V2

Regola non negoziabile (`docs/v2-description.md` §25-29): ogni attività
significativa (modifica, simulazione, sintesi, benchmark, decisione, errore)
deve essere registrata. Nessun log viene mai sovrascritto o troncato — solo
append. Nessun ID esperimento (`EXP-XXXX`) o decisione (`DEC-XXXX`) viene mai
riutilizzato, anche se il risultato è un FAIL.

## File

- `development.log` — log principale di sviluppo, un'entry per ogni sessione
  di lavoro/milestone (creazione file, refactor, avanzamento roadmap).
- `architecture.log` — decisioni e note di architettura a grana fine (non
  scelte finali — quelle vanno in `decisions.log` — ma esplorazioni,
  alternative considerate, vincoli scoperti).
- `simulation.log` — ogni run di simulazione (Icarus/Verilator): test,
  vettori, cicli, PASS/FAIL, confronto bit-exact con V1, stall/memory-wait.
- `synthesis.log` — ogni run Yosys: LUT/FF/DSP/BRAM, warning, problemi CHECK.
- `timing.log` — ogni run nextpnr-ecp5: Fmax, percorso critico, WNS/TNS se
  disponibili. Fmax "ufficiale" di una configurazione = solo da qui, mai da
  simulazione o stima.
- `benchmark.log` — tabelle di confronto per configurazione (Fmax, MAC/cycle,
  cycles/neuron, utilization, ecc.), sempre con etichetta
  THEORETICAL/SIMULATED/SYNTHESIZED/POST-P&R.
- `decisions.log` — decisioni architetturali importanti, formato `DEC-XXXX`
  (vedi `docs/v2-description.md` §27).
- `experiments.log` — registro principale, un `EXP-XXXX` per ogni esperimento
  end-to-end (config → sim/synth/timing → risultato), rimanda a
  `reports/experiments/EXP-XXXX/`.
- `errors.log` — errori/bug/regressioni incontrati durante lo sviluppo V2
  stesso (non i bug V1, già chiusi in `hardware/v1/docs/validation/bugs.md`).

## Campi minimi per entry (§26)

```
timestamp, experiment_id (se applicabile), git_commit, session/agent,
module, configuration, action, reason, command, result, errors, decision,
next_action
```

Per synthesis/timing aggiungere: LUT, FF, DSP, BRAM, Fmax, critical path,
WNS/TNS. Per simulazione: test, vectors, cycles, PASS/FAIL, bit-exact result,
stall cycles, memory wait, utilization.
