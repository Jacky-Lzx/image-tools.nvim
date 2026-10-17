# Preview performance

## Startup and lazy loading

The README lazy.nvim spec leaves the plugin unloaded in empty sessions and
unrelated filetypes. Filetype, command, Lua API and binary `BufReadCmd` triggers
activate it when needed. Setup itself keeps file interception ready, deferring
floating previews, terminal pixels and default insertion helpers. Supplied
insertion options are validated immediately, so their validation helpers can
still load during setup. The first view pays its deferred loading cost.

Run `nvim --headless -u NONE -i NONE --noplugin -l tests/bench/startup.lua`
from the repository. It measures API require, setup, and the first scheduled
refresh in 30 fresh Neovim processes, with synchronous and post-refresh module
counts. Set `IMAGE_TOOLS_BENCH_RUNS` to change the sample count, or
`IMAGE_TOOLS_STARTUP_BASELINE` to a checkout/snapshot directory with `lua/`
to compare versions. Use the same machine and Neovim build for comparisons.

In one local Neovim 0.12.6 run with default options, median require + setup
decreased from 3.71 ms to 2.48 ms (about 33%). Synchronous module count decreased
from 19 to 9, and post-refresh count from 22 to 10. Setup alone decreased from
3.29 ms to 2.11 ms. These timings exclude Neovim process startup, lazy.nvim's
own overhead, first media preparation, terminal I/O and visible rendering.
They measure fresh processes with normal filesystem caches, not cold storage.
There are no machine-dependent timing thresholds in the tests.

## Reference lookup

Typst checks the current line for a possible image call before inspecting prefix
context. LaTeX searches a bounded neighborhood for a complete reference covering
the current row, so commented option rows can trigger a multiline preview.
Rows beyond `max_scan_lines` are rejected before reference detection.

The Lua syntax cache keeps checkpoints every 128 lines and up to 128 queried
results per buffer. Edits retain checkpoints and query results strictly before the changed suffix;
insertions/deletions invalidate shifted rows. Reload invalidates the whole cache;
unloading or deleting the buffer releases it. Tree-sitter instead keeps an incremental capture index:
edits invalidate the affected suffix and overlapping reference ranges, preserving
valid prefixes. Queries advance the index through the requested row, while LaTeX
argument decoding may look ahead to the reference's end within its configured
limits. Paths, custom resolvers, VimTeX roots and filesystem checks stay live.

Markdown reference definitions use a separate 128-line block index, including
forward definitions. Edits retain complete blocks before the changed block and
rebuild its suffix, since a changed code fence can affect later definitions.
The label map is assembled in document order so the first visible definition
still wins. Reloads and scan-limit changes rebuild the index; detaching releases it.

LaTeX additionally keeps up to 128 row results, 128 command-position blocks of
32 lines and 256 anchored command decodes per buffer. Adjacent rows share the
position index and decoded commands rather than reparsing overlapping text.
Line/byte/scan budgets remain part of decode keys. Cold index reads can include
the surrounding block boundaries; blocks exceeding the byte budget use the
bounded query slice instead. Edits invalidate overlapping lookahead and shifted
suffix entries; reloads and detaching discard all three caches. Returned
candidates are independent copies, and environment context, roots, resolvers
and target filesystem checks remain live. An earlier malformed command cannot
consume a later reference beyond its own configured reference budget.

Markdown formula lookup confirms matching backtick runs before excluding code.
Multiline code-span lookahead stops at paragraph/fence boundaries and the scan
ceiling. The syntax cache tracks code-span lookahead dependencies: editing a
future closer invalidates earlier affected checkpoints and query results.
Unrelated suffix edits preserve formula prefix snapshots in both document types.

Project asset inspection reads directory entries in batches of at most 32
concurrent `lstat` requests, yielding between batches. Live-buffer observers and
rename/filetype/load events mark an inspection invalid without repeatedly walking
every tracked document for each entry. Before publishing, complete live-buffer
identity checks and asynchronous disk-version checks still reject stale results.
Concurrent inspections own independent listeners; completion/cancellation removes
their listeners and event handlers. Entry/byte budgets and symlink exclusions
continue to apply.

