# C.4 — Arbitro (`mem_arbiter.v`)

Data: 2026-09-04.

---

## 4.1 Priorità B>C>A>D — CERTIFICATO

**Metodo**: nuovo test dedicato (`sim/mem_arbiter_priority_tb.v`). Quattro scenari,
combinazioni decrescenti di richiedenti simultanei, ciascuno con dati distinguibili
(`m_rdata` eco dell'indirizzo) per confermare che la risposta torni al **richiedente
corretto**, non solo che "qualcuno" venga servito:
1. A+B+C+D simultanei → B vince.
2. A+C+D (B assente) → C vince.
3. A+D (B,C assenti) → A vince.
4. D da solo → viene comunque servito (bassa priorità ≠ mai servito).

```
$ iverilog -g2012 -o /tmp/arb6.out rtl/mem_arbiter.v sim/mem_arbiter_priority_tb.v && vvp /tmp/arb6.out
ALL TESTS PASSED (priority order B>C>A>D confirmed; ...)
```

**Nota di processo — race trovata nella mia stessa testbench**: la prima versione usava
assegnazioni bloccanti per ritirare le richieste dei "perdenti" nello stesso
`@(posedge clk)` che doveva concedere la richiesta — una race reale con il blocco
sincrono del DUT sullo stesso fronte (l'ordine di esecuzione tra processi diversi
sensibili allo stesso evento non è garantito da Verilog). Diagnosticato con un
riferimento gerarchico a `dut.owner`, mai uscito da `SEL_NONE` nonostante le richieste
fossero pilotate — non un difetto dell'RTL. Corretto passando ad assegnazioni non
bloccanti per i segnali di richiesta in tutta la testbench, come farebbe un master reale
sincrono allo stesso clock.

**Verdetto: CERTIFICATO.** L'ordine di priorità dichiarato nell'header è implementato
esattamente come descritto, dati instradati al richiedente corretto in ogni caso.

---

## 4.2 Starvation di D sotto contesa continua — comportamento reale, ambiguità nella documentazione

**Test**: `b_req` e `d_req` mantenuti entrambi asserti continuamente per 500 cicli
(B "ha sempre altro lavoro" nell'istante in cui si libera).

**Risultato**: **D non viene MAI concesso in 500 cicli** di contesa continua da B.

**Perché non lo classifico come bug**: l'header del modulo dichiara "flash operations
are ms-scale and never meant to compete with inference for memory bandwidth" e "In
normal operation B and C are temporally disjoint anyway" — la contesa continua e
sostenuta testata qui è esplicitamente fuori dallo scenario operativo previsto (un
`layer_sequencer`/`neuron_memory` che non lascia MAI un buco libero per centinaia di
cicli di fila non corrisponde a un'inferenza reale). Un arbitro a priorità fissa senza
invecchiamento (aging) che fa morire di fame il richiedente più basso sotto carico
sostenuto è un design standard e spesso intenzionale, non un difetto di per sé.

**Cosa segnalo**: la frase dell'header "gets stretched out, never starves or corrupts
A/B/C" è **ambigua** — può essere letta sia come "[D] non affama mai [se stesso]" sia
come "[la contesa] non fa mai affamare o corrompere A/B/C" (una garanzia solo su A/B/C,
non su D). Il comportamento osservato è coerente con la SECONDA lettura, non con la
prima. Non è un bug funzionale, ma la frase andrebbe disambiguata nel commento sorgente
per evitare che un futuro lettore assuma erroneamente che D abbia una garanzia di
progresso che il codice non implementa.

**Verdetto: CERTIFICATO come comportamento** (nessuna sorpresa rispetto a un arbitro a
priorità fissa senza aging), **riserva documentale** sulla frase ambigua dell'header.

---

## 4.3 Verdetto complessivo C.4

| Sotto-aspetto | Verdetto |
|---|---|
| Priorità B>C>A>D, instradamento dati corretto | **CERTIFICATO** |
| Starvation di D sotto contesa sostenuta | **CERTIFICATO come comportamento**, riserva sulla chiarezza della documentazione (non un bug) |

Nessun bug RTL trovato in questo aspetto. Un difetto di race trovato e corretto nella
testbench di verifica stessa (stesso schema del resto della campagna).
