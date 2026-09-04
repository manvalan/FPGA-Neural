# Sottosistema flash — documento di verifica (F1-F6)

Questo documento consolida, per modulo, cosa è verificato, come, contro quale oracolo, e cosa
NON è coperto — il deliverable richiesto esplicitamente da §9 del prompt di fase. La
narrazione cronologica completa (inclusi i bug trovati e corretti, con la loro esatta
diagnosi) resta in `WORKLOG.md`; questo documento è il riferimento strutturato, non una
sostituzione.

Standard applicato ovunque (§A del prompt di fase): oracolo indipendente dal design (mai
auto-referenziale), due piani di verifica (simulazione Icarus + sintesi/place&route reale
Yosys+nextpnr-ecp5), test avversari oltre al caso positivo, tracciabilità delle fonti.

---

## `rtl/spi_flash_master.v` — master SPI verso la flash (F1)

**Cosa è coperto**: RDID, READ, WREN, PP (incl. la regola "solo AND, mai OR" del datasheet),
SE, RDSR-1; opcode non implementato non causa hang. **Revisionato in Fase F7 (2026-09-04)**:
`sclk` è ora GPIO ordinaria sempre presente (non più dietro `USRMCLK`/CCLK-reuse — vedi
`WORKLOG.md` Fase F7 per il perché), bus a 4 fili genuinamente indipendente.

**Come**: `sim/spi_flash_master_tb.v`, 5 test contro `sim/flash_model.v`.

**Oracolo**: (1) valore JEDEC ID scritto indipendentemente nel testbench, dal datasheet
W25Q128JV(-DTR) §8.1.1 p.24 — non letto dalla costante di `flash_model.v`; (2) per READ, un
pattern piantato via riferimento gerarchico DIRETTAMENTE in `flash_model.mem[]`, mai passato
per l'RTL sotto test; (3) per PP AND-only, un secondo programma con `0xFF` che NON deve
alterare il primo valore (TEST3b) — distingue la regola vera da un "program sovrascrive"
ingenuo che passerebbe un test più debole.

**Test avversari**: opcode illegale (0xAB, comando reale W25Q128JV ma non implementato) →
nessun hang, il master shifta un numero fisso di bit indipendentemente dalla semantica.

**Sintesi reale**: `yosys synth_ecp5` (0 problemi) + `nextpnr-ecp5` reale, modulo isolato:
Fmax 181.36 MHz (PASS a 80MHz, ri-misurato in Fase F7 dopo la rimozione di `USRMCLK` —
181.72 MHz il numero precedente, differenza nel rumore di piazzamento), `USRMCLK` **0/1
(0%)** — conferma diretta che la primitiva non è più usata.

**NON coperto (§A.6)**: nessun test di power-loss (arriva a livello catalogo, F4); nessun
timeout RDSR a questo livello (responsabilità del chiamante, F3); nessuna verifica
elettrica/analogica reale (setup/hold, rise/fall) — solo comportamentale. Il gap di
verifica su `USRMCLKTS` (mai verificato contro la Technical Note Lattice primaria) è stato
**chiuso rimuovendo la dipendenza stessa** in Fase F7, non colmando la verifica mancante.

---

## `sim/flash_model.v` — modello comportamentale della flash (SOLO simulazione)

**Cosa modella**: erase→0xFF, program solo AND, WIP/WEL, timing tPP/tSE ai valori MAX del
datasheet (non TYP — un design che funziona solo col caso tipico non è corretto), power-loss
hook (forzatura di `pending_pp`/`pending_se`/`busy` via riferimento gerarchico).

**Oracolo per ogni regola**: citazione diretta del datasheet W25Q128JV(-DTR) locale, §/pagina
specifica per ogni regola (vedi commenti nel sorgente).

**Discrepanza dichiarata**: il PDF locale è titolato "W25Q128JV-DTR" (variante Double Transfer
Rate), non il part number liscio "W25Q128JV" del BOM reale
(`docs/FPGA-Neural-Hardware-Design.md` §6/§7). Il set di istruzioni standard-SPI e i timing
§9.6 sono condivisi da tutta la famiglia (validi senza riserve); il JEDEC ID invece NO — il
modello usa `EF4018h` (part liscio, pubblicamente documentato) non `EF7018h` (quello di
questo PDF specifico). **Il bring-up su hardware reale deve confermare l'RDID effettivo.**