The tests verify cache/index reuse using counters and reference identities. The recognition benchmark below measures Lua lookup latency; these
checks do not establish terminal decode/render timing. A cold candidate query
may still need preceding context, and a Tree-sitter root parse can cover the
whole document even when capture traversal is bounded.

Converted formats share pending requests when the source version, PDF page,
renderer, cache directory and validation settings match. Each subscriber receives
its own metadata and cancellation handle. The worker is killed only when its last
subscriber cancels; failures release the shared slot so later requests can retry.
The source version is checked again before publishing converted pixels. PNG
metadata reads remain independent; terminal pixels share one runtime pool.

Conversion, clipboard normalization and import hashing share the process budget.
Conversions/clipboard work use the interactive class; hashes use the background
class. Waiting interactive jobs take priority, with FIFO ordering within each
class. If background jobs are waiting, at most three interactive jobs start before
one background job is admitted. Running jobs are never preempted, and cancelled
running jobs keep their slot until exit. Queue status includes waiting counts for
both classes; priority changes waiting order, not the concurrency/timeout limits.

Disk conversions default to a maximum of 256 files and 512 MiB. Directory scans,
file stats and deletion run asynchronously, with directory traversal batched in
64-entry chunks. Cleanup only selects the plugin's 64-hex-digit PNG filenames;
unrelated files, symlinks and temporary conversion files are excluded.

Access order is tracked in memory without modifying the PNG timestamps or changing
terminal-cache keys. Existing file modification times supply the initial order
after a restart. Workers and subscribers hold reference-counted file leases; files
remain protected until subscribers release or close their preparation handles.
Cancelling a pending request releases its work; after delivery, the separate
release/close operation unpins its output. The media entry point's prepare
cancel function performs close. Readers
arriving during a deletion wait for it before checking/recreating the output.
Active files may temporarily exceed the budget; releasing them triggers deferred
cleanup. `ImageCacheClear` / `clear_disk_cache(callback)` remove unused disk
conversions independently of `ImagePreviewClearCache` (terminal graphics).

`:checkhealth image_tools` reads the current managed disk-cache file count and
bytes, configured limits, protected usage, directory path and cleanup state.
Inspection is read-only and batched, with a three-second timeout: it does not
create cache directories, initialize the plugin, change access order or evict
files. Missing directories are reported as unused caches; unreadable directories
and timed-out inspections produce diagnostics instead of an estimated usage.

## Recognition latency benchmark

Run `nvim --headless -u NONE -i NONE --noplugin -l tests/bench/latency.lua`
from the repository. It reports p50/p95 milliseconds for cold lookup, warm lookup,
tail edits and movement across image rows in 1,000/10,000-line documents, using
the Lua backend for Markdown inline/reference images, LaTeX and Typst. Timings include live path resolution.
The benchmark uses temporary buffers, performs no conversion or terminal upload,
and does not impose machine-dependent pass/fail thresholds. Compare runs on the
same Neovim build and hardware; visible rendering still needs Kitty validation.

## Per-view timing diagnostics

`info().timings` / `:ImageInfo` expose monotonic-clock milliseconds for:

- `lookup_ms`: synchronous reference detection/path resolution, when selected
  from a document. A pending Tree-sitter parse's asynchronous wait is excluded.
- `automatic_delay_ms`: actual timer wait for a new automatic selection.
- `preparation_ms`: preparation until delivery, including queue, conversion,
  cache leases, reads and validation.
- `queue_ms` / `conversion_ms`: process queue wait and converter runtime,
  clipped to this subscriber's lifetime when a shared worker started earlier.
  Native PNG and disk-cache reuse require no converter and report zero.
- `transfer_ms`: the transfer request until its completion, including upload
  waits, placement replies and retry overhead.
