# FPGA Neural Network Engine

Hardware Neural Network Engine based on FPGA + dedicated RAM.

The project implements a **parametric hardware accelerator for neural networks**, designed to be reusable across different embedded systems and applications.

The fundamental design principle is that the neural-network computation is performed entirely inside the FPGA, while the host system communicates with the engine through a simple hardware-independent interface such as SPI.

---

## 1. Project Goal

The goal of this project is to develop a reusable **Neural Network Engine implemented in FPGA hardware**.

The engine is composed of:

- FPGA;
- dedicated RAM connected to the FPGA;
- host interface, initially SPI and potentially Dual SPI.

The host system is not part of the neural-network computational datapath.

Possible host systems include:

- Linux SoCs;
- Raspberry-Pi-like systems;
- ESP32;
- microcontrollers;
- other embedded processors;
- development PCs.

The same Neural Network Engine architecture should therefore be usable in completely different systems.

```text
                    HOST SYSTEM
             ┌─────────────────────────┐
             │                         │
             │ Linux / ESP32 / MCU     │
             │                         │
             │ Configuration           │
             │ Training                │
             │ Control                 │
             └────────────┬────────────┘
                          │
                       SPI / Dual SPI
                          │
                          ▼
             ┌─────────────────────────┐
             │          FPGA           │
             │                         │
             │ Neural Network Engine   │
             │                         │
             │ Compute / Control       │
             │                         │
             └────────────┬────────────┘
                          │
                          │
                    Dedicated RAM
```

---

# 2. Architectural Principle

The FPGA is the actual neural-network accelerator.

The RAM required by the neural network is physically associated with the FPGA and is **not part of the host system memory**.

The host only provides:

- configuration;
- network parameters;
- input data;
- control;
- result retrieval.

The neural-network calculations themselves are executed by the FPGA.

This separation is a fundamental architectural requirement.

---

# 3. Hardware Configuration vs Network Configuration

An important distinction is made between the **hardware architecture of the accelerator** and the **parameters of the neural network**.

## 3.1 FPGA hardware configuration

The physical architecture of the Neural Network Engine is defined when the FPGA design is synthesized and implemented.

Typical hardware parameters include:

```text
N_INPUTS
N_NEURONS
N_LAYERS
PARALLEL
DATA_WIDTH
ACCUMULATOR_WIDTH
```

These parameters can therefore be Verilog/SystemVerilog parameters or equivalent synthesis-time configuration values.

For example:

```text
N_INPUTS  = 32
N_NEURONS = 4
PARALLEL  = 8
```

defines a specific hardware implementation optimized for that architecture.

The resulting FPGA bitstream contains the corresponding datapath.

---

## 3.2 Neural-network configuration

Once the FPGA has been configured and initialized, the actual neural-network parameters can be loaded through the host interface.

These parameters may include:

- weights;
- biases;
- activation parameters;
- quantization parameters;
- network-specific constants.

These values are stored in the RAM associated with the FPGA.

Therefore:

```text
FPGA BITSTREAM
        │
        │ defines hardware architecture
        ▼
┌─────────────────────┐
│ Neural Network      │
│ Hardware Engine     │
└──────────┬──────────┘
           │
           │ loads
           ▼
┌─────────────────────┐
│ Dedicated RAM       │
│                     │
│ weights             │
│ biases              │
│ parameters          │
│ buffers             │
└─────────────────────┘
```

This provides an important separation between **hardware specialization** and **network data**.

---

# 4. Application-Specific Neural Networks

The Neural Network Engine is not intended to implement one fixed neural network.

Instead, each application can define its own network.

For example:

```text
Application A
    16 inputs
    8 neurons
    1 output

Application B
    32 inputs
    16 neurons
    4 outputs

Application C
    64 inputs
    multiple layers
    custom parallelism
```

The FPGA hardware can then be generated specifically for the required architecture.

This allows the design to exploit the FPGA resources efficiently rather than implementing a completely generic and potentially inefficient neural-network processor.

---

# 5. Parametric Compute Engine

The current implementation contains a parametric neural-network layer.

A validated configuration is:

```text
N_INPUTS  = 32
N_NEURONS = 4
PARALLEL  = 8
```

The datapath processes the inputs in parallel groups.

Conceptually:

```text
32 inputs
    │
    ├── 8 parallel MACs
    │
    ├── 8 parallel MACs
    │
    ├── 8 parallel MACs
    │
    └── 8 parallel MACs
             │
             ▼
        Accumulation
             │
             ▼
           Bias
             │
             ▼
        Activation
             │
             ▼
          Output
```

The architecture is intended to scale by changing the synthesis parameters.

---

# 6. Current Functional Validation

The `32 × 4 / PARALLEL = 8` configuration has been successfully simulated.

Test output:

```text
========================================
PARAMETRIC LAYER TEST
N_INPUTS  = 32
N_NEURONS = 4
PARALLEL  = 8
========================================

PASS N0: 8192
PASS N1: 4096
PASS N2: 0 (ReLU)
PASS N3: 16384

========================================
PARAMETRIC TEST PASSED
========================================
```

Validated functionality:

- multiple inputs;
- multiple neurons;
- parallel MAC processing;
- accumulation across multiple input groups;
- bias handling;
- independent neuron outputs;
- ReLU activation;
- parametric layer architecture.

The corresponding test has been committed to the repository.

Commit:

```text
test: validate parametric 32x4 layer with parallelism 8
```

---

# 7. FPGA Boot and Initialization

The FPGA is configured during system initialization using its normal FPGA configuration mechanism.

The FPGA bitstream defines the hardware architecture of the Neural Network Engine.

Conceptually:

```text
Power-on
   │
   ▼
FPGA configuration
   │
   │ bitstream
   ▼
Neural Network Engine available
   │
   ▼
Host initialization
   │
   │ SPI
   ▼
Load network parameters
   │
   ▼
Load weights / biases
   │
   ▼
Engine ready
```

This means that the host does **not dynamically construct the FPGA datapath** during normal operation.

The datapath already exists in hardware.

The host configures the network data that the datapath operates on.

---

# 8. Host Interface

The primary external interface is intended to be:

```text
SPI
```

with possible future support for:

```text
Dual SPI
```

The interface must remain independent of the host operating system.

The same hardware protocol should therefore be usable from:

```text
Linux
ESP32
MCU
PC
```

The host interface should provide access to:

