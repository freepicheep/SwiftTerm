# Cold history: compact scrollback

A scrollback row costs a full `BufferLine` whatever it holds: 8 bytes per
column for its cells, plus the line object, its render identity and its cell
page: about 820 bytes for an 80-column row. Ten thousand lines of history take
about 8 MiB. Hosts that keep many terminals (a multiplexer server, a tabbed
app) pay that per terminal, twice if they run a second emulator per session.

Cold history moves scrollback rows that nobody is looking at out of the line
ring into a compact encoding, and restores them when they are read. The same
10,000 lines take about 1.3 MiB (measured heap: 823 bytes a row before, 139
after, counting the ring slot and allocator rounding), and the parse and
scroll paths are unchanged.

## The model

This follows Ghostty's cold page compression (`src/terminal/PageList.zig`,
`src/terminal/compress/`), adapted to SwiftTerm's line ring:

- **Nothing happens during output.** A first version compacted each row as it
  scrolled into history. Encoding a row costs about as much as SwiftTerm spends
  parsing and placing it, so the scroll benchmarks ran two to five times
  slower. Compaction is now work the host schedules when output is idle.
- **The host decides when.** `Terminal.historyActivity` changes whenever there
  may be new work; when it has changed and output has been quiet for a while
  (a second, say), call `Terminal.compactHistory(.incremental)` until it
  returns `.complete`, a few milliseconds apart. Each step moves at most 256
  rows and inspects at most 4,096 slots. `.full` does everything at once.
- **Reading restores.** A cold row's slot in the ring is empty. The ring's
  `_read` accessor already fills empty slots, so a read restores the row
  without any new check on the hot path. The next idle pass moves it out again
  once nothing refers to it.
- **Readers that only look don't restore.** Search, selection, text
  extraction and `Buffer.readScrollInvariantLine(row:)` read a cold row through
  a temporary copy. The semantic prompt scanners read marks and wrap flags
  without restoring anything; cold rows never carry marks.

## What is cold

A row is moved when it is in history (above the screen), outside the viewport,
carries no images, no semantic prompt marks and no continuation group, and the
ring holds the only reference to it (`isKnownUniquelyReferenced`). The last rule
keeps any line object someone else holds (the semantic origin, a host's
reference) in the ring, so changes made through it stay visible.

## Keys

Cold rows are found by key: `CircularBufferLineList.droppedCount + index`,
where `droppedCount` counts every line dropped off the start of the ring
(recycled, overwritten or trimmed). As older lines are dropped, a history
row's index falls by one and `droppedCount` rises by one, so its key stays the
same. Every operation that moves history rows does so by dropping lines at
the start; the operations that shift the middle of the ring work on screen
rows. Reflow is the exception: it rewrites the whole ring, so a column change
restores all cold rows first, as Ghostty restores pages before a resize.

A full ring that recycles a slot whose row is cold drops that row and gets a
fresh line object for the new bottom row (`lineForDroppedColdRow`).

## Storage

`HistoryRowCodec` encodes one row. A `PackedCell` is 64 bits: a 24-bit content
field and 40 bits of style, width, protection, payload and semantic state.
Across a row those 40 bits rarely change, so a row is stored as runs (the cell
with its content cleared, and where the run starts) followed by every cell's
content in 1, 2 or 4 bytes, the smallest that fits. Cells past the last one
that differs from the row's blank tail are not stored. When runs would not
save anything (CJK text alternates wide heads and spacer tails) the cells are
stored raw. Decoding is exact: identifiers stay those of the terminal's
`CellArena`.

Both directions work eight cells at a time with `SIMD8<UInt64>`: a block whose
templates all match the current run is checked with one vector compare, and its
content is narrowed or widened with one vector conversion. Only blocks where a
run changes take the per-cell path.

`HistoryChunk` holds the rows one compaction step moved, in one allocation of
exactly the size needed: first what lookups need per row (a 32-bit key offset,
a 32-bit payload offset, and the wrapped and dead flags), then each row's
24-byte header (width, stored count, runs, content width, render mode, bidi
state, tail cell) and its encoded cells. There is no allocation per row. A
restored row is marked dead, and a chunk is released when all of its rows are
dead, restored or dropped off the top.

For a plain 72-character line with one style: 9 bytes of lookup data, a
24-byte header, one 8-byte template, one start (padded to 8) and 72 content
bytes: about 121 bytes of chunk, against about 820 for the line.

## Costs

Measured on an M1 Pro with `Tools/SwiftTermBenchmarks` (`history_*`), 80x25,
10,000 lines of styled output:

| | |
| --- | --- |
| Compact 10,000 rows and restore them all | 4.4 ms |
| Read every cold row without restoring it | 3.0 ms |
| 10,000 lines of output over warm history | 1.9 ms |
| The same right after compaction | 5.6 ms |

The last row includes the compaction itself and rebuilding a line object for
each cold row the output recycles. It is paid once per burst, for at most one
scrollback's worth of lines: after that the burst runs over rows that are not
cold.

On the vtebench workloads the parse and scroll paths retire the same number of
instructions as before, within 0.4%.

## Not done

- **Compressing chunks.** The encoded payload is mostly text now; LZ4 over a
  chunk (as Ghostty does for pages) would roughly halve it again. The lookup
  data is kept separate so that a compressed payload would still answer
  `isRowWrapped` and key lookups without decompressing.
- **Recycling line objects.** A burst right after compaction allocates a line
  object per recycled cold row.