**NON coperto (§A.6)**: Fast/Dual/Quad/QPI/DTR (fuori scope, solo SPI standard usato);
bit di protezione/Individual Block Lock (fuori scope, la flash è esclusiva della FPGA);
timing elettrico reale; il power-loss simulato rappresenta solo "operazione mai committata",
non "committata a metà" (limite del modello, dichiarato).

---

## `rtl/flash_copy_engine.v` — copy engine LOAD/SAVE/ERASE (F2/F3/F5)

**Cosa è coperto**: `DIR_LOAD` (flash→PSRAM, chunking automatico oltre 65535B),
`DIR_SAVE` (PSRAM→flash, erase-before-write, loop Page Program ≤256B, poll WIP),
`DIR_ERASE` (erase settore standalone, F5).

**Come**: `sim/flash_copy_engine_load_tb.v` (5 test), `sim/flash_copy_engine_save_tb.v`
(5 test), `sim/flash_copy_engine_erase_tb.v` (3 test) — stack PSRAM reale (mem_arbiter →
int8_memory_access → memory_interface → psram_controller → psram_model), non un modello
semplificato.

**Oracolo**: dati piantati indipendentemente in `flash_model.mem[]` (LOAD) o letti
direttamente da lì dopo una SAVE (non passati per l'RTL sotto test in nessuno dei due
sensi); per la regola AND-only, un settore pre-avvelenato con un pattern diverso da quello
salvato, verificando che la coda non scritta torni a 0xFF (prova un erase reale, non solo un
program sopra il vecchio contenuto).

**Test avversari**: lunghezza fuori range (flash e PSRAM), `len==0`, blocco non allineato al
settore (SAVE/ERASE), blocco che attraversa un confine di pagina 256B (300 byte, 2 pagine),
contesa reale dell'arbitro con un master a priorità più alta durante un intero LOAD, WIP
prolungato (forzato via hook power-loss, nessun timeout — poll continua, completa quando WIP
si libera davvero).

**Due bug trovati e corretti durante il bring-up** (dettagli completi in `WORKLOG.md`, F2):
1. **Bug pre-esistente in `rtl/psram_controller.v`** (non del sottosistema flash): richieste
   arrivate durante i primi ~150µs dopo reset venivano perse silenziosamente, e la sequenza
   interna di configurazione del chip generava impulsi `mem_ready` spuri. Rischio reale per
   lo scenario "boot standalone da flash" per cui esiste questo sottosistema. Corretto con
   coda per richieste precoci + guardia sugli impulsi spuri.
