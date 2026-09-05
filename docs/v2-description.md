FPGA-Neural V2 — Neural Multiprocessor / Dataflow Architecture
Obiettivo

Progettare e implementare una V2 dell'acceleratore neurale FPGA contenuto nel repository:

https://github.com/manvalan/FPGA-Neural

La V2 deve evolvere l'architettura V1 trasformandola da un acceleratore principalmente sequenziale a una Neural Multiprocessor / Dataflow Machine, mantenendo V1 come implementazione di riferimento funzionante.

L'obiettivo non è semplicemente aumentare PARALLEL.

L'obiettivo è costruire un'architettura composta da:

molteplici Neural Processor / Perceptron Processor indipendenti;
un Neural Director / Orchestrator;
un Dependency Manager;
un Memory Manager;
buffer locali e FIFO;
prefetch;
forwarding dei risultati;
pipeline interne ai Neural Processor;
esecuzione concorrente di più neuroni;
gestione dinamica delle dipendenze;
capacità di eseguire reti regolari, DAG, fuzzy network e strutture con dipendenze non strettamente sequenziali.

Il sistema deve essere progettato come una piccola macchina dataflow neurale, non come una semplice versione più larga dell'architettura V1.

1. Regola fondamentale: V1 è il Golden Reference

La V1 funzionante deve essere conservata integralmente.

Non modificare, cancellare o degradare la V1 per implementare la V2.

Struttura obbligatoria:

hardware/
├── v1/
│   ├── rtl/
│   ├── sim/
│   ├── constraints/
│   ├── synthesis/
│   └── ...
│
└── v2/
    ├── rtl/
    ├── sim/
    ├── constraints/
    ├── synthesis/
    ├── reports/
    ├── scripts/
    ├── logs/
    └── docs/

La V1 deve essere utilizzata come:

riferimento funzionale;
riferimento numerico;
riferimento prestazionale;
riferimento per i test bit-exact;
baseline per valutare ogni modifica V2.
2. Hardware target

Target FPGA:

Lattice ECP5U LFE5U-45F-8BG381

La progettazione deve tenere conto delle caratteristiche reali del dispositivo.

Non assumere che una maggiore quantità di DSP/logic implichi automaticamente maggiore prestazione.

Il limite può essere:

timing;
routing;
fanout;
congestione;
memoria;
larghezza dei bus;
mux;
distribuzione dei segnali;
interconnessioni tra blocchi.

Ogni scelta importante deve quindi essere verificata con sintesi e place-and-route reali.

3. Baseline V1

La V1 attuale contiene, tra gli altri:

rtl/neuron_parallel.v
rtl/mac8.v
rtl/mac_unit.v
rtl/neuron_memory.v
rtl/layer_sequencer.v
rtl/graph_engine.v
rtl/act_buffer.v
rtl/psram_controller.v
rtl/int8_memory_access.v
rtl/memory_interface.v
rtl/mem_arbiter.v
rtl/spi_neuron_top.v

La V1 utilizza:

INT8;
accumulazione INT32;
PARALLEL=8;
MAC paralleli;
adder tree bilanciato;
bias;
activation;
saturazione INT8;
memoria PSRAM/CellularRAM esterna.

Dati reali già osservati nella V1:

P16  ≈ 52.13 MHz
P8   ≈ 61.71 MHz
P4   ≈ 75.01 MHz
P2   ≈ 87.88 MHz

in una configurazione isolata N_INPUTS=256.

Nel sistema integrato:

P8 ≈ 65.13 MHz

con failure rispetto a un target di 80 MHz.

Il critical path osservato è principalmente legato alla logica del neuron_parallel e alla sua interconnessione, non al controller PSRAM.

Questi dati devono essere considerati misure reali V1, non risultati V2.

4. Architettura V2

La V2 deve essere organizzata in due piani.

Control Plane
Neural Director
      │
      ├── Scheduler
      ├── Dependency Manager
      ├── Ready Queue
      ├── Waiting Queue
      └── Processor State
