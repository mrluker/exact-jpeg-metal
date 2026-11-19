# Parallel Huffman decoding by self-synchronisation

The entropy-coded part of a baseline JPEG is one long bit string of variable-length Huffman codes. A code's
meaning depends on everything before it (which table applies, which coefficient comes next), so the obvious
decoder is sequential, and on a CPU it is the most expensive stage of JPEG decoding. Restart markers would cut
the stream into independent pieces, but most camera JPEGs have none, and GPU decoders often keep this stage
on the CPU (nvJPEG, for example, has both CPU and GPU Huffman back ends).

exact-jpeg-metal decodes the whole stream on the GPU with the self-synchronisation method of Weißenberger and
Schmidt ("Massively Parallel Huffman Decoding on GPUs", ICPP 2018). This note describes the method as
implemented in `Sources/ExactJPEG/Shaders/Decode.metal` and `Sources/ExactJPEG/Decoder.swift` (a port of
the CUDA implementation in exact-gpu-jpeg), including what we added.

## Decoder state

After removing byte stuffing (the `00` after each `FF`) and restart markers, decoding is a deterministic state
machine. Its state at a symbol boundary is

    (bit position, block within the MCU, coefficient index)

packed into 64 bits (`pk` in `Decode.metal`). Given a state, the next symbol, and so the next state, is fixed.
The block-within-MCU says which component (and so which DC and AC tables) applies; the coefficient index says
whether a DC or an AC symbol comes next.

## Self-synchronisation

Huffman codes self-synchronise: start decoding at a wrong bit position and, after a short while (typically
tens to a few hundred bits for JPEG tables), the decode lands on a true symbol boundary and from then on
follows the true decode exactly. JPEG adds the block/coefficient counters to the state, but those
synchronise too, because the end of a block (EOB, or coefficient 63) is a strong, frequent signal.

The stream is cut into chunks of `S` bits (2048 by default), one GPU thread each (`sync_pass`, 128 threads per threadgroup):

1. **Pass 0** . Every chunk decodes from a guessed state: its own first bit, first block of an MCU,
   DC next. It runs past its end to the first symbol boundary there and records that **exit state**, plus the
   number of blocks it finished.
2. **Passes 1, 2, ...** . Chunk *i* takes chunk *i − 1*'s exit state as its entry. If that differs
   from the entry it used last time, it decodes again and records its new exit; a flag says whether any exit
   changed. Chunk 0 starts from the true state, so after pass *k* the first *k* chunks are certainly right;
   in practice every chunk is right after 1–5 passes, because each chunk's guessed decode has usually
   synchronised long before its end.
3. **Fixed point.** When no exit changes, every chunk's entry is the true state at its position (by induction
   from chunk 0). An exclusive prefix sum of the per-chunk block counts gives each chunk the number of its
   first block.
4. **Write pass** (`decode_write`). Each chunk decodes once more from its true entry and writes coefficients.
   A block belongs to the chunk in which its DC symbol starts: a chunk first skips the rest of a block begun
   in the chunk before it, and finishes its own last block past its end.

All passes are encoded into the same command buffer as the rest of the decode (8 by default), with no host round trip; a pass after the fixed point costs almost
nothing (each thread compares two 64-bit states and exits). If the chunks have not synchronised within those 8 passes the
decode is redone with 64; if that is not enough the GPU path declines the image (CPU fallback). We have not seen that on real photos with the default
chunk size; the test suite shows it can happen with absurdly small chunks (64 bits).

## Additions in this implementation

**Checkpoints.** A re-decode in pass *k* usually rejoins the previous decode quickly. Each chunk records its
state at three interior checkpoints; when a re-decode reaches a checkpoint in the same state as last time, the
rest of the chunk would decode identically, so it stops and only shifts its block count. This makes the
later passes cheap.

**Restart intervals.** With restart markers (`DRI`), the unstuffing kernel removes the `RSTn` markers,
checks their numbering, and records where each interval starts in the unstuffed bit stream. Chunks are then
cut so that none crosses an interval boundary (`make_chunks`). A chunk that starts an interval has a known
true state (its first bit, first block, DC next, which is exactly pass 0's guess), so it never re-decodes, and
synchronisation can never propagate across intervals. Block numbers come from a segmented prefix sum: interval
*k* starts at block *k* × interval × blocks-per-MCU. DC prediction restarts per interval
(a segmented prefix sum, `scan_*` in `Common.metal`). Restart intervals therefore make decoding faster (shorter chains), but the decoder does not
need them.

**Error detection.** The write pass decodes from true states, so anything wrong there is an error in the file:
a code that is not in the table, an AC run past coefficient 63, a restart interval whose blocks need bits past
its marker, or an interval (or the stream) that ends before its last block. Each sets a bit in an error word;
the image is then declined. The header parser rejects tables libjpeg-turbo would reject (and some it would
accept), and the pixel stage flags coefficient values outside the range where libjpeg-turbo's SIMD and C
IDCTs agree. In every such case the decoder returns None rather than guess what libjpeg-turbo's
error-concealment would produce.

**Bounds.** Every decode loop advances the bit position by at least one bit per symbol and at most 31, and
stops at its chunk's end (a block in progress adds at most 64 symbols), so a thread reads at most about 4 KB
past its chunk; the stream buffer has 4 KB of zero padding. Kernels index every array with bounds computed on
the host from the header, and block numbers are clamped to the image's block count.

## Cost

On an Apple M1 Max (32-core GPU) the whole decode of a 30 MP 4:2:2 camera-like JPEG (7.8 MB, no restart
markers), Huffman stage included, takes about 6.2 ms of GPU time; libjpeg-turbo spends about 104 ms on one
CPU core. Two synchronisation passes are typical.
