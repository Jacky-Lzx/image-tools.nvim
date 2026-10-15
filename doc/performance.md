# Preview performance

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
the Lua backend for Markdown/LaTeX/Typst. Timings include live path resolution.
The benchmark uses temporary buffers, performs no conversion or terminal upload,
and does not impose machine-dependent pass/fail thresholds. Compare runs on the
same Neovim build and hardware; visible rendering still needs Kitty validation.

Viewer zoom scales conversion output bounds and PDF density up to eight times,
further constrained by configured dimension/pixel limits. Conversion keys and
coalescing include the detail level. Panning changes only a placement's Kitty
source rectangle, so native PNG pan/zoom does not require another pixel upload.

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
