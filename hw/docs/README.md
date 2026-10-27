# ML-KEM / UART1 CSR Reference and Usage Sequences

The EBAZ4205 platform uses ML-KEM KeyGen at 100 MHz and PS UART1 on MIO 24-25.
Load the [XSA with bitstream](../vitis/mlkem_keygen_uart.xsa) using Vitis/JTAG and
run the PS firmware before sending UART commands. MMIO addresses are **base +
offset**, with 32-bit accesses aligned to 4-byte boundaries. In Vitis standalone,
use `Xil_In32` / `Xil_Out32`.

## 1. ML-KEM CSRs

**Base: `0x40000000`.** The IP accepts two 32-byte seeds, `d,z`, and returns an
1184-byte `ek` and a 2400-byte `dk`. The PS supplies the seeds; the PL does not
generate random numbers.

| Offset | Register | Access | Description |
|---|---|---|---|
| `0x00` | CTRL | R/W | Bit 0 START; bit 1 SOFT_RST; bit 2 IRQ_ENABLE. START/RESET are pulses and read back as 0. |
| `0x04` | STATUS | R/W1C | Bit 0 BUSY; bit 1 DONE; bit 2 ERROR; bit 3 RESULTS_VALID. Only DONE/ERROR support write-one-to-clear. |
| `0x08` | CYCLE_COUNT | RO | Number of cycles since START was accepted; saturates at `0xFFFFFFFF`. |
| `0x0C` | WATCHDOG | R/W | Cycle limit; defaults to `0x00100000`. Write 0 to disable; writable only while idle. |
| `0x10..0x2C` | SEED_D[0..7] | R/W | Eight little-endian words of seed `d`. |
| `0x30..0x4C` | SEED_Z[0..7] | R/W | Eight little-endian words of seed `z`. |
| `0x50` | ERROR_CODE | RO | 0: no error; 1: watchdog; 2: transcoder. |
| `0x54` | SEED_VALID | RO | Bits `[7:0]`: written `d` words; `[15:8]`: written `z` words. All seed words present = `0xFFFF`. |
| `0x1000..0x149C` | EK[0..295] | RO | 296 words = 1184 bytes of `ek`. |
| `0x14A0..0x1DFC` | DK[0..599] | RO | 600 words = 2400 bytes of `dk`. |
| `0x1E00..0x1FFC` | Reserved | RO | Returns 0 when results are valid. |

- Seed/WATCHDOG writes require full words (`WSTRB=0xF`); CTRL/STATUS use the byte-0 strobe.
- START is valid only when `BUSY=0` and `SEED_VALID=0xFFFF`; START clears the seed-valid mask to 0.
- Successful STATUS = **`0xA`**: DONE=1, RESULTS_VALID=1, BUSY=ERROR=0.
- Read output only when RESULTS_VALID=1; a new START, SOFT_RST, or an error invalidates the results.
- Unaligned accesses, unsupported offsets, START with missing seeds or while busy,
  and reads of invalid output return AXI `SLVERR`.

## 2. ML-KEM Usage Sequence

1. Wait for `STATUS.BUSY=0`; write `STATUS=0x6` to clear previous DONE/ERROR flags.
2. Keep the default WATCHDOG or write a new limit to `+0x0C` while idle.
3. Write all 16 seed words, with `i=0..7`:

   ```text
   D[i] -> base + 0x10 + 4*i
   Z[i] -> base + 0x30 + 4*i
   word[i] = b[4*i] | (b[4*i+1]<<8) | (b[4*i+2]<<16) | (b[4*i+3]<<24)
   ```

   In C++, cast each byte to `uint32_t` before shifting.
4. Read `+0x54` and require `SEED_VALID=0xFFFF`.
5. Write **`CTRL=0x1` at `0x40000000`** to START in polling mode.
6. Poll STATUS until `(STATUS & 0x6) != 0`, with a software deadline.
   Read keys only when `STATUS=0xA`. If ERROR is set, read ERROR_CODE before resetting.
7. Read the complete results:

   | Result | Start Address | 32-bit Reads | Size |
   |---|---|---:|---:|
   | `ek` | **`0x40001000`** | 296 | 1184 bytes |
   | `dk` | **`0x400014A0`** | 600 | 2400 bytes |

   Increment the address by 4 bytes for each read; extract the least significant byte first.
   `dk = dk_PKE[1152] || ek[1184] || SHA3-256(ek)[32] || z[32]`.
8. Write `STATUS=0x2` to clear DONE if needed; the keys remain readable after DONE is cleared.
   The next job must rewrite all 16 seed words; no soft reset is needed after success.

**Using IRQs:** configure GIC ID **61** as level-sensitive, then START with `CTRL=0x5`.
The IRQ level is `IRQ_ENABLE && (DONE || ERROR)`; write one to the corresponding
STATUS bits to clear the interrupt source.
The current platform has no AXI INTC at `0x41200000`.

