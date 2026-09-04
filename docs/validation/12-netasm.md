# C.12 — `netasm` (host, assemblatore pseudo-assembly → byte)

Data: 2026-09-04.

## Evidenza

`tools/netasm/tests/test_netasm.py` — rieseguito da zero in Fase 0 di questa campagna
(non preso dalla parola): **20/20 PASS**. Copertura, verificata leggendo i nomi dei test
(`tests/test_netasm.py`), non solo il conteggio:
- Parsing (denso/grafo, commenti, righe vuote, errori di sintassi).
- Assemblaggio grafo byte-esatto **senza** padding, confrontato byte-per-byte contro
  l'esempio del manuale (§3), riferimento indipendente dall'implementazione.
- Assemblaggio grafo **con** padding (PARALLEL=4).
- Neurone a zero connessioni (`n_conn=0` → pad a un gruppo intero).
- Guardie a tempo di compilazione: auto-riferimento, riferimento in avanti, output usato
  come sorgente, overflow `MAX_CONN`, overflow `N_TOTAL`, `OUTPUT` non dichiarato —
  ciascuna verificata come test **negativo** (deve rifiutare, non solo "non crashare").
- Round-trip con l'RTL: gli stessi byte prodotti da `netasm` sono quelli effettivamente
  usati nel test end-to-end mandatorio del sottosistema flash
  (`sim/spi_neuron_top_flash_tb.v` TEST4, `netasm→SAVE_SLOT→LOAD_SLOT→RUN_NETWORK`,
  output=126 confermato) — non solo testato in isolamento, verificato anche contro
  l'hardware reale a valle.

## Verdetto

**CERTIFICATO.** Nessuna riserva — copertura sia positiva sia negativa, oracolo
indipendente (esempio del manuale, non l'implementazione stessa), e un round-trip reale
con l'hardware già dimostrato in una fase precedente di questa stessa sessione.
