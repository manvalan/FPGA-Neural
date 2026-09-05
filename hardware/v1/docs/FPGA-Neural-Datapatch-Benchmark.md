# FPGA-Neural — Analisi datapath e benchmark ECP5

## 1. Obiettivo

Questa fase del progetto FPGA-Neural ha avuto lo scopo di verificare il comportamento sintetizzabile e le prestazioni del core neurale parametrico sul dispositivo:

**Lattice LFE5U-45F-8BG381C**

Configurazione FPGA:

- ECP5-45F
- Speed grade: `-8`
- Package: `CABGA381`
- 72 blocchi `MULT18X18D`
- circa 43.8k LUT/FF equivalenti

La configurazione funzionale utilizzata nei benchmark è:

```text
DATA_WIDTH  = 8 bit
ACC_WIDTH   = 32 bit
N_INPUTS    = 256
N_NEURONS   = 4
PARALLEL    = variabile

Il datapath implementa:

INT8 × INT8
      ↓
   INT16
      ↓
sign extension
      ↓
   INT32
      ↓
accumulation
      ↓
   + bias
      ↓
    ReLU
      ↓
INT8 saturation

Lo scopo principale del benchmark è stato determinare il compromesso tra:

numero di MAC paralleli;
utilizzo dei DSP;
complessità del datapath;
routing;
frequenza massima;
latenza di elaborazione.
2. Architettura RTL

L'attuale datapath è organizzato gerarchicamente:

                    layer
                      │
             ┌────────┴────────┐
             │                 │
          neuron 0           neuron N
             │                 │
             ▼                 ▼
       neuron_parallel   neuron_parallel
             │                 │
             ▼                 ▼
           mac8              mac8
             │                 │
       MAC × PARALLEL    MAC × PARALLEL

Ogni neurone elabora N_INPUTS ingressi a gruppi di PARALLEL.

Con:

N_INPUTS = 256

il numero di gruppi è:

GROUPS = 256 / PARALLEL

Pertanto:

PARALLEL	Gruppi per neurone
16	16
8	32
4	64
2	128

I quattro neuroni vengono elaborati contemporaneamente.

3. MAC unit

Il modulo mac_unit implementa un singolo prodotto-accumulatore.

Per la configurazione INT8:

x : signed INT8
w : signed INT8

Il prodotto è:

INT8 × INT8 = INT16

Il risultato viene quindi esteso con segno a 32 bit:

INT16 → INT32

e sommato all'accumulatore.

L'operazione fondamentale è quindi:

acc_out = acc_in + (x × w)

L'implementazione è completamente parametrica rispetto a:

DATA_WIDTH
ACC_WIDTH
4. Balanced adder tree

Una modifica importante rispetto alla prima implementazione è stata la sostituzione dell'accumulatore combinazionale lineare con un balanced binary adder tree.

Una riduzione lineare avrebbe prodotto:

((((p0 + p1) + p2) + p3) + ...)

con profondità:

O(PARALLEL)

La nuova implementazione utilizza invece:

             sum
           /     \
        sum       sum
       /   \     /   \
      p0   p1   p2   p3

La profondità diventa:

O(log2(PARALLEL))

Per esempio:

PARALLEL = 8
→ 3 livelli

PARALLEL = 16
→ 4 livelli

PARALLEL = 32
→ 5 livelli

Questa modifica riduce significativamente la profondità combinazionale del datapath.

5. neuron_parallel

neuron_parallel esegue il calcolo di un singolo neurone.

Il funzionamento è:

start
  ↓
group 0
  ↓
group 1
  ↓
...
  ↓
group N
  ↓
+ bias
  ↓
ReLU
  ↓
saturation
  ↓
done

Durante ogni ciclo viene elaborato un gruppo di:

PARALLEL

prodotti.

L'accumulatore mantiene il risultato tra un gruppo e il successivo.

6. Test funzionale

Il testbench sim/parametric_tb.v utilizza:

DATA_WIDTH = 8
N_INPUTS   = 256
N_NEURONS  = 4
PARALLEL   = variabile
ACC_WIDTH  = 32

Sono stati definiti quattro casi di test.

N0 — accumulazione su più gruppi

Input:

x = 1

Pesi:

primi 32 = +1
restanti = 0

Risultato:

32 × 1 × 1 = 32

Output atteso:

32

Questo test verifica soprattutto la corretta gestione dell'accumulatore attraverso più gruppi.

N1 — bias

Pesi:

tutti = 0

Bias:

+10

Output atteso:

10
N2 — ReLU

Pesi:

tutti = -1

Input:

tutti = +1

Il risultato è negativo.

La ReLU produce:

0
N3 — saturazione

Pesi:

primi 32 = +4
restanti = 0

Input:

tutti = +1

Risultato:

32 × 4 = 128

L'uscita INT8 positiva viene saturata:

128 → 127
7. Risultato simulazione

Il test è passato con PARALLEL=16:

PARALLEL  = 16

PASS N0: 32
PASS N1: 10
PASS N2: 0 (ReLU)
PASS N3: 127 (saturation)

INT8 PARAMETRIC TEST PASSED

È passato anche con PARALLEL=32:

PARALLEL  = 32

PASS N0: 32
PASS N1: 10
PASS N2: 0 (ReLU)
PASS N3: 127 (saturation)

INT8 PARAMETRIC TEST PASSED

La correttezza funzionale del datapath parametrico è quindi confermata.

8. Sintesi e Place & Route

Dopo la simulazione il datapath è stato sintetizzato per ECP5 utilizzando:

Yosys

e successivamente piazzato e instradato con:

nextpnr-ecp5

Target:

LFE5U-45F
CABGA381
Speed grade -8

Il wrapper di benchmark genera internamente:

input;
pesi;
bias;
segnali di test.

In questo modo non vengono portati all'esterno i giganteschi bus del modello neurale.

Il top-level espone solamente:

clk
rst
start
y_bus
busy
done

Questa modifica è stata fondamentale.

Il primo tentativo esponeva infatti direttamente:

x_bus      ≈ 2048 bit
weights    ≈ 8192 bit
bias       ≈ 32 bit

portando a oltre 10.000 I/O fisiche richieste.

Il risultato era:

TRELLIS_IO: 10309/245

e quindi un errore di placement.

Il problema non era la dimensione logica del circuito, ma esclusivamente il numero di I/O.

9. PARALLEL = 16

Risorse sintetizzate:

LUT4 ≈ 2531
DFF  = 186

Risorse FPGA:

MULT18X18D = 64 / 72

quindi:

88% dei DSP

Timing:

Fmax ≈ 52.13 MHz
Tcrit ≈ 19.18 ns

Il percorso critico risultava fortemente influenzato dal routing.

Configurazione:

PARALLEL = 16
N_NEURONS = 4

produce:

16 × 4 = 64 MAC simultanei
10. PARALLEL = 8

Risorse:

MULT18X18D = 32 / 72

quindi:

32 DSP

Con quattro neuroni:

8 × 4 = 32 MAC simultanei

Timing:

Fmax ≈ 61.71 MHz
Tcrit ≈ 16.20 ns

Composizione del percorso critico:

logic   ≈ 6.43 ns
routing ≈ 9.77 ns
total   ≈ 16.20 ns

Questa configurazione è particolarmente importante perché corrisponde esattamente al target originale di:

32 MAC hardware simultanei
11. PARALLEL = 4

Risorse:

LUT4 = 804
DFF  = 194

MULT18X18D = 16 / 72

Quindi:

16 MAC simultanei

Timing:

Fmax ≈ 75.01 MHz
Tcrit ≈ 13.33 ns

Composizione:

logic   ≈ 6.67 ns
routing ≈ 6.66 ns
total   ≈ 13.33 ns

In questa configurazione logica e routing sono quasi perfettamente bilanciati.

12. PARALLEL = 2

Risorse:

LUT4 = 481
DFF  = 198

MULT18X18D = 8 / 72

Quindi:

8 MAC simultanei

Timing finale dopo routing:

Fmax ≈ 87.88 MHz
Tcrit ≈ 11.38 ns

Composizione:

logic   ≈ 6.43 ns
routing ≈ 4.95 ns
total   ≈ 11.38 ns

Il design è stato quindi verificato con target:

80 MHz

ottenendo:

87.88 MHz

e:

PASS

Il margine teorico rispetto a 80 MHz è:

T80MHz = 12.50 ns

12.50 - 11.38 ≈ 1.12 ns
13. Tabella comparativa
PARALLEL	MAC/neurone	Neuroni	MAC totali	DSP	Fmax	Tcrit	80 MHz
16	16	4	64	64	52.13 MHz	19.18 ns	FAIL
8	8	4	32	32	61.71 MHz	16.20 ns	FAIL
4	4	4	16	16	75.01 MHz	13.33 ns	FAIL
2	2	4	8	8	87.88 MHz	11.38 ns	PASS
14. Interpretazione

I risultati mostrano chiaramente il trade-off fondamentale.

Riducendo PARALLEL:

PARALLEL ↓
    ↓
MAC simultanei ↓
    ↓
DSP ↓
    ↓
adder tree ↓
    ↓
routing/congestione ↓
    ↓
Fmax ↑

ma contemporaneamente:

PARALLEL ↓
    ↓
numero gruppi ↑
    ↓
cicli necessari ↑
    ↓
latenza ↑

Quindi la frequenza massima non è sufficiente per scegliere la configurazione.

Occorre considerare il throughput complessivo:

throughput ≈ MAC_per_cycle × clock_frequency

A parità di quattro neuroni:

P2
8 MAC × 87.88 MHz
≈ 703 M MAC/s
P4
16 MAC × 75.01 MHz
≈ 1.20 G MAC/s
P8
32 MAC × 61.71 MHz
≈ 1.97 G MAC/s
P16
64 MAC × 52.13 MHz
≈ 3.34 G MAC/s

Questi valori sono una misura teorica del throughput del datapath MAC, non ancora del throughput end-to-end della rete, perché non includono i limiti della memoria esterna, del trasferimento dei pesi e del controller.

15. Scelta architetturale

Il risultato più importante del benchmark è che PARALLEL=8 rimane il candidato naturale per l'architettura V1 se l'obiettivo iniziale di progetto è mantenere circa:

32 MAC simultanei

Infatti:

PARALLEL = 8
N_NEURONS = 4

→ 32 MAC
→ 32 DSP / 72
→ 61.71 MHz

L'utilizzo DSP è ancora relativamente basso:

44% circa

lasciando risorse per:

controller memoria;
buffer;
interfaccia SPI;
DMA;
gestione layer;
eventuali pipeline;
future funzioni di controllo.

PARALLEL=2 è invece la configurazione più semplice da temporizzare tra quelle testate:

87.88 MHz

e passa il target di 80 MHz.

Tuttavia richiede:

128 gruppi

per elaborare un neurone da 256 ingressi.

Per questo motivo non è opportuno adottarlo automaticamente come configurazione definitiva solo perché raggiunge la frequenza più elevata.

16. Timing a 100 MHz

Il target di:

100 MHz

non viene attualmente raggiunto.

Il miglior risultato è:

87.88 MHz

con PARALLEL=2.

Il percorso critico è ancora:

weight FF
    ↓
MULT18X18D
    ↓
products
    ↓
adder/carry chain
    ↓
acc_next
    ↓
ReLU / saturation
    ↓
output FF

Il problema non è quindi un'elevata occupazione delle risorse FPGA.

Al contrario, con P2 l'FPGA è utilizzato molto poco:

DSP ≈ 11%
LUT ≈ 1%
FF  ≈ 0%

Il limite è principalmente temporale e dipende dal datapath combinazionale.

Per superare 100 MHz sarà probabilmente necessario introdurre una o più pipeline interne.

Questa ottimizzazione non è però ancora necessaria per procedere con la prossima fase architetturale.

17. Vincoli LPF

Durante questi benchmark il file:

synth/ecp5/top.lpf

è stato lasciato senza vincoli di pin.

nextpnr viene eseguito con:

--lpf-allow-unconstrained

Pertanto i numerosi warning relativi a I/O non vincolate sono intenzionali.

Il benchmark verifica quindi:

sintesi
placement
routing
timing

e non:

pin assignment
I/O standard della scheda
signal integrity

I vincoli LPF reali verranno aggiunti quando sarà definito il pinout della scheda FPGA-Neural.

18. Decisione per la prossima fase

Non è utile proseguire con benchmark PARALLEL=1.

Il punto di interesse architetturale è già stato individuato.

La prossima fase deve spostare il progetto dal benchmark sintetico verso l'architettura reale:

                    HOST
                      │
                      │ SPI
                      ▼
              FPGA interface
                      │
                      ▼
               Memory interface
                      │
          ┌───────────┴───────────┐
          ▼                       ▼
      PSRAM 8 MB               FPGA BRAM
          │                       │
          └──────────┬────────────┘
                     ▼
                tile/buffer
                     │
                     ▼
                 MAC engine
                     │
                     ▼
                accumulator
                     │
                     ▼
                 activation
                     │
                     ▼
                  output

Il core layer e neuron_parallel dovrà quindi essere separato dalla memoria fisica attraverso una Memory Interface.

19. Memoria V1

La memoria di lavoro prevista è:

ISSI IS66WVE4M16EBLL-70BLI

Caratteristiche:

64 Mbit
8 MB
4M × 16
parallel PSRAM
asynchronous/page mode
70 ns
2.7–3.6 V
48-TFBGA
6 × 8 mm

La memoria volatile sarà utilizzata come working memory durante l'inferenza.

La memoria persistente prevista è:

Winbond W25Q128JVS

con:

128 Mbit
16 MB
SPI NOR Flash

La divisione dei ruoli è:

W25Q128JVS
    ↓
persistent storage
    ↓
weights
biases
network metadata
FPGA/network configuration

e:

IS66WVE4M16EBLL
    ↓
runtime working memory
    ↓
input/output tensors
intermediate data
weight tiles

Infine:

FPGA BRAM
    ↓
local working buffers
tiles
accumulators
20. Conclusioni

La fase di caratterizzazione del datapath ha prodotto i seguenti risultati:

Il datapath INT8/INT32 è funzionalmente corretto.
Il test parametrico è passato.
Il balanced adder tree ha sostituito con successo la precedente riduzione lineare.
Il design è sintetizzabile per LFE5U-45F.
Il placement e routing sono stati completati correttamente.
Il problema iniziale delle migliaia di I/O è stato eliminato spostando i test vector all'interno del wrapper.
PARALLEL=8 implementa esattamente 32 MAC simultanei con quattro neuroni.
PARALLEL=2 raggiunge 87.88 MHz e supera il target di 80 MHz.
Il limite attuale a 100 MHz è dovuto al percorso combinazionale, non alla saturazione delle risorse FPGA.
Non è necessario continuare il benchmark verso PARALLEL=1.

La baseline architetturale rimane quindi:

LFE5U-45F-8BG381C
INT8 / INT32
256 inputs
4 neurons
PARALLEL parametrico

con:

PARALLEL = 8

come candidato principale per la configurazione orientata al throughput e:

PARALLEL = 2

come riferimento per la configurazione orientata alla frequenza.

La prossima attività significativa è l'integrazione della Memory Interface con la PSRAM esterna, mantenendo PARALLEL come parametro del motore computazionale.

Appendice A — Toolchain
Yosys

Yosys è il tool di sintesi RTL.

Flusso:

Verilog RTL
    ↓
elaborazione
    ↓
ottimizzazione
    ↓
mapping ECP5
    ↓
JSON netlist

Versione utilizzata:

Yosys 0.68+post

Binary:

/opt/homebrew/bin/yosys
Project Trellis

Project Trellis fornisce il database open-source dell'architettura ECP5 e gli strumenti necessari all'implementazione.

Tra gli strumenti disponibili:

ecppack
ecppll
ecpbram
ecpunpack

Installazione utilizzata:

/tmp/prjtrellis/install
nextpnr-ecp5

nextpnr-ecp5 esegue:

placement
routing
timing analysis

Versione:

nextpnr-0.11.1-19-g8dbcee5

Binary:

/tmp/nextpnr/build/nextpnr-ecp5

Parametri principali:

--45k

seleziona LFE5U-45F.

--package CABGA381

seleziona il package.

--speed 8

seleziona speed grade -8.

--json

carica la netlist generata da Yosys.

--lpf

carica i vincoli di pin.

--lpf-allow-unconstrained

permette I/O non vincolate.

--freq 80

richiede un timing target di 80 MHz.

Icarus Verilog

Icarus Verilog viene utilizzato per la simulazione RTL.

Esempio:

iverilog -g2012 \
  -Ptb.PARALLEL=16 \
  -o sim/parametric_256x4_p16 \
  sim/parametric_tb.v \
  rtl/mac_unit.v \
  rtl/mac8.v \
  rtl/neuron_parallel.v \
  rtl/layer.v

Esecuzione:

vvp sim/parametric_256x4_p16

Icarus verifica principalmente la correttezza funzionale del RTL.

Appendice B — Differenza tra simulazione e implementazione
Simulazione
Icarus Verilog

verifica:

algebra signed;
prodotti;
accumulazione;
gruppi;
bias;
ReLU;
saturazione;
segnali busy e done.
Implementazione
Yosys
+
nextpnr-ecp5

verifica:

sintetizzabilità;
mapping FPGA;
LUT;
FF;
DSP;
placement;
routing;
timing;
Fmax.

Le due verifiche sono complementari.
 r
Appendice C — Stato attuale
RTL funzionale              PASS
Simulazione parametrica     PASS
Sintesi ECP5                PASS
Placement                   PASS
Routing                     PASS

PARALLEL=16                 52.13 MHz
PARALLEL=8                  61.71 MHz
PARALLEL=4                  75.01 MHz
PARALLEL=2                  87.88 MHz

Target 80 MHz, P2           PASS
Target 100 MHz              FAIL

Memory Interface            PASS (implementata, vedi Appendice D)
PSRAM controller            PASS (implementata, page mode incluso dal 2026-09-03, vedi Appendice D)
Host SPI interface          DA IMPLEMENTARE
Layer engine reale          PROSSIMA FASE

Appendice D — PSRAM page mode (2026-09-03)

Contesto: il chip di memoria previsto (ISSI IS66WVE4M16EBLL-70BLI,
§19) è "asynchronous/page mode", ma `rtl/psram_controller.v` fino a
questa data usava solo l'accesso asincrono a parola singola — ogni
transazione pagava sempre i 70ns pieni (`tAA`), il page mode non era
usato. Verificato leggendo il datasheet reale della famiglia
(IS66WVE1M16BLL, stesso layout di registro di configurazione/CR
della famiglia BLL — 4M×16 vs 1M×16 cambia solo la densità
dell'array, non la logica di page mode/CR): pagina di 16 word
(`A[3:0]`), `tAPA`/`tPC` = 20ns per accessi successivi nella stessa
pagina invece di `tAA` = 70ns, page mode disabilitato di default
all'accensione (serve un caricamento esplicito del registro di
configurazione).

Implementato in `rtl/psram_controller.v` (dettagli in WORKLOG.md,
sezione "PSRAM page mode"), interamente interno al controller —
nessuna modifica a `memory_interface.v`/`int8_memory_access.v`/
`mem_arbiter.v` o a chi li usa.

Banda del gather `graph_engine` (`sim/graph_engine_bandwidth_tb.v`,
stesso benchmark già citato in "Bitstream reale + banda del gather"),
misurata prima/dopo isolando i soli due file toccati con `git
stash`:

```text
                  PRIMA (no page mode)   DOPO (page mode)   Δ