**Recovery:** on a host timeout, write `CTRL=0x2` for SOFT_RST, wait for BUSY to
clear, then reload the seeds. SOFT_RST clears the seeds and invalidates output.
The host deadline measures elapsed time; WATCHDOG counts PL cycles. Do not
return keys after an error or when only part of the result has been read.

## 3. PS UART1 CSRs

**Base: `0xE0001000`.** This is the Xilinx PS UART, not AXI UARTLite.

| Offset | Register | Access | Description |
|---|---|---|---|
| `0x00` | CR | R/W | Bits 0 RXRST and 1 TXRST are self-clearing; bit 2 RX_EN, 3 RX_DIS, 4 TX_EN, 5 TX_DIS. |
| `0x04` | MR | R/W | Data format/channel/clock. **`0x20` = normal, 8N1, reference clock not divided by 8.** |
| `0x08` | IER | W1S | Write 1 to enable the corresponding UART IRQ source. |
| `0x0C` | IDR | W1-disable | Write 1 to disable the corresponding UART IRQ source. |
| `0x10` | IMR | RO | Mask of enabled UART IRQ sources. |
| `0x14` | ISR | R/W1C | IRQ event status; write 1 to clear handled bits. |
| `0x18` | BAUDGEN | R/W | Clock divisor CD, range `1..65535`. |
| `0x1C` | RXTOUT | R/W | RX timeout; write 0 to disable. |
| `0x20` | RXWM | R/W | RX FIFO threshold for trigger events. |
| `0x24` | MODEMCR | R/W | Write 0 to disable hardware flow control. |
| `0x2C` | SR | RO | RX/TX FIFO status and transmit activity. |
| `0x30` | FIFO | Read RX / write TX | Read one RX byte; write bits `[7:0]` to send one TX byte. |
| `0x34` | BAUDDIV | R/W | Divider BDIV, range `4..255`. |

**SR:** RXEMPTY bit 1 (`0x02`), RXFULL bit 2 (`0x04`), TXEMPTY bit 3 (`0x08`),
TXFULL bit 4 (`0x10`), RACTIVE bit 10 (`0x400`), TACTIVE bit 11 (`0x800`).

**IER/IDR/IMR/ISR:** bit 0 RX trigger, bit 3 TX empty, bit 5 RX overrun,
bit 6 framing error, bit 7 parity error, bit 8 RX timeout. Polling does not
require UART IRQs to be enabled. The PS UART IRQ is separate from ML-KEM IRQ 61;
obtain its configuration from the BSP.

## 4. UART1 Usage Sequence

**Direct initialization for the current XSA's 100 MHz UART reference clock:**

1. Write `IDR=0x3FFF` to disable UART IRQs; write `CR=0x28` to disable RX/TX.
2. Write `MODEMCR=0`, `MR=0x20` for normal mode, 8N1, without RTS/CTS.
3. Write `BAUDGEN=124`, `BAUDDIV=6`:

   ```text
   baud = 100000000 / (124 * (6 + 1)) = 115207.37 baud
   deviation from 115200 is approximately +0.0064%
   ```

4. Write `CR=0x03`; wait for `(CR & 0x03)==0` until RX/TX reset completes, with a timeout.
5. Write `ISR=0x3FFF` to clear previous flags; write `RXTOUT=0` for polling.
6. Write `CR=0x14` to enable RX/TX. Set the PC terminal to **115200, 8N1, no flow control**.

In Vitis, use `XUartPs_CfgInitialize`, `XUartPs_SetOperMode(...,
XUARTPS_OPER_MODE_NORMAL)`, and `XUartPs_SetBaudRate(..., 115200)` as an alternative
to direct register writes. The driver obtains the UART clock from the BSP
configuration; select `ps7_uart_1` for the console.
Do not reuse these divisors if the UART clock/XSA changes.

**Transmit/receive after initialization:**

| Operation | Sequence |
|---|---|
| Send one byte | Read SR at **`0xE000102C`**; when `(SR & 0x10)==0`, write the byte to FIFO at **`0xE0001030`**. |
| Receive one byte | Read SR; when `(SR & 0x02)==0`, read FIFO and take bits `[7:0]`. Each read removes the byte from the FIFO. |
| Wait for transmission to complete | Wait for `(SR & 0x08)!=0` and `(SR & 0x800)==0`, with a timeout. |

The firmware connects the two sequences: **UART RX -> PS writes seed CSRs ->
START ML-KEM -> PS reads keys -> UART TX**. UART transfers one byte at a time;
each 32-bit key word must be split into four little-endian bytes. The PC and PS
software must agree on the command/frame format; UART does not start ML-KEM
automatically.