Data Plane
                 ┌─────────────────────┐
                 │   Memory Manager    │
                 └──────────┬──────────┘
                            │
               ┌────────────┼────────────┐
               │            │            │
             Buffer       Buffer       Buffer
             Input        Weight       Result
               │            │            │
               └────────────┼────────────┘
                            │
       ┌────────────┬───────┴───────┬────────────┐
       │            │               │            │
      NP0          NP1             NP2          NP3
       │            │               │            │
       └────────────┴───────────────┴────────────┘
                            │
                       Result/Forward

Il numero di processor non deve essere deciso a priori.

Deve essere determinato tramite sweep di sintesi e timing.

5. Neural Processor

Il Neural Processor è l'unità fondamentale della V2.

Ogni processor deve essere autonomo e indipendente.

Un processor esegue un neurone alla volta, ma il datapath interno deve essere pipelineizzato.

Configurazione iniziale:

P_IN = 8

Ogni processor inizialmente deve avere:

8 × INT8 multiplier
balanced adder tree
INT32 accumulator
bias
activation
INT8 saturation
local operand registers/FIFO
job interface
result interface

Pipeline iniziale candidata:

Stage 0  input alignment/register
Stage 1  8 multipliers
Stage 2  adder tree level 1
Stage 3  adder tree level 2
Stage 4  adder tree level 3
Stage 5  accumulator
Stage 6  bias / activation
Stage 7  output / saturation

La pipeline può essere modificata se le simulazioni e il timing dimostrano una soluzione migliore.

L'obiettivo principale è il throughput, non la minima latenza possibile.

6. Neural Processor FSM

Ogni Neural Processor deve avere una macchina a stati chiaramente definita.

Baseline:

NP_IDLE
NP_LOAD_JOB
NP_WAIT_OPERANDS
NP_LOAD_TILE
NP_MAC
NP_ACCUM
NP_NEXT_TILE
NP_FINISH
NP_WRITE_RESULT
NP_DONE
NP_ERROR
NP_IDLE

Processor libero e disponibile.

NP_LOAD_JOB

Caricamento del job descriptor.

Inizializzazione:

node ID;
numero input;
indirizzo input;
indirizzo pesi;
bias;
activation;
tile count;
accumulator.
NP_WAIT_OPERANDS

Attesa degli operandi.

Il processor deve poter rimanere bloccato senza impedire agli altri processor di lavorare.

NP_LOAD_TILE

Caricamento di un tile locale.

NP_MAC

Esecuzione del datapath MAC pipeline.

NP_ACCUM

Aggiornamento dell'accumulatore.

NP_NEXT_TILE

Richiesta del tile successivo.

Il Memory Manager dovrebbe averlo già prefetched.

NP_FINISH

Bias, activation e saturazione.

NP_WRITE_RESULT

Handshake con Memory Manager / result path.

NP_DONE

Il processor ritorna disponibile.

NP_ERROR

Gestione degli errori senza bloccare globalmente il sistema.

7. Interfacce del Neural Processor

Evitare grandi mux dinamici come quelli dell'architettura V1.

Preferire:

valid
ready
data
last

per gli stream.

Input:

operand_valid
operand_ready
input_data
weight_data
tile_last

Output:

result_valid
result_ready
result_data
node_id

La validità deve essere pipelineizzata insieme ai dati.

Non assumere ritardi fissi senza handshake o valid propagation.

8. Neural Processor Array

Creare:

hardware/v2/rtl/neural_processor_array.v

Il modulo deve permettere:

N_PROCESSORS = parametrico
P_IN         = parametrico

Configurazioni iniziali:

1 × P8
2 × P8
4 × P8
8 × P8

Successivamente esplorare configurazioni maggiori se timing e risorse lo consentono.

Esempi teorici:

4 × P8 = 32 MAC/cycle
8 × P8 = 64 MAC/cycle

Questi sono solo valori teorici.

Non presentarli mai come throughput misurato.

9. Neural Director / Orchestrator

Creare:

hardware/v2/rtl/neural_director.v

Il Director controlla l'intero sistema.

Responsabilità:

