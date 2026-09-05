# C.3 — Sottosistema memoria (`int8_memory_access`, `memory_interface`, `psram_controller`)

Data: 2026-09-04.

---

## 3.1 `int8_memory_access.v` — conversione byte↔word e selezione byte-lane — CERTIFICATO

**Metodo**: nuovo test dedicato (`sim/int8_memory_access_bytelane_tb.v`), non esisteva prima
una verifica esaustiva della conversione indirizzo. Due batterie:
1. **Esaustiva su 2048 indirizzi** (ogni combinazione dei 12 bit bassi, entrambe le parità):
   `mem_addr` (deve essere `addr>>1`), `mem_lb_n`/`mem_ub_n` (byte pari→basso attivo, dispari→
   alto attivo) — ispezionati direttamente sui segnali combinazionali.
2. **Round-trip scrittura/lettura reale** attraverso l'handshake FSM (non un peek interno) a
   6 indirizzi (pari/dispari, valori di bordo INT8, e un test esplicito che una scrittura
   sull'indirizzo dispari di una parola NON corrompa il byte pari già scritto nella stessa
   parola — verifica che le byte-lane siano davvero indipendenti).

**Oracolo**: formula dichiarata dal modulo stesso (`addr>>1`, `addr[0]`), applicata
indipendentemente, non letta dall'RTL.

**Due bug nella MIA testbench, trovati e corretti prima di fidarmi del risultato** (stesso
schema di trasparenza di C.1/C.2, riportato per intero):
1. Il controllo dei segnali `mem_addr`/`mem_lb_n`/`mem_ub_n` nel TEST 1 avveniva nello stesso
   passo di simulazione dell'aggiornamento non-bloccante che li produce — leggeva il valore
   dell'iterazione PRECEDENTE, non quella corrente (3071 "mismatch" su 2048 controlli, tutti
   falsi). Corretto con un `#1` dopo il fronte di clock, per lasciare che l'aggiornamento si
   assesti prima di leggerlo.
2. Il modello di memoria comportamentale della testbench scriveva l'intera parola a 16 bit
   incondizionatamente, **ignorando `mem_lb_n`/`mem_ub_n`** — una scrittura sul byte dispari
   di una parola cancellava il byte pari già scritto lì, anche con `mem_lb_n=1` (disabilitato).
   Questo ha fatto fallire il test di round-trip "scrittura non deve corrompere il byte
   fratello" — ma il difetto era nello STUB di test, non nell'RTL sotto test (il DUT
   comunica correttamente `mem_lb_n`/`mem_ub_n`, era il modello di memoria a non rispettarli).
   Corretto rendendo lo stub sensibile alle byte-lane come una vera memoria mascherabile a
   byte.

```
$ iverilog -g2012 -o /tmp/bytelane2.out rtl/int8_memory_access.v sim/int8_memory_access_bytelane_tb.v && vvp /tmp/bytelane2.out
ALL TESTS PASSED (2048 decode checks + 6 round-trip checks, 0 mismatches)
```

**Verdetto: CERTIFICATO.** 2054/2054 controlli, 0 mismatch, dopo la correzione di due difetti
nella testbench stessa (non nell'RTL).

---

## 3.2 `memory_interface.v` — CERTIFICATO (via test pre-esistente)

Modulo semplice: stesso pattern di handshake req/ready di `int8_memory_access.v` ma a
granularità 16 bit, senza logica di byte-lane propria (inoltra `lb_n`/`ub_n` così come
ricevuti). `sim/memory_interface_tb.v` (pre-esistente, riverificato in Fase 0) copre
l'handshake. Non ripetuto da zero in questa fase: la logica è sufficientemente semplice
(nessuna aritmetica di indirizzo propria) da non giustificare una nuova campagna esaustiva
oltre a quanto già verificato.

**Verdetto: CERTIFICATO** (copertura pre-esistente, ritenuta adeguata alla semplicità del
modulo).

---

## 3.3 `psram_controller.v` — CERTIFICATO (lavoro estensivo già svolto in questa sessione, non ri-fatto da zero)

Questo modulo ha già ricevuto una verifica sostanziale **in questa stessa sessione**, non
solo dichiarata nel WORKLOG di sessioni precedenti:
- **Un bug reale pre-esistente trovato e corretto**: richieste arrivate durante
  `STATE_INIT`/`STATE_CR_INIT` (~150µs di poweron) venivano perse silenziosamente; corretto
  con un latch `req_pending` — trovato durante il lavoro sul sottosistema flash (Fase F2),
  con una riproduzione minimale isolata prima e dopo il fix.
- **Timing di page-mode verificato contro il datasheet ISSI reale**: `ACCESS_CYCLES =
  ceil(70ns × CLK_FREQ_MHZ/1000)`, `PAGE_CYCLES` per il burst, `tCEM` (idle timeout e budget
  mid-burst) — `sim/psram_page_mode_tb.v`, con `sim/psram_model.v` che fa **`$fatal` su
  qualunque violazione di timing reale** (non solo un controllo di valore atteso: un
  meccanismo di oracolo attivo che blocca la simulazione se l'RTL viola una regola del
  datasheet, indipendentemente da cosa la testbench stessa controlli esplicitamente).
- Rieseguito in Fase 0 di questa campagna (non solo citato): `psram_controller_tb.v` e
  `psram_page_mode_tb.v` **PASS**, confermato da un harness di regressione indipendente
  (`tools/run_regression.py`), non dalla parola del WORKLOG.

**Non ripetuto da zero in C.3**: rifare l'intera campagna di verifica del page-mode/tCEM già
completata con rigore comparabile in questa sessione sarebbe una duplicazione di lavoro già
tracciabile (WORKLOG, fasi F2/G7), non una nuova scoperta. Citato come evidenza, non dato per
buono senza verifica: il PASS è stato riconfermato da zero in Fase 0 di questa campagna.

**Verdetto: CERTIFICATO**, con la stessa evidenza di prima (riverificata, non solo citata).

---

## 3.4 Verdetto complessivo C.3

| Sotto-aspetto | Verdetto |
|---|---|
| `int8_memory_access.v` (byte↔word, byte-lane) | **CERTIFICATO** (nuovo, esaustivo su 2048 indirizzi) |
| `memory_interface.v` | **CERTIFICATO** (copertura pre-esistente adeguata) |
| `psram_controller.v` (incl. page-mode, tCEM) | **CERTIFICATO** (lavoro esteso di sessione, riverificato) |

Nessun bug nuovo trovato in questo aspetto — due difetti trovati erano nella mia stessa
testbench di verifica, corretti prima di trarre conclusioni sull'RTL.