2. **Bug nel nuovo codice**: `d_req` verso l'arbitro PSRAM era un impulso di un ciclo,
   perdibile in caso di contesa esatta con un'altra porta. Corretto rendendolo un segnale di
   livello tenuto alto finché non viene servito davvero (con un secondo sotto-bug — race sul
   ciclo esatto di rilascio dell'arbitro — trovato e corretto nello stesso giro).

**Sintesi reale**: `yosys synth_ecp5` pulito + `nextpnr-ecp5` reale, modulo isolato: F2
172.98 MHz, F3 158.28-158.55 MHz (PASS a 80MHz, numeri di solo modulo).

**NON coperto (§A.6)**: blocco >65535B a piena dimensione (chunking implementato e
ragionato, non esercitato a piena scala per tempo di simulazione); due SAVE consecutive su
settori adiacenti (non richiesto per queste fasi).

---

## `rtl/crc32.v` — CRC32 (F4)

**Cosa è coperto**: algoritmo CRC32 riflesso standard (IEEE 802.3/zlib, polinomio
0xEDB88320).

**Come**: `sim/crc32_tb.v`, 4 test.

**Oracolo — TRE fonti indipendenti**: (1) identità matematica del messaggio vuoto (init XOR
final = 0); (2) valore di controllo testuale standard pubblicato "123456789" → `0xCBF43926`
(citato in ogni tabella di riferimento CRC32, non calcolato da nessuno dei due lati); (3)
`tools/flash_catalog/oracle.py`, che usa `zlib.crc32` della libreria standard Python —
implementazione completamente separata, non derivata dalla stessa comprensione di design.

**NON coperto**: nessuna verifica di throughput/pipeline (l'accumulatore è un aggiornamento
combinazionale per byte, non un collo di bottiglia dato il ritmo flash/PSRAM molto più lento).

---

## `rtl/flash_slot_manager.v` — catalogo a slot fissi (F4/F5)

**Cosa è coperto**: `CAT_READ` (ricarica il catalogo on-chip da flash), `CAT_WRITE_SLOT`
(registra/aggiorna una voce, persiste l'intero catalogo), `LOAD_SLOT`/`SAVE_SLOT` (risolvono
lo slot dal catalogo on-chip, CRC calcolato dal vero stream di byte), più i 3 opcode raw
(F5: `FLASH_READ_BLOCK`/`FLASH_WRITE_BLOCK`/`FLASH_ERASE`, pass-through diretto senza
catalogo/CRC).

**Come**: `sim/flash_slot_manager_tb.v` (6 test, F4), `sim/flash_slot_manager_raw_tb.v`
(4 test, F5) — stesso stack PSRAM reale.

**Oracolo**: `tools/flash_catalog/oracle.py` — layout byte del catalogo e CRC32 di
riferimento, confrontati byte-a-byte contro i byte REALI persistiti in `flash_model.mem[]`
(non contro il decode dell'RTL stesso).

**Test avversari**: CRC corrotto (un bit capovolto direttamente in `flash_model.mem[]`) →
`LOAD_SLOT` rifiuta; slot mai salvato → `LOAD_SLOT` rifiuta immediatamente, nessuna
transazione tentata (sentinella PSRAM intatta); **power-loss simulato** durante il Sector
Erase di una `SAVE_SLOT` (hook di `flash_model.v`, settore pre-avvelenato con pattern
diverso) — il motore "completa con successo" secondo RDSR (nessun modo per saperlo
altrimenti), ma il CRC persistito non combacia più coi byte reali (mai davvero cancellati) →
una `LOAD_SLOT` successiva lo rileva. Dimostra che il meccanismo di rilevamento dipende dal
CRC sui byte realmente committed, non da un segnale di completamento che può mentire.

**Bug trovato e corretto in revisione** (prima di ogni simulazione): condizione di
aggiornamento del CRC basata su `fce_d_req && d_ready` — contraddizione logica sempre falsa,
dato come `flash_copy_engine.v` definisce il proprio `d_req`. Corretta in `fce_busy &&
d_ready`. Decode di una voce di catalogo inizialmente incompleto (solo offset). Gap trovato
in revisione durante F5: `SAVE_SLOT` non controllava `fce_err` prima di marcare il catalogo
valido.

**Sintesi reale**: `yosys synth_ecp5` pulito (0 problemi CHECK). Place&route reale a livello
di modulo isolato NON eseguibile per questo modulo specifico (253 bit di porte a livello di
modulo superano i 245 pin fisici del package — artefatto del testare un modulo interno come
top fittizio, non un problema del design); la vera verifica di piazzamento arriva con
l'integrazione in `spi_neuron_top` (F5, sotto).

**NON coperto (§A.6)**: due slot che si sovrappongono in flash (responsabilità dell'host, che
governa offset/length via `CAT_WRITE_SLOT`); `CATALOG_PSRAM_ADDR` è una convenzione non
imposta altrove — vedi §5 "limiti host" sotto per la conseguenza reale di questo limite.

---

## `rtl/spi_engine.v` — opcode SPI del sottosistema flash (F5)

**Cosa è coperto**: decodifica degli 8 opcode (0x40-0x47), accumulatore di payload condiviso,
STATUS esteso (bit3=`flash_err_sticky`, bit4=`flash_busy`), `done_event` corretto per
includere il completamento flash come sorgente indipendente dall'inferenza.

**Come**: `sim/spi_neuron_top_flash_tb.v` (test end-to-end via SPI reale bit-banged) +
regressione di `sim/spi_engine_tb.v` (esistente, invariato).

**Oracolo**: derivazione a mano bit-per-bit di ogni campo del payload (stesso metodo di F1),
verificata via traccia diretta dei valori decodificati (`flash_op_code`/`flash_slot_id`/ecc.)
prima di fidarsi del comportamento a valle.

**Bug trovato DALLA REGRESSIONE, non dalla progettazione** (motivo per cui va sempre
rieseguita, mai solo assunta): la prima versione di `done_event` sostituiva un multiplexer a
priorità ESISTENTE (che maschera deliberatamente gli `nm_done` intermedi durante una
`RUN_NETWORK` multi-layer) con un OR piatto — `sim/spi_engine_tb.v` ha fallito immediatamente
("done bit set by an intermediate nm_done"). Corretto preservando la maschera esistente
INVARIATA e aggiungendo `flash_done` come sorgente OR separata, fuori dalla maschera.

**NON coperto**: nessuna verifica formale di tutte le 2^N combinazioni di byte payload
malformati (fuori scope — i test coprono il caso positivo e gli specifici casi avversari già
verificati ai livelli sottostanti, che l'SPI framing si limita a inoltrare fedelmente).

---

## `rtl/spi_neuron_top.v` — integrazione finale (F5)

**Cosa è coperto**: istanziazione di `flash_slot_manager`, nuovi pin fisici
(`flash_mosi`/`flash_miso`/`flash_cs_n`, distinti dai pin SPI host), Port D dell'arbitro
collegata (non più tied-off), pinout reale rigenerato.

**Come**: `sim/spi_neuron_top_flash_tb.v`, 4 test sopra lo STACK COMPLETO REALE.

**Il test end-to-end richiesto esplicitamente da §6 del piano**: `netasm → WRITE_RAM →
SAVE_SLOT → (sovrascrittura PSRAM con garbage) → LOAD_SLOT → RUN_NETWORK → READ_RAM = 126`
— lo stesso valore atteso indipendente già usato in `sim/graph_engine_tb.v`/
`sim/spi_neuron_top_graph_tb.v` (esempio da manuale §3), non ri-derivato.

**Tre intoppi reali nella costruzione del test, nessun bug RTL** (dettagliati in
`WORKLOG.md`, F5): collisione PSRAM tra il blob di rete e `CATALOG_PSRAM_ADDR` di default;
`--parallel` di `netasm` non corrispondente al `PARALLEL` reale dell'hardware; `netasm`
incorpora indirizzi ASSOLUTI (non relativi) nella tabella descrittore, quindi spostare il
blob compilato richiede rigenerarlo con `--table-base`/`--edges-base` corrispondenti — un
mismatch qui produce un risultato "riuscito" (STATUS pulito, nessun errore) ma
completamente sbagliato, senza alcun sintomo hardware-visibile.

**Sintesi reale, livello di SISTEMA COMPLETO** (prima volta per il sottosistema flash
integrato): 0 errori di vincolo, 56/56 celle piazzate. Fmax **66.68 MHz** (FAIL a 80MHz,
atteso — percorso critico verificato esplicitamente IDENTICO a quello già noto dalla Fase 7,
`neuron_parallel`'s catena di riporto dell'accumulatore, NESSUN modulo flash coinvolto). Il
calo dai 73.88MHz precedenti è rumore di piazzamento (banda già caratterizzata), non una
regressione — confermato dal percorso critico invariato.

Occupazione (sistema completo): `TRELLIS_IO` 56/245 (22%), `TRELLIS_FF` 4855/43848 (11%),
`TRELLIS_COMB` 9060/43848 (20%), `DP16KD` 2/108, `MULT18X18D` 16/72, `USRMCLK` 1/1 (100%) —
nessuna pressione sulle risorse del dispositivo.

**Fase F7 (2026-09-04, stesso giorno): bus flash reso indipendente, ri-sintetizzato.**
Rimosso `USRMCLK`/riuso di CCLK per SCLK (richiesta esplicita dell'utente: il bus deve essere
esclusivo anche elettricamente, non solo di controllo — vedi `WORKLOG.md` Fase F7 per il
razionale completo). `flash_sclk` è ora una 4ª ball GPIO ordinaria (`E3`, banco 7), aggiunta
in modo puramente additivo (`git diff` sul `.lpf`: solo 1 riga in più, nessuna ball esistente
spostata). Ri-sintesi completa del sistema: **0 errori di vincolo**, `TRELLIS_IO` 57/245
(23%), **`USRMCLK` 0/1 (0%)** — conferma diretta che la primitiva non è più usata affatto.
Fmax **67.91 MHz** (leggermente meglio dei 66.68MHz precedenti, rumore di piazzamento, non
regressione), percorso critico confermato ancora identico (nessun modulo flash coinvolto).
Regressione completa dei 33 testbench del progetto ripetuta da zero dopo il fix: tutti PASS,
incluso il test end-to-end mandatorio con lo stesso output atteso (126) e le stesse latenze
misurate (ERASE≈400.003ms, SAVE≈403.004ms, LOAD=1.743ms — invariate, la rinomina del pin non
tocca la temporizzazione).

---

## Scoperta trasversale: limite reale di `WRITE_RAM`/`READ_RAM` (non specifica alla flash)

Durante il bring-up del test end-to-end (F5) è emerso che `WRITE_RAM`/`READ_RAM` (opcode
esistenti, PRE-esistenti a questa intera sessione, mai modificati) non hanno alcun
backpressure verso il master SPI — limite già dichiarato nell'header di `spi_engine.v` ma la
cui conseguenza pratica (corruzione silenziosa dei dati, non un hang, non un errore) non era
mai stata esposta prima. È emersa a causa del fix CORRETTO su `psram_controller.v` (sopra):
un bug pre-esistente diverso mascherava accidentalmente il rischio, dando all'host
"fortunatamente" abbastanza poco tempo da non disallinearsi. **Rischio reale per QUALUNQUE
host** che emetta `WRITE_RAM`/`READ_RAM` troppo presto dopo il reset (entro il power-up
~150µs di `psram_controller`), non solo per i test di questa sessione. **Mitigazione
applicata qui**: ogni testbench aspetta esplicitamente `psram_ctrl.state == STATE_IDLE`
prima del primo accesso PSRAM. **Non risolto nell'RTL** (fuori scope per il sottosistema
flash — richiederebbe un vero protocollo di backpressure): dichiarato come rischio aperto,
non nascosto.

---

## Latenze reali misurate (F6)

**Metodologia** (dichiarata esplicitamente, §A.5): simulare l'intera attesa WIP a scala
temporale reale con il vero loop di poll RDSR si è rivelato impraticabile — a timing reale,
coprire un'attesa di 400ms con poll a ritmo SPI reale richiede circa 100.000+ transazioni di
poll, decine di milioni di eventi Icarus, oltre il limite pratico di tempo macchina (limite
del simulatore, non dell'hardware — un poll reale su silicio non costa tempo di simulazione).
Approccio usato: la fase di "issue" (WREN+SE/PP, limitata dal clock SPI) è misurata
direttamente in simulazione (accurata indipendentemente dalla scala temporale del modello
flash, che scala solo l'attesa WIP successiva); la durata dell'attesa WIP stessa è presa
dal valore MAX del datasheet (già citato in `sim/flash_model.v`, §9.6 p.90), sommata
analiticamente. Misurato con `sim/flash_latency_bench.v`.

| Operazione | @16MHz | @80MHz |
|---|---|---|
| ERASE (un settore 4KB) | 400.014 ms | 400.003 ms |
| SAVE (256B, incl. proprio erase) | 403.019 ms | 403.004 ms |
| LOAD (4096B) | 8.713 ms (0.470 MB/s) | 1.743 ms (2.351 MB/s) |

ERASE/SAVE sono dominati quasi interamente dal timing interno della flash (tSE_MAX=400ms,
tPP_MAX=3ms — fisici, indipendenti dalla frequenza host); LOAD è invece puramente limitato
dal clock SPI (nessuna attesa WIP per READ, §8 intro p.24 del datasheet) — la banda scala
linearmente con la frequenza, come atteso fisicamente.

---

## Riepilogo regressione (F6)

Tutti i 33 testbench del progetto (incluse le 2 varianti negative attese fallire in
elaborazione) — **PASS**, nessuna regressione, eseguiti dopo ogni modifica significativa
durante l'intera sessione, non solo alla fine.