ricezione dei job;
scansione dei job READY;
scelta del processor libero;
assegnazione;
tracking dello stato dei processor;
gestione delle dipendenze;
rilevamento dei completamenti;
wake-up dei job;
gestione ready queue;
gestione waiting queue;
prevenzione dei deadlock;
massimizzazione dell'utilizzo dei processor.

FSM iniziale:

DIR_IDLE
DIR_SCAN_READY
DIR_ALLOCATE
DIR_WAIT_DEPENDENCY
DIR_MONITOR
DIR_COMPLETE
DIR_WAKEUP
DIR_ERROR

Scheduling iniziale:

first-free

Successivamente valutare:

round-robin
least-loaded
locality-aware
priority-based
dependency-aware

La politica migliore deve essere determinata sperimentalmente.

10. Dependency Manager

Creare:

hardware/v2/rtl/dependency_manager.v

Ogni nodo deve avere almeno:

node_id
state
required_dependencies
resolved_dependencies
producer_information

Esempio:

node 37
required = 4
resolved = 3
state = WAITING

Quando arriva il quarto risultato:

resolved = 4
state = READY

Il nodo può quindi essere assegnato dal Director.

Il sistema deve supportare:

dipendenze multiple;
risultati condivisi;
più consumer;
wake-up;
forwarding;
backpressure.
11. Dataflow e token

Il modello concettuale deve supportare token:

TOKEN
├── node_id
├── value
└── valid

Quando un processor produce un risultato:

Producer
   │
   ├──→ Consumer FIFO
   │
   └──→ Result Buffer

Quando possibile il dato deve essere inoltrato direttamente al consumer senza obbligare il sistema a fare:

processor
→ external memory
→ memory controller
→ buffer
→ processor

Il risultato può essere contemporaneamente:

forwarded;
memorizzato;
utilizzato da più consumer.
12. Memory Manager

Creare:

hardware/v2/rtl/memory_manager.v

Il Neural Processor non deve accedere direttamente alla PSRAM.

Il Memory Manager deve occuparsi di:

input activations;
weights;
results;
prefetch;
buffering;
FIFO;
arbitration;
forwarding;
gestione latenza;
double buffering;
memory request scheduling.

Il processor deve vedere principalmente:

data available

e non:

PSRAM latency
13. Prefetch

Creare:

hardware/v2/rtl/prefetch_engine.v

Usare inizialmente una strategia:

compute tile N
      │
      └── concurrently ──→ prefetch tile N+1

Con double buffering:

Buffer A → COMPUTE
Buffer B → PREFETCH

swap

Buffer B → COMPUTE
Buffer A → PREFETCH

Priorità:

HIGH    operand required now
MEDIUM  next tile
LOW     future tile
14. Buffer

Creare:

hardware/v2/rtl/activation_buffer.v
hardware/v2/rtl/weight_buffer.v
hardware/v2/rtl/result_buffer.v

La profondità deve essere parametrica.

Valutare anche:

FIFO depth
buffer depth
numero porte
BRAM mapping
routing
timing

Non assumere che buffer più grandi siano automaticamente migliori.

15. Memoria esterna

NON iniziare modificando il controller PSRAM.

Mantenere inizialmente il backend esistente.

Astrarre il Memory Manager dal backend:

Memory Manager
      │
      ▼
Memory Backend Interface
      │
      ▼
PSRAM Controller

Solo dopo aver misurato il sistema V2 valutare eventuali alternative:

SRAM;
PSRAM;
SDRAM;
DDR;
QSPI;
altre memorie o risorse esterne.

Qualsiasi modifica hardware esterna deve essere motivata da dati reali.

16. Parallelismo

Due parametri fondamentali:

P_IN
N_PROCESSORS

P_IN indica il numero di MAC paralleli dentro un Neural Processor.

N_PROCESSORS indica quanti Neural Processor operano contemporaneamente.

Eseguire sweep almeno su:

P_IN = 2, 4, 8

e:

N_PROCESSORS = 1, 2, 4, 6, 8, 12, 16...