- control registers;
- status;
- network configuration;
- RAM;
- input data;
- output data;
- start/stop control;
- completion status.

A conceptual command sequence is:

```text
RESET
  │
  ▼
CONFIGURE
  │
  ▼
LOAD NETWORK PARAMETERS
  │
  ▼
LOAD WEIGHTS
  │
  ▼
LOAD BIASES
  │
  ▼
LOAD INPUT
  │
  ▼
START
  │
  ▼
WAIT FOR DONE
  │
  ▼
READ OUTPUT
```

## 8.1 SPI Protocol v1 (draft, 2026-09-02)

Concrete opcode-level draft of the section above, written before any
Phase 4 RTL. Opcode values and the exact set of commands are
illustrative/example at this stage, not frozen — the framing rules
(MSB-first, explicit length, sticky STATUS.done) and the two
decisions already made (explicit length field over CS-delimited
streaming; a runtime READ_CONFIG command) are the parts intended to
stick; the opcode table itself is expected to be revised as Phase 4
RTL work starts.

**Physical layer:** SPI Mode 0 (CPOL=0, CPHA=0), MSB-first, single
SPI for v1 (Dual SPI is a future extension per §8, not addressed
here). The FPGA is always SPI slave. One command per CS-low period;
byte 0 of every transaction is the opcode.

**Multi-byte fields** are big-endian (most significant byte first).
Byte addresses are `ADDR_WIDTH`-bit (23 bits today, from
`rtl/neuron_memory.v` — sized for a full 8 MiB PSRAM, see
`docs/FPGA-Neural-Hardware-Design.md` §3), carried in a 3-byte field
with the top bit reserved as 0.

**Length is explicit**, not CS-edge-delimited: `WRITE_RAM`/`READ_RAM`
carry a 2-byte length field, so the SPI controller only needs a byte
counter, not CS-edge detection mid-transfer.

### Opcode table