cicli/edge        53.25                  37.53              -29.5%
edge/s  @80MHz     1 502 347              2 131 557          +41.9%
banda   @80MHz     6.01 MB/s              8.53 MB/s          +41.9%
edge/s  @16MHz*      300 469                426 311          +41.9%
banda   @16MHz*    1.20 MB/s              1.71 MB/s          +41.9%
```
\* oscillatore reale raccomandato, `docs/FPGA-Neural-Hardware-Design.md` §4.

Nota: il primo tentativo di implementazione (chiusura pagina anche
sul cambio di `LB#`/`UB#`) misurava **61.25 cicli/edge, peggio del
"prima"** — regressione reale, trovata proprio grazie a questo
benchmark prima di considerare il lavoro finito, poi corretta (vedi
WORKLOG.md per il dettaglio).

Impatto risorse ECP5 (Yosys `synth_ecp5`):

```text
                     PRIMA         DOPO          Δ
psram_controller.v (isolato)
  LUT4               63            290           +227
  TRELLIS_FF         83            141           +58
  CCU2C               7             12           +5

spi_neuron_top (sistema completo, Tipo #2, PARALLEL=2)
  LUT4              2367          2619           +252
  TRELLIS_FF        2406          2467           +61
  DP16KD               2             2            0
  MULT18X18D           4             4            0
```