fino al limite imposto da:

LUT;
FF;
DSP;
BRAM;
routing;
timing.

La configurazione finale deve essere scelta sulla base del throughput effettivo, non dell'utilizzo massimo delle risorse.

17. Dataflow Core

Creare:

hardware/v2/rtl/dataflow_core.v

Il modulo integra:

Neural Director
Dependency Manager
Memory Manager
Prefetch Engine
Neural Processor Array
Activation Buffer
Weight Buffer
Result Buffer

Architettura:

                  JOBS
                   │
                   ▼
          ┌─────────────────┐
          │ Neural Director │
          └───────┬─────────┘
                  │
          ┌───────▼─────────┐
          │   Dependency    │
          │    Manager      │
          └───────┬─────────┘
                  │
                  ▼
          ┌─────────────────┐
          │ Memory Manager  │
          └───────┬─────────┘
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
       NP0       NP1       NP...
        │         │         │
        └─────────┼─────────┘
                  │
                  ▼
              RESULTS
18. Scheduling dinamico

Il sistema deve permettere che:

NP0 → node A
NP1 → node B
NP2 → node C
NP3 → WAIT

Se NP3 attende un risultato:

NP3 WAIT

non deve bloccare:

NP0
NP1
NP2

Quando il risultato arriva:

Producer
   ↓
Dependency Manager
   ↓
dependency resolved
   ↓
job READY
   ↓
Director
   ↓
free processor
19. Supporto a reti diverse

L'architettura deve essere sufficientemente generale per supportare:

Layer regolari
input → layer → layer → output
DAG
       ┌── node B ──┐
node A ┤            ├→ node E
       └── node C ──┘
Fuzzy network

con dipendenze irregolari e numero variabile di ingressi.

Cloud / sparse graph

con nodi attivati dinamicamente.

Non costruire il sistema assumendo esclusivamente una rete fully-connected regolare.

20. Simulazione obbligatoria

Ogni componente deve avere un testbench.

Creare:

hardware/v2/sim/
├── tb_neural_processor.v
├── tb_neural_processor_array.v
├── tb_memory_manager.v
├── tb_prefetch_engine.v
├── tb_dependency_manager.v
├── tb_neural_director.v
└── tb_dataflow_core.v

Test obbligatori:

test funzionali;
random test;
extreme INT8;
pipeline;
stall;
backpressure;
dependency;
wake-up;
forwarding;
multi-processor concurrency;
deadlock detection;
data-loss detection;
bit-exact comparison con V1.

Valori INT8 da includere:

-128
-127
-1
0
1
126
127
21. Test bit-exact

Ogni risultato V2 deve essere confrontabile con V1.

Per gli stessi:

inputs
weights
bias
activation
network

deve essere verificato:

V1 result == V2 result

salvo differenze esplicitamente documentate e matematicamente giustificate.

22. Performance simulation

La simulazione deve misurare almeno:

total_cycles
compute_cycles
stall_cycles
memory_wait_cycles
processor_busy_cycles
processor_idle_cycles
completed_neurons
completed_tiles
processor_utilization
memory_utilization
effective_throughput
stall_percentage

Eseguire anche sweep della latenza memoria:

0 cycles
1 cycle
2 cycles
4 cycles
8 cycles
16 cycles

L'obiettivo è misurare quanto efficacemente il prefetch nasconde la latenza.

23. Sintesi e Place & Route

Ogni configurazione deve essere realmente verificata con:

Icarus / Verilator
Yosys
nextpnr-ecp5

Non inventare risultati.

Non stimare il timing come se fosse una misura.

Distinguere sempre:

THEORETICAL
RTL SIMULATION
SYNTHESIS
POST-P&R MEASUREMENT

Il valore Fmax ufficiale della configurazione deve provenire dal place-and-route reale.

24. Benchmark

Per ogni configurazione creare:

hardware/v2/reports/
├── simulation/
├── synthesis/
├── timing/
└── experiments/

Esempio:

hardware/v2/reports/experiments/EXP-0001/
├── experiment.yaml
├── simulation.log
├── synthesis.log
├── timing.log
├── results.txt
└── notes.md

