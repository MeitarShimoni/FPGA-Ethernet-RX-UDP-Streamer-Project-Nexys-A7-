# FPGA Ethernet RX — UDP Streamer Project (Nexys A7)

A from-scratch Ethernet receive path in SystemVerilog for the Nexys A7 board
(onboard 10/100 PHY, RMII interface). Long-term goal: a full UDP/IP stack —
the FPGA answers ping and streams live data to a PC.

**Current status:** RMII byte alignment + MAC frame parsing with CRC32
checking, verified in simulation.

---

## 1. Ethernet in one minute

Data on Ethernet travels in **frames**. The PHY chip handles the analog side
of the cable and hands the FPGA a raw bit stream (as 2-bit "dibits" at
50 MHz — that's RMII). Everything above that — finding where a frame starts,
grouping bits into bytes, checking it wasn't corrupted, understanding
addresses — is our job in RTL.

## 2. Anatomy of an Ethernet frame

What actually arrives on the wire, in order:

| Field           | Size     | What it is                                                                 | Who handles it        |
|-----------------|----------|----------------------------------------------------------------------------|-----------------------|
| Preamble        | 7 bytes  | `0x55` repeated — a "warm-up" pattern (10101010...) so the receiver can lock on | `eth_frame_rx` (discarded) |
| SFD             | 1 byte   | `0xD5` — Start Frame Delimiter, marks "real data starts on the next byte"  | `eth_frame_rx` (discarded) |
| Destination MAC | 6 bytes  | Who the frame is for. `FF:FF:FF:FF:FF:FF` = broadcast (everyone)           | Passed to upper layers |
| Source MAC      | 6 bytes  | Who sent it                                                                 | Passed to upper layers |
| EtherType       | 2 bytes  | What's inside: `0x0806` = ARP, `0x0800` = IPv4                              | Passed to upper layers |
| Payload         | 46–1500 bytes | The actual data (ARP message, IP packet...). Short data is zero-padded to 46 | Passed to upper layers |
| FCS             | 4 bytes  | CRC32 checksum over everything from Destination MAC to end of payload       | `eth_frame_rx` (checked, then stripped) |

Two details that matter in RTL:

- **Bit order:** Ethernet sends each byte LSB-first. That's why the preamble
  byte `0x55` appears on the RMII pins as the dibit `01` over and over — and
  why we can align byte boundaries just by finding the first `01`.
- **FCS position:** the checksum comes *last*, and frame length is unknown in
  advance. So we can only know where the FCS starts once the frame *ends* —
  hence the 4-byte delay line trick (see below).

## 3. What each file does

### `rmii_rx.sv` — dibits → bytes
Takes the raw RMII pins (`rxd[1:0]`, `crs_dv`) and outputs an aligned byte
stream. It waits for the carrier and the first `01` dibit (start of preamble)
to lock the byte boundary, then emits one byte every 4 clocks. Also filters
the CRS_DV toggling quirk that RMII has near the end of a frame.

Outputs: `rx_data` + `rx_valid` (one pulse per byte), `rx_frame_end`
(pulse when the carrier drops).

### `eth_frame_rx.sv` — bytes → verified frames
A small FSM:

1. **IDLE → PRE:** hunts for preamble bytes (`0x55`)
2. **PRE → DATA:** waits for the SFD (`0xD5`); anything else = resync
3. **DATA:** streams out frame bytes while computing CRC32 on the fly

Two tricks inside:

- **4-byte delay line:** every byte is held back by 4 positions before being
  output. When the frame ends, the 4 bytes still "stuck" in the delay line
  are exactly the FCS — so the output stream never contains it.
- **CRC residue check:** instead of extracting the FCS and comparing, we run
  CRC32 over the *entire* frame including the FCS. Math guarantees that for
  an intact frame the CRC register always lands on the constant
  `0xDEBB20E3`. One comparison, no FCS extraction needed.

Outputs: `m_data` + `m_valid` (frame bytes, FCS stripped), and at end of
frame a `frame_done` pulse with `frame_ok` (CRC verdict). **`frame_ok` is
only meaningful in the cycle `frame_done` is high** — always check them
together (`frame_done && frame_ok`).

### `tb_eth_rx.sv` — self-checking testbench
Builds a 60-byte frame, computes a real FCS with the same CRC algorithm,
serializes everything down to RMII dibits, and drives the pins. Checks:

- **Frame 1 (clean):** output bytes must match, `frame_ok` must be 1
- **Frame 2 (corrupted on purpose):** one byte is flipped after the FCS was
  computed → `frame_ok` must be 0. This proves the checker rejects bad
  frames, not just that it accepts good ones.

Expected output:
```
[t] frame_done, frame_ok=1 as expected
[t] frame_done, frame_ok=0 as expected
TB finished: 2 frames checked.
```

## 4. Signal flow

```
PHY pins          rmii_rx              eth_frame_rx            (next stage)
rxd[1:0]  ──►  dibit → byte   ──►  preamble/SFD hunt    ──►  packet FIFO
crs_dv          alignment           CRC32 check               (commit/drop)
                                    FCS stripping
```

## 5. Roadmap — what comes next

In build order, each step giving something testable:

1. **Packet FIFO (commit/rewind)** — write frame bytes into a FIFO
   speculatively; at `frame_done`, commit the write pointer if `frame_ok`,
   rewind it if not. Downstream logic then only ever sees clean frames.
   Make it dual-clock and it also crosses from the 50 MHz RMII domain to
   the system clock — two problems, one module.
2. **MAC filter** — accept only frames whose destination MAC is ours or
   broadcast. Our MAC: made up, locally administered (e.g.
   `02:00:00:00:00:01`). Broadcast must pass, or ARP will never work.
3. **TX path** — the mirror image: build preamble + SFD + frame + computed
   FCS and serialize to dibits. Reuses the same CRC32 function
   (complemented, sent LSB-byte first).
4. **ARP responder** — parse ARP requests asking "who has IP x.x.x.x?" and
   answer with our MAC. **Milestone: the FPGA shows up in `arp -a` on the
   PC.** Nothing else can work before this — the PC won't talk to an IP it
   can't resolve.
5. **ICMP echo** — parse IPv4 headers, answer echo requests.
   **Milestone: `ping` to the FPGA works.**
6. **UDP TX** — build UDP/IP packets with a fixed header (IP header checksum
   is a simple 16-bit ones'-complement sum) and stream data — a counter,
   ADC samples, anything — to the PC. Receive with ~10 lines of Python
   (`socket.recvfrom`). **Milestone: live data plotted on the PC.**
7. **Stretch goals:** UDP RX (PC → FPGA commands), then PTP timestamping.

## 6. Practical bring-up tips

- **Direct cable, static IPs.** Connect FPGA straight to the PC's Ethernet
  port. Set the PC to a static IP (e.g. `192.168.1.1/24`), give the FPGA a
  hardcoded one (e.g. `192.168.1.2`). No router, no DHCP.
- **Wireshark first, hardware second.** Wireshark shows every frame with all
  fields decoded and flags bad checksums — it's a free protocol analyzer.
  You can also copy real frame bytes from a capture into the testbench.
- **Check the PHY clocking.** On the Nexys A7 the PHY needs its 50 MHz
  reference clock and proper reset timing per the board reference manual —
  a silently-unclocked PHY looks exactly like "my design is broken."

## 7. Running the simulation

Vivado: add all three `.sv` files, set `tb_eth_rx` as simulation top, run
behavioral simulation. All files must be compiled as SystemVerilog and keep
their `timescale` directive (xsim errors out if some modules have one and
others don't).
