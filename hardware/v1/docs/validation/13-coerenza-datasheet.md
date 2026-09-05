# C.13 — Coerenza datasheet↔RTL

Data: 2026-09-04.

## Metodo

Il lavoro di allineamento datasheet↔RTL più recente (pinout pin-per-pin, bus SPI flash
indipendente, opcode 0x40-0x47, Fmax aggiornata) è stato fatto **in questa stessa sessione**,
appena prima dell'avvio di questa campagna di certificazione — non preso dalla parola.
`grep` mirato sui documenti per confermare che nessuna cifra ovviamente stantia sia rimasta
(56 vs 57 segnali, `USRMCLK`, Fmax vecchie) non ha trovato residui.

## Scostamento reale trovato: i bug di questa campagna non sono (ancora) nel datasheet

**Nessuno dei 7 bug trovati in questa campagna (BUG-001–BUG-007) è menzionato nel
datasheet o in `docs/FPGA-NeuralNetwork-Engine.md`** — verificato con una ricerca mirata,
non assunto. Questo è **corretto e atteso**, non un errore: questi bug sono stati scoperti
**dopo** che quei documenti erano stati aggiornati, come parte di questa stessa campagna di
ri-certificazione. Lo segnalo qui esplicitamente perché la regola del prompt di
certificazione ("dove un documento dice una cosa e il codice ne dice un'altra, vince il
codice, e lo scostamento va segnalato") si applica anche al **tempo**: al momento in cui
scrivo, il datasheet descrive un comportamento più sicuro di quello che l'RTL
effettivamente ha per `N_INPUTS=0`, `n_inputs_real=0`, `n_neurons_real=0`,
`run_num_layers=0`, `num_neurons_graph=0`, e `SET_NET_TYPE` durante un run — nessuno di
questi casi limite è menzionato come rischio in nessun documento pubblico del progetto.

**Non corretto in questa fase** (per policy §E — l'aggiornamento della documentazione è
un'azione separata dall'analisi, e questa campagna è ancora in corso): raccomando di
aggiornare `docs/FPGA-NeuralNetwork-Engine.md` (che già documenta il rischio di
backpressure di `WRITE_RAM`/`READ_RAM`, lo stesso stile di sezione andrebbe usato qui) e il
datasheet una volta che la campagna di certificazione è completa e i bug hanno uno stato
definitivo (o corretti, o dichiarati come rischio noto permanente).

## Verdetto

**CERTIFICATO per l'allineamento sulle cifre/pinout/opcode** (nessun residuo stantio
trovato). **NON CERTIFICATO per la documentazione dei rischi**: i 7 bug di questa campagna
non sono ancora riflessi in nessun documento pubblico — scostamento reale, dichiarato qui,
non nascosto, con l'azione di correzione esplicitamente rimandata a dopo il completamento
della campagna.