Ogni benchmark deve contenere almeno:

Fmax
processors
P_IN
MAC/cycle
LUT
FF
DSP
BRAM
cycles/neuron
neurons/s
stall %
effective MAC/s
25. LOGGING OBBLIGATORIO
Questa è una regola fondamentale del progetto.

OGNI attività significativa deve essere registrata.

Nessuna modifica, simulazione, sintesi, benchmark, decisione architetturale o errore deve essere perso.

Creare:

hardware/v2/logs/
├── development.log
├── architecture.log
├── simulation.log
├── synthesis.log
├── timing.log
├── benchmark.log
├── decisions.log
├── experiments.log
└── errors.log

Il registro principale deve essere:

hardware/v2/logs/experiments.log

Ogni esperimento deve avere un identificativo univoco:

EXP-0001
EXP-0002
EXP-0003
...

Gli ID non devono essere riutilizzati.

26. Contenuto minimo di ogni log

Ogni evento significativo deve contenere:

timestamp
experiment_id
git_commit
session/agent
module
configuration
action
reason
command
result
errors
decision
next_action

Per synthesis/timing includere anche:

LUT
FF
DSP
BRAM
Fmax
critical path
WNS/TNS se disponibili

Per simulazione:

test
vectors
cycles
PASS/FAIL
bit-exact result
stall cycles
memory wait
utilization
27. Logging delle decisioni

Ogni scelta architetturale importante deve essere registrata in:

hardware/v2/logs/decisions.log

Formato concettuale:

DEC-0001

DATE:
...

DECISION:
Use 4 independent P8 Neural Processors.

WHY:
...

EVIDENCE:
EXP-0001
EXP-0002
EXP-0003

ALTERNATIVES:
P4 × 8
P8 × 4
P16 × 2

RESULT:
...

STATUS:
ACCEPTED

Le decisioni devono essere basate su dati quando possibile.

28. Nessuna sovrascrittura dei risultati

I risultati precedenti non devono essere cancellati o sovrascritti.

Se:

EXP-0017 = PASS
EXP-0018 = FAIL
EXP-0019 = PASS

tutti e tre devono rimanere.

Un risultato negativo è comunque un risultato utile.

Deve essere possibile ricostruire la storia:

idea
↓
implementazione
↓
test
↓
fallimento/successo
↓
modifica
↓
nuovo test
↓
decisione
29. Riproducibilità

Ogni esperimento deve essere riproducibile.

Il log deve permettere di sapere:

quale commit
quale configurazione
quali parametri
quale toolchain
quale comando
quale testbench
quali constraint
quale risultato

Ogni report deve essere associato al commit Git utilizzato.

Se il working tree contiene modifiche non committate, questo deve essere esplicitamente registrato.

30. Regola contro risultati inventati

È vietato presentare dati non misurati come dati reali.

Esempio:

4 × P8 @ 80 MHz = 2.56 GMAC/s

deve essere indicato:

THEORETICAL

Finché non esiste una misura reale.

Un risultato:

Fmax = 83.7 MHz

può essere dichiarato misurato solo se ottenuto da:

nextpnr-ecp5

con relativa configurazione e report salvati.

31. Sweep automatici

Creare:

hardware/v2/scripts/sweep/

Gli script devono poter eseguire automaticamente combinazioni di:

P_IN
N_PROCESSORS
FIFO depth
buffer depth
pipeline configuration

e produrre automaticamente:

simulation
synthesis
place-and-route
timing
resource utilization
benchmark

Ogni configurazione deve generare un proprio:

EXP-XXXX

e registrarlo nei log.

32. Confronto V1 vs V2

Il benchmark finale deve produrre una tabella:

                 V1       V2
------------------------------------
Fmax
LUT
FF
DSP
BRAM
MAC/cycle
cycles/neuron
neurons/s
stall %
memory utilization
processor utilization
effective MAC/s

Ogni numero deve essere classificato come:

THEORETICAL
SIMULATED
SYNTHESIZED
POST-P&R
33. Roadmap di implementazione
M1 — Neural Processor

Implementare:

hardware/v2/rtl/neural_processor.v

P8.

Input forniti direttamente dal testbench.

Obiettivo:

bit-exact V1
pipeline funzionante

Eseguire simulation + synthesis + timing.

M2 — Processor Array

Implementare:

neural_processor_array.v

Testare:

1
2
4
8

processor.

Misurare:

timing;
risorse;
throughput;
utilization.
M3 — Buffers

Implementare:

activation_buffer.v
weight_buffer.v
result_buffer.v
M4 — Memory Manager

Implementare:

memory_manager.v
prefetch_engine.v

Inizialmente utilizzare il backend PSRAM esistente.

M5 — Neural Director

Implementare:

neural_director.v

Scheduling iniziale:

first-free
M6 — Dependency Manager

Implementare:

dependency_manager.v

Aggiungere:

ready;
waiting;
dependency counters;
wake-up;
producer tracking.
M7 — Dataflow Core

Integrare:

dataflow_core.v
M8 — PSRAM integration

Integrare il controller V1 senza modificarlo inizialmente.

Misurare il comportamento reale.

M9 — Full benchmark

Confrontare V1/V2.

M10 — Optimization

Solo sulla base dei dati:

pipeline;
P_IN;
numero processor;
buffer;
FIFO;
scheduling;
prefetch;
routing;
memoria.
34. Principi architetturali non negoziabili
V1 rimane intatta.
V2 vive esclusivamente sotto hardware/v2/....
Nessun risultato inventato.
Ogni misura deve provenire dagli strumenti appropriati.
Ogni modifica deve essere registrata.
Ogni esperimento deve avere un ID.
Nessun risultato precedente deve essere sovrascritto.
Ogni decisione importante deve avere una motivazione.
Ogni benchmark deve essere riproducibile.
Un processor bloccato non deve bloccare gli altri.
Il Neural Processor non deve conoscere direttamente la memoria esterna.
Il Director gestisce WHAT deve essere eseguito.
Il Memory Manager gestisce COME rendere disponibili i dati.
Il Neural Processor gestisce COME eseguire il calcolo.
Ottimizzare il throughput effettivo, non il numero di DSP utilizzati.
Evitare grandi mux e interconnessioni globali quando possibile.
Favorire località fisica e pipeline.
Le configurazioni devono essere esplorate sperimentalmente.
Ogni modifica deve essere confrontata con la baseline.
Il progetto deve mantenere una cronologia completa e ricostruibile dello sviluppo.
35. Filosofia finale

La V2 deve evolvere FPGA-Neural verso:

                 NEURAL DIRECTOR
                       │
          ┌────────────┼────────────┐
          │            │            │
       READY        WAITING      DEPENDENCY
        QUEUE        QUEUE        MANAGER
          │
          ▼
                  MEMORY MANAGER
                       │
             ┌─────────┼─────────┐
             │         │         │
          INPUT      WEIGHT    RESULT
          BUFFER     BUFFER    BUFFER
             │         │         │
             └─────────┼─────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
       NP0            NP1            NP...
        │              │              │
        └──────────────┼──────────────┘
                       │
                  DATAFLOW / FORWARD

Il risultato finale deve essere una macchina neurale parallela e dataflow, capace di mantenere occupati più Neural Processor contemporaneamente, nascondere la latenza della memoria, gestire dipendenze dinamiche e scalare il numero di processor in funzione dei limiti reali dell'ECP5.

Il processo di sviluppo deve essere completamente tracciabile:

IDEA
 ↓
ARCHITECTURE LOG
 ↓
IMPLEMENTATION
 ↓
SIMULATION
 ↓
SYNTHESIS
 ↓
PLACE & ROUTE
 ↓
MEASUREMENT
 ↓
EXPERIMENT LOG
 ↓
DECISION LOG
 ↓
NEXT EXPERIMENT

Non deve esistere una modifica "non registrata", una misura "senza report" o una decisione architetturale "senza motivazione".