Su un dispositivo da ~43.8k LUT4 equivalenti l'incremento resta sotto
il 6% di utilizzo totale — nessun impatto pratico sul budget
risorse. Nessuna DP16KD/MULT18X18D aggiuntiva (il page mode è pura
logica di controllo, non tocca la datapath).

Fmax reale (`nextpnr-ecp5`, stesso comando/vincoli già validati in
"Bitstream reale + banda del gather" e nell'entry "Pin fisici
IRQ_N/DATA_READY_N", `spi_neuron_top`, Tipo #2), misurata sia a
PARALLEL=2 sia a PARALLEL=8 per completezza (prima c'era solo P2):

```text
            PRIMA (sessione precedente)   DOPO (con page mode)
P2          55.59 MHz                     75.73 MHz
P8          non misurato in questa serie  65.13 MHz
```

Entrambe ancora FAIL all'obiettivo 80MHz, ma P2 è **migliore**, non
peggiore, rispetto a prima di questa sessione. Il percorso critico è
stato verificato esplicitamente leggendo il report `nextpnr-ecp5` per
entrambe le configurazioni, non assunto: la sorgente in entrambi i
casi è `u_graph_engine.u_neuron.group_index` → catena
`mac8`/`neuron_parallel` (lo stesso accumulatore CCU2C già
identificato in Fase 7) — **`psram_controller` non compare mai nel
percorso critico**, nonostante la crescita di risorse del page mode.
Coerente con quanto stabilito nello sweep di seed di Fase 7
(`FPGA-NeuralNetwork-Engine.md` §15): il collo di bottiglia resta la
catena di accumulo di `neuron_parallel.v`, non lo stack PSRAM.

**Verifica `tCEM` rafforzata** (richiesta esplicita dell'utente, dopo
il lavoro sopra): `sim/psram_model.v` non aveva un controllo
indipendente sul limite di 8µs di CE# basso — solo il controller lo
rispettava, senza una rete di sicurezza nel modello di test.
Aggiunto un check dedicato (`TCEM_NS = 8000.0`, verificato sia a fine
sessione sia a metà burst) e un test dedicato che tiene una pagina
aperta per centinaia di letture consecutive, mai idle, fino a
superare il budget interno del controller: split confermato (8
chiusure di CE# durante il singolo burst), nessuna violazione
rispetto al limite reale del modello — margine reale, non per
coincidenza. Aggiungere questo controllo ha smascherato una race
Verilog genuina nel modello stesso (due processi indipendenti
triggerati nello stesso istante di simulazione, ordine di esecuzione
non definito dallo standard — non un bug del controller), corretta
con la tecnica standard (`#0` di sincronizzazione). Dettagli completi
in `WORKLOG.md`, sezione "PSRAM page mode — giro di rigore
aggiuntivo".

Tentata anche la ri-esecuzione del benchmark di parallelizzazione
P2/P4/P8 isolato (`tools/fpga_benchmark.py`) per completezza — quel
benchmark sintetizza solo
`mac_unit.v`/`mac8.v`/`neuron_parallel.v`/`layer.v`, non tocca
`psram_controller.v`. Il sotto-processo Yosys per P8 è incappato in
una patologia nota di `abc -g simple` sul netlist completamente
srotolato (256×4×32 MAC), superando le 2 ore di CPU senza terminare;
interrotto, non riprodotto in questa sessione. **Verificato non
essere un effetto del lavoro di oggi** (stesso script, stesso RTL di
input di prima, nessuna modifica su quel percorso). I numeri storici
restano validi perché deterministici su input invariati:

```text
PARALLEL=16   52.13 MHz
PARALLEL=8    61.71 MHz
PARALLEL=4    75.01 MHz
PARALLEL=2    87.88 MHz
```