- `upload_ms` / `placement_ms`: this view's wait for pixels and placement
  acknowledgements. Shared uploads count only this consumer's wait; cached
  pixels do not repeat an earlier upload's duration. A placement retry adds
  both attempts' waits.
- `draw_ms`: placeholder/window drawing after terminal acknowledgement.
- `total_ms`: measured render-session elapsed time plus available lookup and
  automatic-delay times. File-viewer PDF metadata discovery precedes the render
  session and is excluded.

The preparation/transfer fields contain their more detailed subphases; summing
every field double-counts them. Stages not yet reached or unavailable from an
injected service are omitted. Pending outer-stage times grow when inspected;
ready/failed timings freeze. Snapshots are independent tables, including retained
floating-preview failures and per-window file-viewer diagnostics. These clocks
measure plugin processing and protocol acknowledgement, not visible terminal
pixels or GPU presentation. They allocate no per-view sampling timer.

Viewer zoom scales conversion output bounds and PDF density up to eight times,
further constrained by configured dimension/pixel limits. Conversion keys and
coalescing include the detail level. Panning changes only a placement's Kitty
source rectangle, so native PNG pan/zoom does not require another pixel upload.

## Direct-upload encoding benchmark

Direct transfer uses a shared terminal send queue. Encoding yields between
batches of at most 32 Kitty chunks (96 KiB of raw PNG bytes), without allocating a complete
Base64 image or concatenating the entire wire stream. Source PNG bytes remain
resident until transmission finishes. Other plugin graphics commands wait until
the final chunk, as required by the
[Kitty chunking protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/#remote-client).
Cancelling a partial upload sends its deletion before draining the queue;
queued cancellations release their bytes without starting an upload. Reply
handlers are installed before the first chunk, while response timeouts begin
after the last chunk. Queued placement/file requests start their timeout only
when written. Queue and transmission duration still contribute to transfer timing.

Run `nvim --headless -u NONE -i NONE --noplugin -l tests/bench/upload.lua`.
It measures total encoding/scheduling time and the maximum 1 ms timer gap for
1/8/32 MiB inputs with a simulated immediately acknowledging terminal. Set
`IMAGE_TOOLS_PROTOCOL_BASELINE` to an absolute saved pre-change `protocol.lua`
to compare whole-image encoding on the same machine. It excludes disk reads,
real terminal I/O, PNG decoding and visible rendering, and has no timing thresholds.

## Import hashing benchmark

Run `nvim --headless -u NONE -i NONE --noplugin -l tests/bench/deduplicate.lua`
from the repository. The benchmark hashes temporary binary files of 1, 8 and
32 MiB twice and reports cold/warm total time and the largest event-loop timer
gap. A 1 ms repeating timer samples editor responsiveness; these are observations,
not scheduling guarantees or end-to-end insertion timings. No timing threshold
is used. Set `IMAGE_TOOLS_CONTENT_BASELINE` to an absolute saved pre-change
`content.lua` to compare implementations on the same machine.

In one local Neovim 0.12.6 run, the 32 MiB baseline took 100.61 ms cold and
97.68 ms on repeat, with a 92.02 ms maximum cold loop gap. Background hashing
took 113.12 ms cold and 0.03 ms on repeat, with a 1.53 ms maximum cold loop gap.
Cold process startup adds latency; the improvement is editor responsiveness and
avoiding repeated work. Results depend on hardware, load and filesystem caches.

Hash workers share the conversion queue's concurrency budget and have a fixed
10-second timeout. Their file data and Base64/SHA256 allocations are confined to
child processes, bounded by max_bytes per worker. The editor holds at most 128
digest metadata entries, keyed by path/inode/size/high-resolution mtime/ctime.
Every hit checks the current revision; changed sources invalidate the digest.
Concurrent subscribers share a worker and cancel independently. Source revisions
are checked in the worker and again before the parent publishes/caches its result.
Directory lookup still scans candidates by extension/size and performs live stats;
this cache removes repeated content reads and hashing, not directory traversal.