| Opcode | Name | Payload (host → FPGA) | Response (FPGA → host) | Function |
|---|---|---|---|---|
| 0x00 | NOP | — | — | No operation (idle/dummy clocking) |
| 0x01 | WRITE_RAM | addr(3B) + len(2B) + `len` data bytes | — | Write a block into PSRAM (X, weights, bias, network params). **No backpressure to the host** (known v1 limitation) — see the warning right after this table. |
| 0x02 | READ_RAM | addr(3B) + len(2B) | `len` data bytes | Read a block back from PSRAM |
| 0x0F | RESET | — | — | Synchronous reset pulse to the compute engine (`neuron_memory`) and clears the STATUS latch below. Does **not** erase PSRAM contents. Kept as a distinct opcode from NOP. |
| 0x10 | SET_BASE | sel(1B) + addr(3B) | — | Sets `x_base`(sel=0) / `w_base`(sel=1) / `bias_addr`(sel=2) / `table_base`(sel=3) / `buf_a_base`(sel=4) / `buf_b_base`(sel=5) / `activation`(sel=6) / `n_inputs_real`(sel=7) / `n_neurons_real`(sel=8) / `num_neurons_graph`(sel=9) / `n_out`(sel=10) — sel=6..8 are single-layer/manual-path registers only (RUN_NETWORK reads the equivalent fields per-layer from the descriptor table instead, dense mode). sel=6 uses only the low 2 bits of the low address byte (see `neuron_parallel.v`'s `ACT_*` localparams; reset default `ACT_RELU`). sel=7/8 use the low 2 of the 3 address bytes as a 16-bit BE value (reset default = this bitstream's build-time `N_INPUTS`/`N_NEURONS`) — see "Runtime network width" below. sel=9/10 (Phase G5, graph/Type#2 only) set `num_neurons_graph`/`n_out` the same 16-bit-BE-in-low-2-bytes way; `buf_a_base` (sel=4) is reused as `out_base` in graph mode (see `rtl/graph_engine.v`'s header). |
| 0x11 | SET_NET_TYPE | type(1B) | — | Phase G5: selects the network type `RUN_NETWORK` dispatches to — `0x01`=dense/Type#1 (`layer_sequencer`, default after RESET), `0x02`=graph/Type#2 (`graph_engine`). |
| 0x20 | START | — | — | Pulses `start` on `neuron_memory` directly (single-layer/manual path); ignored (no-op) if the engine is busy in any form (single-layer or a RUN_NETWORK job) |
| 0x21 | STATUS | — | 1 byte | bit0=`busy` (live, OR of the single-layer, RUN_NETWORK, and graph busy signals), bit1=`done` (**sticky, clear-on-read**; latches on the *final* layer's completion for a RUN_NETWORK job, not each intermediate layer — and now also on a completed flash op, see bit3), bit2=`graph_err` (Phase G5, §7 load-time guard; sticky until RESET or the next graph `run_start`, **not** clear-on-read), bit3=`flash_err` (flash subsystem, §8.3 below; **sticky, clear-on-read** like bit1), bit4=`flash_busy` (flash subsystem; **live**, not sticky), bits7:5 reserved=0 |
| 0x22 | READ_OUTPUT | — | `N_NEURONS` bytes | `y_bus`, neuron-major (byte 0 = neuron 0). Dense/Type#1 only — graph/Type#2 results are read back from PSRAM at `out_base` via `READ_RAM` instead (`graph_engine` has no `y_bus`). |
| 0x23 | RUN_NETWORK | num_layers(1B) | — | Dispatches to `layer_sequencer` (dense) or `graph_engine` (graph) based on the current `SET_NET_TYPE` selection. Dense (Phase 5): pulses `layer_sequencer`'s `run_start` to chain `num_layers` (1..N_LAYERS) runs of `neuron_memory` using the descriptor table at `table_base` and the ping-pong buffers at `buf_a_base`/`buf_b_base`; layer 0 reads from `x_base`. Each layer's activation (see below) is read per-layer from the descriptor table, independent of the single-layer path's `activation` register. Graph (Phase G5): `num_layers` payload byte is ignored (neuron count comes from `SET_BASE` sel=9 instead, so this opcode's byte framing stays identical for both types); pulses `graph_engine`'s own `run_start`. Ignored (no-op) if the engine is already busy in any form. |
| 0x30 | READ_CONFIG | — | 11 bytes | Hardware config record, see below |
| 0x40 | FLASH_READ_BLOCK | flash_addr(3B) + psram_addr(3B) + len(3B) | — | Flash subsystem (§8.3): copies `len` bytes flash→PSRAM, raw (no catalog/CRC). |
| 0x41 | FLASH_WRITE_BLOCK | psram_addr(3B) + flash_addr(3B) + len(3B) | — | Copies `len` bytes PSRAM→flash, raw — internal erase-before-write + ≤256B Page Program loop + WIP poll, transparent to the host. |
| 0x42 | FLASH_ERASE | sector_addr(3B) | — | Standalone 4KB sector erase (`sector_addr` must be sector-aligned). |
| 0x43 | CAT_READ | — | — | Reloads the on-chip slot catalog (16 entries) from the flash's reserved catalog sector. Fire-and-forget like every other flash op below — poll STATUS/`data_ready_n` for completion, then use `CAT_INSPECT` to actually read a slot's metadata back. |
| 0x44 | CAT_WRITE_SLOT | slot_id(1B) + offset(3B) + length(3B) + type(1B) | — | Registers/updates slot `slot_id`'s (offset, length, type) in the on-chip catalog and persists the whole catalog to flash. Marks the slot **invalid** (no verified data behind it yet) — `SAVE_SLOT` is what marks it valid. |
| 0x45 | LOAD_SLOT | slot_id(1B) + psram_addr(3B) | — | Resolves `slot_id`'s offset+length from the on-chip catalog and streams flash→PSRAM, verifying the CRC32 live against the catalog's stored value. `flash_err` (STATUS bit3) if the slot is invalid (no transaction attempted) or the CRC doesn't match. |
| 0x46 | SAVE_SLOT | slot_id(1B) + psram_addr(3B) + length(3B) | — | Streams `length` bytes PSRAM→flash at `slot_id`'s already-registered offset (via a prior `CAT_WRITE_SLOT`), computing the CRC32 live; on success updates the catalog entry (length, CRC, valid=1) and persists it. |
| 0x47 | CAT_INSPECT | slot_id(1B) | 16 bytes | **Added beyond the original catalog opcode draft** (not `CAT_READ` itself, which has no payload/response — see its own row above): synchronous read of one already-loaded catalog entry, same byte layout as the raw catalog-sector bytes (offset[3] + length[3] + type[1] + valid[1] + crc32[4] + reserved[4], MSB-first). |

**`WRITE_RAM`/`READ_RAM` have no backpressure to the host (known v1
limitation, real consequence found 2026-09-04):** each received/produced
byte must be fully processed by `spi_engine` before the next SCLK-driven
byte boundary arrives — reasonable for bulk-loading weights/inputs at
init, not a real-time path (see `rtl/spi_engine.v`'s own header). The
concrete risk this creates: if a host issues `WRITE_RAM`/`READ_RAM`
before `psram_controller`'s power-up sequence has completed
(~150µs after reset, `rtl/psram_controller.v`'s `STATE_INIT`+
`STATE_CR_INIT`), `spi_engine` stalls waiting for the very first PSRAM
access to complete while the host — not slowed by any handshake —
keeps clocking bytes. Bytes received during that stall are **silently
dropped**, with no error and no hang, just wrong data in PSRAM. Found
during the flash-subsystem work (`WORKLOG.md`, phase F5) via a minimal
`WRITE_RAM`-only reproduction with no flash opcodes involved at all —
this is a general hazard for any host, not specific to the flash
opcodes below. **Mitigation for now: a host must wait for PSRAM
power-up (or otherwise ensure the FPGA is fully out of reset for
>150µs) before its first `WRITE_RAM`/`READ_RAM`.** Not fixed at the
protocol level (would need real backpressure, a larger change) —
declared here as an open risk, not silently worked around.

**Why STATUS.done is sticky / clear-on-read:** in `rtl/neuron_memory.v`
`done` is a single-cycle pulse (asserted for exactly one clock in
`STATE_WAIT_N`, deasserted the next cycle). A host polling over SPI
— orders of magnitude slower than the FPGA clock — would almost
certainly miss a raw one-cycle pulse. The SPI register bank must
therefore latch `done` into a sticky bit on the pulse, and clear it
when the host issues `STATUS` (or `RESET`), not sample the raw
`neuron_memory.done` signal directly. `busy` has no such problem
(it is level-held for the whole computation) and can be read live.

**READ_CONFIG payload** (fixed 11 bytes — widened from the original 8-byte
draft in Phase G5 to add graph-engine capability info, §16 below —
lets one host firmware build work across different bitstreams
without recompiling):

| Byte(s) | Field | Source |
|---|---|---|
| 0 | `ADDR_WIDTH` (bits) | `neuron_memory.ADDR_WIDTH` |
| 1–2 | `N_INPUTS` (16-bit BE) | `neuron_memory.N_INPUTS` |
| 3 | `N_NEURONS` | `neuron_memory.N_NEURONS` |
| 4 | `PARALLEL` | `neuron_memory.PARALLEL` |
| 5 | `DATA_WIDTH` (bits) | `neuron_memory.DATA_WIDTH` |
| 6–7 | protocol version (16-bit BE) | `0x0001` for this spec |
| 8–9 | `N_TOTAL` (16-bit BE) — graph engine's activation-buffer depth (Phase G5) | `spi_engine.N_TOTAL` |
| 10 | capability flags — bit0=1 (graph/Type#2 supported) | `spi_engine.v`'s `GRAPH_SUPPORTED` |

**Runtime network width — one bitstream, any topology up to its
build-time max (2026-09-02):** `READ_CONFIG`'s `N_INPUTS`/`N_NEURONS`
report this bitstream's build-time **maximum** width (`neuron_memory`'s
own synthesis parameters) — the ceiling, not necessarily what the
currently-loaded network actually uses. The *real* per-run width is a
separate, host-set value:

- **Single-layer/manual path:** `SET_BASE` sel=7 (`n_inputs_real`) /
  sel=8 (`n_neurons_real`), 16-bit BE, defaulting to the build-time
  max on reset.
- **RUN_NETWORK (multi-layer) path:** each layer's own
  `n_inputs_real`/`n_neurons_real` in its descriptor table entry (see
  the RUN_NETWORK row above and the table format below) — independent
  per layer, so a network can taper (e.g. 256 -> 64 -> 16 -> 4) inside
  one chained run.

`n_inputs_real` **must be a multiple of `PARALLEL`** (the same
constraint `N_INPUTS` itself is held to at elaboration time — see
`rtl/neuron_parallel.v`'s parameter guard — now the host's runtime
responsibility instead of a build-time check). Both fields directly
bound the hardware's own loops (`neuron_memory`'s X/W RAM reads,
`neuron_parallel`'s MAC group count, and — for RUN_NETWORK — the
ping-pong copy-out length): a layer that only uses part of the
bitstream's max width genuinely computes and copies out faster, not
just "as if" narrower. No zero-padding of RAM is needed for the
unused tail (contrast with the old padding-only convention this
replaced) — data beyond `n_inputs_real`/`n_neurons_real` is simply
never read.

**Example session** (fills in the conceptual sequence above with
concrete opcodes):

```text
RESET                 -> 0x0F
READ_CONFIG           -> 0x30           (host learns N_INPUTS/N_NEURONS/...)
WRITE_RAM (weights)   -> 0x01 ...
WRITE_RAM (biases)    -> 0x01 ...
SET_BASE (X/W/BIAS)   -> 0x10 x3
WRITE_RAM (input X)   -> 0x01 ...
START                 -> 0x20
poll STATUS           -> 0x21           (until done bit set; clears on this read)
READ_OUTPUT           -> 0x22
```

**RUN_NETWORK (Phase 5) example session:**

```text
WRITE_RAM (layer descriptor table) -> 0x01 ...   (N_LAYERS entries of w_base(3B)+bias_addr(3B)+activation(1B)+n_inputs_real(2B)+n_neurons_real(2B), MSB-first)
WRITE_RAM (weights/biases per layer, X for layer 0) -> 0x01 ...
SET_BASE (X/TABLE/BUF_A/BUF_B)     -> 0x10 x4
RUN_NETWORK(num_layers)            -> 0x23 <num_layers>
poll STATUS                        -> 0x21   (until done bit set; clears on this read)
READ_OUTPUT                        -> 0x22   (final layer's y_bus)
```

Not yet decided / explicitly out of scope for v1: Dual SPI framing,
a CRC/checksum on transfers (SPI is assumed reliable for a
board-level trace in v1). Multi-layer sequencing itself (RUN_NETWORK,
opcode 0x23) is implemented per `rtl/layer_sequencer.v` and the table
above.

---

## 8.3 Flash Subsystem (opcodes 0x40-0x47, completed 2026-09-04)

The FPGA has **exclusive** access to the onboard boot/persistence flash
(Winbond W25Q128JV, 16MB SPI NOR — confirmed part,
`docs/FPGA-Neural-Hardware-Design.md` §6/§7) through a dedicated,
physically separate SPI master (`rtl/spi_flash_master.v`), never
through direct host access to the flash pins. This is **not** a
filesystem: a small, fixed-size catalog (16 slots, `rtl/flash_slot_manager.v`)
maps `slot_id → (offset, length, type, valid, CRC32)` in a reserved
flash sector (sector 0) — no dynamic allocation, no garbage collection.

**Layering** (each level reusable/testable on its own):
- `rtl/spi_flash_master.v` — raw SPI master toward the flash chip
  (RDID/READ/WREN/PP/SE/RDSR-1). All 4 pins (`sclk`/`mosi`/`miso`/`cs_n`)
  are ordinary GPIO (`flash_sclk`/`flash_mosi`/`flash_miso`/`flash_cs_n`
  at the top level) — a **fully independent** SPI bus, no pin shared
  with the dedicated boot config-SPI path, no ECP5 config-primitive
  involved. **Revised 2026-09-04**: an earlier version reused the
  boot `CCLK` pad via the `USRMCLK` primitive to save one pin — dropped
  because it made the "exclusive flash bus" claim electrically
  misleading (SCLK depended on the same pad as the config engine) and
  carried an unresolved verification gap (`USRMCLKTS` pad-enable timing
  was never checked against the primary Lattice sysCONFIG Usage Guide,
  FPGA-TN-02039, not present in this project's local document set).
  See `WORKLOG.md`'s Phase F7 entry.
- `rtl/flash_copy_engine.v` — block-streaming engine on top: flash→PSRAM
  (`DIR_LOAD`), PSRAM→flash with internal erase-before-write + ≤256B
  Page Program loop + WIP polling (`DIR_SAVE`), standalone sector erase
  (`DIR_ERASE`). A low-priority master (Port D) on `rtl/mem_arbiter.v` —
  flash operations are ms-scale and never block inference.
- `rtl/flash_slot_manager.v` — the slot catalog on top of that, plus a
  CRC32 (`rtl/crc32.v`, IEEE 802.3/zlib) computed live over the actual
  byte stream during `LOAD_SLOT`/`SAVE_SLOT`, so a corrupted or
  partially-written slot (e.g. power lost mid-erase) is detected even
  when the underlying flash operation itself reported success.

**Opcodes**: see the table above (0x40-0x47) — all fire-and-forget
(poll `STATUS`/`data_ready_n` for completion, exactly like `RUN_NETWORK`),
except `CAT_INSPECT` (0x47, synchronous response, added beyond the
original catalog-opcode draft to actually deliver `CAT_READ`'s
"-> host" — see that opcode's own table row).

**Design decision worth citing here**: `SAVE_SLOT` (and the raw
`FLASH_WRITE_BLOCK`/`FLASH_ERASE`) require their target flash address to
be 4KB-sector-aligned — rejected as an error otherwise, rather than a
silent read-modify-erase-write of a partial sector (no scratch buffer
large enough exists for that, and every real `SAVE_SLOT` already writes
a whole, sector-aligned slot by construction). Full rationale, every
datasheet citation, every adversarial test (CRC mismatch, never-saved
slot, page-boundary crossing, simulated power-loss, arbiter contention),
and the two real bugs found and fixed during bring-up (one pre-existing
in `psram_controller.v`, one in the new arbiter-request handshake) are
in `WORKLOG.md`'s F1-F6 entries and
`docs/FPGA-Neural-Flash-Subsystem-Verification.md` (per-module coverage
summary, not repeated here).

**Measured real latency** (methodology in the verification doc): ERASE
(4KB sector) ≈400ms, SAVE (256B page, incl. its own erase) ≈403ms —
both dominated by the flash chip's own internal timing (tSE/tPP MAX,
independent of host clock frequency); LOAD (4096B) is purely SPI-clock-
bound: 1.74ms (2.35MB/s) @80MHz, 8.71ms (0.47MB/s) @16MHz.

---

# 9. Dedicated FPGA RAM

The RAM is considered part of the Neural Network Engine.

It is not intended to be supplied by the host system.

Depending on the final architecture, RAM may contain:

```text
Weights
Biases
Input buffers
Intermediate layer buffers
Output buffers
Network parameters
```

The memory architecture must be designed according to:

- number of parallel MAC units;
- data width;
- required bandwidth;
- number of layers;
- buffering requirements;
- FPGA block-RAM resources;
- possible external RAM requirements.

The preferred architecture is that the FPGA directly controls this memory.

---

# 10. Training

Training and inference are conceptually separated.

The first implementation does not require the FPGA to perform the complete training process.

Training can be performed externally:

```text
PC / Linux / other host
        │
        │ training
        ▼
Network weights
        │
        │ SPI
        ▼
FPGA RAM
```

The FPGA then performs inference using the resulting parameters.

This approach greatly reduces the complexity of the initial hardware implementation.

However, the architecture should not prevent future implementation of hardware-assisted or fully hardware-based training.

---

# 11. Inference

During inference, the host only supplies input data and retrieves the result.

```text
              HOST
                │
             Input
                │
                │ SPI
                ▼
        ┌───────────────┐
        │      FPGA     │
        │               │
        │ Neural Network│
        │    Engine     │
        │               │
        └───────┬───────┘
                │
             Output
                │
                │ SPI
                ▼
              HOST
```

The host is not involved in the individual MAC operations.

This provides:

- deterministic computation;
- reduced host workload;
- hardware parallelism;
- predictable latency;
- independence from the host CPU architecture.

---

# 12. Multi-Layer Architecture

The current implementation starts from a single parametrized layer.

The intended architecture is eventually:

```text
Input
  │
  ▼
┌──────────────┐
│   Layer 0    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Layer 1    │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Layer 2    │
└──────┬───────┘
       │
       ▼
    Output
```

Intermediate data will be stored in FPGA-controlled memory buffers.

The number and size of layers should ultimately be part of the hardware generation process.

---

# 13. Reusability

The main purpose of the architecture is reuse.

A future project should be able to use the same general Neural Network Engine architecture with a different hardware configuration.

For example:

```text
Project A
    N_INPUTS  = 32
    N_NEURONS = 8
    PARALLEL  = 8

Project B
    N_INPUTS  = 64
    N_NEURONS = 16
    PARALLEL  = 16

Project C
    N_INPUTS  = 128
    N_NEURONS = 32
    PARALLEL  = 32
```

The HDL architecture remains conceptually the same while synthesis parameters generate an implementation appropriate for the target application.

---

# 14. Design Philosophy

The project should be considered a:

> **Reusable FPGA Neural Network Accelerator Platform**

rather than a single neural-network implementation.

The application determines:

```text
Input size
Network topology
Number of layers
Number of neurons
Parallelism
Numerical precision
Activation functions
Memory requirements
Performance requirements
```

The hardware generator then produces the corresponding FPGA implementation.

---

# 15. Development Roadmap

## Phase 1 — Parametric Layer

- [x] Parametric inputs
- [x] Parametric neurons
- [x] Parametric parallelism
- [x] Accumulation
- [x] Bias
- [x] ReLU
- [x] 32×4 / P=8 functional test

## Phase 2 — Parameter Sweep

Validate multiple combinations of:

```text
N_INPUTS
N_NEURONS
PARALLEL
```

including configurations where the number of inputs is not an exact multiple of the parallelism.

- [x] Exact-multiple sanity configs (32×8, 64×32)
- [x] Non-exact-multiple configs (30×8, 20×16)
- [x] Degenerate config, PARALLEL > N_INPUTS (4×8)
- [x] Sweep testbench: `sim/parameter_sweep_tb.v`

**Findings — FIXED (2026-09-02):**

- `neuron_parallel.v` computed `GROUPS = N_INPUTS / PARALLEL` with
  integer division. When `N_INPUTS` was **not** an exact multiple of
  `PARALLEL`, only the first `GROUPS * PARALLEL` inputs were ever
  read by the accumulator — the remainder was silently dropped (no
  error, no warning). Confirmed for 30×8 → only 24 of 30 inputs
  summed, and 20×16 → only 16 of 20 inputs summed.
- If `PARALLEL > N_INPUTS`, `GROUPS = 0` and the controller's
  `group_index == GROUPS-1` terminal condition was never satisfied:
  the neuron entered `busy` and never asserted `done` (confirmed
  hang, 500-cycle watchdog in the sweep bench).
- Both share the same root cause (`N_INPUTS % PARALLEL != 0`,
  degenerate `PARALLEL > N_INPUTS` included) and both are now
  rejected at **elaboration time**, in simulation and synthesis
  alike, by a `generate` guard added to `neuron_parallel.v`
  (instantiates a deliberately undefined module when the parameter
  combination is invalid — zero cost, zero behavior change for any
  valid configuration). The validated datapath itself
  (mac8/mac_unit/accumulation/ReLU/saturation) was **not** modified.
  See `sim/neuron_parallel_guard_negative_nonmultiple_tb.v` and
  `sim/neuron_parallel_guard_negative_degenerate_tb.v` for the
  negative-test proof, and `sim/parameter_sweep_tb.v` for the
  updated positive sweep (now valid-configs-only, including
  `PARALLEL=2` and `PARALLEL=4`, the two best-performing values from
  `docs/FPGA-Neural-Datapatch-Benchmark.md`).

## Phase 3 — Memory Architecture

Define:

- weight memory;
- bias memory;
- input buffers;
- output buffers;
- intermediate buffers;
- memory addressing;
- bandwidth requirements.

- [x] `neuron_memory.v`: single-neuron memory integration (N_NEURONS=1)
- [x] `neuron_memory.v`: multi-neuron memory integration (N_NEURONS>1)
- [ ] Intermediate/multi-layer buffers (deferred to Phase 5)
- [ ] Bandwidth analysis against PSRAM timing (deferred to Phase 7)

**Multi-neuron design (2026-09-02):** `neuron_memory.v` now takes an
`N_NEURONS` parameter and loops over neurons in memory: `X` is read
once (shared input vector), and for each neuron in turn `W` and
`bias` are re-read from PSRAM and fed to a single, reused
`neuron_parallel` instance — memory-bound by design, one neuron
computed at a time, no change to the validated compute datapath.
Addressing follows the same neuron-major convention as `layer.v`:
neuron `n`'s weights live at `w_base + n*N_INPUTS` bytes, its bias at
`bias_addr + n`. Output is now `y_bus` (packed, `DATA_WIDTH*N_NEURONS`
bits, neuron-major), replacing the old single-neuron `y` port.
Validated end to end through the full memory stack
(`memory_interface` + `psram_controller` + `psram_model`) in
`sim/neuron_memory_multi_tb.v` (N_NEURONS=3: scale, larger value,
ReLU). `sim/neuron_memory_tb.v` (N_NEURONS=1) still passes unchanged,
confirming backward compatibility.

## Phase 4 — SPI Interface

Implement:

- SPI controller;
- register map;
- RAM access;
- configuration protocol;
- input/output protocol;
- status and control.

- [x] Protocol/opcode set drafted — see §8.1 SPI Protocol v1
- [x] SPI controller RTL — `rtl/spi_slave.v` (physical layer: Mode 0, MSB-first, 3-stage CDC synchronizer for SCLK/MOSI/CS_N)
- [x] Register bank RTL — `rtl/spi_engine.v` (all 8 opcodes: NOP, WRITE_RAM, READ_RAM, RESET, SET_BASE, START, STATUS, READ_OUTPUT, READ_CONFIG; sticky clear-on-read STATUS.done)
- [x] RAM access passthrough RTL — `rtl/mem_arbiter.v` (fixed-priority arbiter, neuron_memory > spi_engine) + shared `int8_memory_access` instance in `rtl/spi_neuron_top.v`
- [x] Testbenches: `sim/spi_slave_tb.v` (4 tests), `sim/spi_engine_tb.v` (10 tests, synthetic RAM), `sim/spi_neuron_top_tb.v` (end-to-end, **real** `psram_model.v`, no synthetic mock — RESET/READ_CONFIG/WRITE_RAM/READ_RAM/SET_BASE/START/STATUS/READ_OUTPUT all exercised purely over simulated SPI)

**Real-toolchain verification (Yosys + nextpnr-ecp5 + ecppack, 2026-09-02):**

- `spi_slave.v` alone: PASS, Fmax 403.23 MHz.
- `spi_engine.v` alone: PASS, Fmax 191.31 MHz. Neither uses any DSP.
- `spi_neuron_top.v` (full integration: SPI + arbiter + neuron_memory
  + PSRAM chain), N_NEURONS=1: **FAIL at 80 MHz** — Fmax ~52.58 MHz
  (PARALLEL=8) / ~55.85 MHz (PARALLEL=2, the benchmark's own
  80 MHz-passing config in isolation). The critical path in both
  cases is entirely inside `neuron_parallel.v`'s saturation
  comparator (`> 127`, `rtl/neuron_parallel.v:127`) — zero
  contribution from the new SPI/arbiter logic — but its routed delay
  is ~57% worse than in the isolated benchmark (17.91 ns vs.
  11.38 ns) due to placement/routing congestion once the SPI +
  PSRAM logic shares the fabric with it, not resource exhaustion
  (DSP utilization only 2%). This means the current auto-placed
  full system would need to run around 50-56 MHz to stay within
  timing margin at speed grade -8, not the 80 MHz target — a
  system-level floorplanning/pipelining problem, out of scope here
  and left for Phase 7 (Optimization: "pipeline depth", "FPGA
  resource utilization"). It does not affect functional correctness
  (verified independently, in simulation, against real PSRAM
  timing) or synthesizability (0 CHECK-pass problems, no latches).

## Phase 5 — Multi-Layer Network

Implement:

- multiple layers;
- intermediate buffers;
- layer sequencing;
- configurable activation functions.

- [x] `layer_sequencer.v`: chains up to `N_LAYERS` runs of a single, reused `neuron_memory` instance, reading each layer's `w_base`/`bias_addr`/`activation`/`n_inputs_real`/`n_neurons_real` from a host-written descriptor table (11 bytes/layer) and ping-ponging each layer's output between two RAM buffers (layer 0 reads the external `x_base`; layer k>0 reads the buffer layer k-1 wrote)
- [x] Configurable activation functions — `neuron_parallel.v` gains a 2-bit `activation` port (`ACT_NONE`=linear+two-sided saturate, `ACT_RELU`=the original hardwired behavior, kept as the default so every pre-existing caller/testbench is unaffected), threaded through `neuron_memory.v` at runtime and settable per-layer via the descriptor table (Phase 5 path) or per-run via `SET_BASE` sel=6 (legacy single-layer path). Unit-tested directly in `neuron_parallel_tb.v` (linear pass-through + negative saturation to -128) and end-to-end in `spi_neuron_top_runnetwork_tb.v` (a real negative accumulator that ACT_RELU would have clamped to 0 comes through unclamped under ACT_NONE, verified over real SPI/RAM)
- [x] Runtime network width — one synthesized bitstream serves any topology up to its build-time max: `neuron_parallel.v` gains a runtime `n_inputs_real` (bounding its MAC group loop) and `neuron_memory.v` gains `n_inputs_real`/`n_neurons_real` (bounding its X/W RAM-read loop and its neuron loop), all defaulting to the build-time max so every pre-existing caller is unaffected. Settable per-layer via the descriptor table (Phase 5 path) or per-run via `SET_BASE` sel=7/8 (legacy single-layer path). This is a **real** early termination, not just address bookkeeping — no RAM zero-padding needed for the unused tail, and it measurably runs faster: `neuron_parallel_tb.v` TEST 7 shows 3 cycles vs. 6 for a reduced-vs-full run (with garbage loaded in the skipped lanes, proving they're never read), and `neuron_memory_tb.v` TEST 5 shows the same effect through the real PSRAM stack: **209 cycles vs. 788** for an 8-of-32 vs. full-32 run. `layer_sequencer_tb.v` additionally proves a reduced `n_neurons_real` shortens the ping-pong copy-out itself (untouched RAM bytes beyond the real count, not just a differing value)
- [x] `mem_arbiter.v`: extended to a third port (Port C, priority B > C > A) for the sequencer's own RAM master access
- [x] `spi_engine.v`: `RUN_NETWORK` opcode (0x23) + `SET_BASE` selectors for `table_base`/`buf_a_base`/`buf_b_base`; `STATUS.busy`/`STATUS.done` extended to track the sequencer (`seq_busy`/`seq_done`) as well as `neuron_memory` directly, so `done` latches on the *last* layer only, not each intermediate one — see §8.1
- [x] `spi_neuron_top.v`: instantiates the sequencer and muxes `neuron_memory`'s control inputs between it (while `seq_busy`) and `spi_engine`'s direct-drive path (legacy single-layer mode)
- [x] Testbenches: `sim/layer_sequencer_tb.v` (2-layer run: descriptor table, ping-pong addressing verified by address not just value, byte-exact output-buffer copy, `seq_busy` held across the layer boundary, `seq_done` fires exactly once, plus a reduced `n_neurons_real` proven to shorten the copy-out itself); `sim/spi_engine_tb.v` gained tests K/L/M/N (new `SET_BASE` selectors incl. activation and runtime width, `RUN_NETWORK` accept/busy-ignore gating, `STATUS` semantics) — both use a mocked `neuron_memory`, same pattern as Phase 4's `spi_engine_tb.v`; `sim/neuron_parallel_tb.v` and `sim/neuron_memory_tb.v` each gained a dedicated runtime-width test against the real datapath/real PSRAM stack (see the runtime-width bullet above for the cycle counts)
- [x] Real-toolchain (Yosys + nextpnr-ecp5) synthesis/Fmax check of the extended `spi_neuron_top.v` — **worse than Phase 4 alone** in both configs checked, speed grade -8: N_INPUTS=32/N_NEURONS=1/PARALLEL=8 gives **40.57 MHz, FAIL** (Phase 4 alone: ~52.58 MHz); PARALLEL=2 gives **42.54 MHz, FAIL** (Phase 4 alone: ~55.85 MHz). The Phase 5 wiring (sequencer + mux + arbiter Port C) measurably cost 12-13 MHz of headroom on top of Phase 4's own placement-congestion problem, and the critical path itself shifted from Phase 4's saturation-comparator finding to `neuron_memory`'s `x_mem`/`w_mem` LUT-RAM read-mux tree — see the Phase 7 critical-path analysis below.
- [x] `sim/spi_neuron_top_runnetwork_tb.v`: real end-to-end test, `RUN_NETWORK` driven purely over simulated SPI against the real `neuron_memory` + PSRAM chain (N_INPUTS=N_NEURONS=4, PARALLEL=2, 2 layers, hand-computed expected output verified via both `READ_OUTPUT` and a `READ_RAM` of `buf_b_base`, plus `buf_a_base`'s intermediate layer-0 output) — all PASS, and confirms the mux correctly hands `neuron_memory` back to the legacy single-layer `START` path afterward

**Bug found and fixed while writing the above test (2026-09-02):** a real race
in the STATUS.done sticky/clear-on-read mechanism (§8.1), present since Phase 4
and not specific to RUN_NETWORK — it only needed continuous STATUS polling
racing a `done` transition to surface, which the new end-to-end test's
`wait_done` polling loop finally did. `tx_byte`'s `OP_STATUS` case read
`status_done_sticky`/`busy` **live/combinationally** for the whole `ST_RESP`
window, while the sticky bit was cleared unconditionally on any STATUS read
(`status_read_now`). If `done_event` landed while a STATUS response byte was
already mid-transmission, the byte actually shifted out to the host could
still be the stale pre-done value while the engine simultaneously treated the
read as having delivered `done` and cleared it — silently dropping the
transition forever, hanging any host polling STATUS in a tight loop. Fixed in
`rtl/spi_engine.v` by latching a `status_snapshot` register once, at
`OP_STATUS` opcode-accept time, and gating the sticky clear on
`status_snapshot[1]` (i.e. only clear if the byte actually transmitted showed
`done=1`) instead of clearing unconditionally on every STATUS read. A
`done_event` that arrives too late for one snapshot is now reported on the
next poll instead of being lost. All existing testbenches (`spi_slave_tb.v`,
`spi_engine_tb.v`, `spi_neuron_top_tb.v`, `layer_sequencer_tb.v`) still pass
unchanged.

## Phase 6 — Host Software

Develop host-side drivers for:

- Linux;
- ESP32.

The same FPGA protocol should be usable by both.

## Phase 7 — Optimization

Evaluate:

- pipeline depth;
- MAC parallelism;
- memory bandwidth;
- numerical precision;
- FPGA resource utilization;
- latency;
- throughput.

**Critical-path analysis (real Yosys + nextpnr-ecp5, 2026-09-02):**
both `spi_neuron_top.v` builds checked so far miss the 80 MHz target, and
the shortfall grew with Phase 5 wired in:

| Build | N_INPUTS/N_NEURONS/PARALLEL | Fmax | vs. 80 MHz |
|---|---|---|---|
| Phase 4 only (documented above) | 32/1/8 | ~52.58 MHz | -34% |
| Phase 4 only (documented above) | 32/1/2 | ~55.85 MHz | -30% |
| Phase 5 (this session) | 32/1/8 | 40.57 MHz | -49% |
| Phase 5 (this session) | 32/1/2 | 42.54 MHz | -47% |

Resource utilization is not the cause in either case: `MULT18X18D`
(DSP) and `DP16KD` (block RAM) both sit at **0%** in the Phase 5
builds — `neuron_memory.v`'s `x_mem`/`w_mem` arrays (32 x INT8 each)
are being inferred as **LUT-based distributed RAM**, not the ECP5's
dedicated `DP16KD` block RAM, which sits completely idle.

The critical path itself **shifted** between the two checks. Phase
4's finding (quoted above) pinned it on `neuron_parallel.v`'s
saturation comparator (`> 127`), with routing congestion as the
driver, not logic depth. In this session's Phase-5 builds the
reported critical path (posedge -> posedge, `neuron_memory`'s
accumulator register) instead runs through a long chain of nested
`PFUMX`/`L6MUX21` LUT multiplexers reading `w_mem`/`x_mem` before
reaching `acc` — consistent with a 32-entry LUT-RAM read select tree,
not the saturation logic. Whether this is a genuinely different
bottleneck or an artifact of where Phase 5's extra logic pushed the
placer is not yet determined; it would need a placement-seed sweep
(same design, several `nextpnr --seed` values) to separate "real
critical path" from "this particular placement's critical path" —
neither Phase 4's nor Phase 5's single P2/P8 runs establish that.

**Candidate directions (not implemented, need a decision before
touching the validated core further):**

**Placement-seed sweep (2026-09-02) — resolved: it's structural, not
noise.** Re-ran `nextpnr-ecp5` on the already-synthesized Phase 5
netlists (`top.json` reused, only placement re-seeded — no re-synth)
at `--seed 1/2/3` for both P8 and P2:

| Build | seed (default) | seed 1 | seed 2 | seed 3 | spread |
|---|---|---|---|---|---|
| P8 | 40.57 MHz | 39.70 MHz | 39.54 MHz | 40.00 MHz | 1.03 MHz (2.6%) |
| P2 | 42.54 MHz | 42.82 MHz | 42.72 MHz | 45.01 MHz | 2.47 MHz (5.8%) |

Both builds land in a tight band regardless of seed — nothing close
to the P2/P4/P8 same-tier benchmark's own non-monotonic swings (that
benchmark's design uses <2% of the device, so its placer has enormous
freedom; `spi_neuron_top`'s fuller design does not). **This confirms
a real structural bottleneck, not a lucky/unlucky placement** — a
seed sweep or floorplan constraint will not close a ~2x gap to
80 MHz by itself; an RTL change is needed.

**Candidate directions (not implemented, need a decision before
touching the validated core further):**

- Move `x_mem`/`w_mem` onto `DP16KD` block RAM (0% used) instead of
  LUT fabric — the leading candidate. The critical path runs through
  what looks like `w_mem`'s *write*-address decode (`neuron_memory`
  loads one byte per cycle into a variable index during
  `STATE_READ_X`/`STATE_READ_W`, which needs a full-width mux/demux
  in LUT fabric to steer that byte to the right register) feeding
  forward into the accumulator's input path — not the arithmetic
  itself. A block-RAM read/write port replaces that scattered
  LUT-based decode with a single hard macro. This is a genuine
  redesign, not a drop-in swap: `x_bus`/`w_bus` are currently
  exposed to `neuron_parallel` as one fully-parallel N_INPUTS-wide
  combinational bus (built by unrolling every `x_mem`/`w_mem`
  element every cycle); block RAM has a registered, address-in/
  data-out-next-cycle read port, so `neuron_parallel`'s group
  processing would need to become RAM-latency-aware instead of
  assuming the whole bus is already valid. Real potential upside,
  real design effort — needs a go-ahead, not something to do
  opportunistically.
- A pipeline register between MAC accumulation and the
  activation/saturate stage (this session's original guess) does
  **not** target the actual Phase 5 bottleneck — that finding was
  Phase 4's critical path (the saturation comparator), and the path
  moved once Phase 5's logic was wired in (see above). Keeping this
  noted for Phase 4-only builds; not a fix for the current problem.

## Phase 8 — Optional Hardware Training

Investigate:

- backpropagation;
- gradient calculation;
- weight updates;
- hardware-assisted training.

---

# 16. Long-Term Vision

The final objective is to create a reusable hardware block that can be integrated into different future MIKILAB projects.

```text
                         APPLICATION
                              │
                ┌─────────────┴─────────────┐
                │                           │
             Linux                       ESP32
                │                           │
                └─────────────┬─────────────┘
                              │
                         SPI / Dual SPI
                              │
                              ▼
                 ┌────────────────────────┐
                 │          FPGA          │
                 │                        │
                 │ Neural Network Engine  │
                 │                        │
                 │ ┌────────────────────┐ │
                 │ │ Control            │ │
                 │ ├────────────────────┤ │
                 │ │ Input Interface    │ │
                 │ ├────────────────────┤ │
                 │ │ NN Compute Core    │ │
                 │ ├────────────────────┤ │
                 │ │ Activation         │ │
                 │ ├────────────────────┤ │
                 │ │ Output Interface   │ │
                 │ └────────────────────┘ │
                 │                        │
                 │ Dedicated RAM          │
                 │                        │
                 └────────────────────────┘
```

The host platform can change without changing the fundamental Neural Network Engine architecture.

The FPGA becomes a dedicated neural-computation peripheral, analogous to other hardware accelerators, but optimized specifically for the neural-network topology required by each application.

---

# 17. Current Status

| Component | Status |
|---|---|
| Parametric neuron layer | OK Working |
| Parametric input count |  OK |
| Parametric neuron count | OK |
| Parametric parallelism | OK |
| Accumulation | OK |
| Bias | OK |
| ReLU | OK |
| 32×4 / P=8 validation | OK |
| Dedicated RAM architecture | OK (memory_interface + psram_controller + int8_memory_access, real-PSRAM tested) |
| PSRAM page-mode burst reads | OK (2026-09-03, `psram_page_mode_tb.v`; sequential gather bandwidth +42% measured, see `FPGA-Neural-Datapatch-Benchmark.md` Appendice D) |
| SPI interface | OK (spi_slave + spi_engine, 17 opcodes incl. RUN_NETWORK + flash subsystem, real-toolchain Fmax checked at system level) |
| Dual SPI | Future |
| Multi-layer engine (Type#1, dense) | OK — RTL + unit tests + real end-to-end (simulated SPI) done; real toolchain checked (P8: FAIL 40.57 MHz, worse than Phase 4 alone) |
| Graph engine (Type#2, sparse arbitrary graph) | OK (Phase G5 — `graph_engine.v`, load-time guard §7, real end-to-end SPI test, real toolchain Fmax checked at system level) |
| Flash subsystem (boot/persistence, exclusive FPGA access) | OK (Phases F1-F6, 2026-09-04 — SPI master, bidirectional copy engine, slot catalog + CRC32, 8 opcodes, full real-toolchain synthesis; see §8.3 and `WORKLOG.md`) |
| Configurable activation functions | OK (ACT_NONE / ACT_RELU, per-layer via descriptor table or per-run via SET_BASE) |
| Runtime network width (one bitstream, any topology up to build max) | OK (per-layer or per-run `n_inputs_real`/`n_neurons_real`, real cycle savings measured end to end) |
| Linux host driver | Planned |
| ESP32 host driver | Planned |
| Hardware training | Future |

---

## Core architectural principle

**The FPGA implements the neural-network machine.  
The FPGA owns its RAM.  
The host configures and uses the machine.  
A build sets the machine's *ceiling* (max layers, max width, PARALLEL); the host configures the *actual* network — layer count, per-layer input/output width, per-layer activation, and trained parameters — entirely at runtime, over SPI, into FPGA-local memory. One bitstream serves any topology up to that ceiling (2026-09-02, see §17 "Runtime network width").**

This separation is the foundation of the project.