# Preview performance

Typst checks the current line for a possible image call before inspecting prefix
context. LaTeX searches a bounded neighborhood for a complete reference covering
the current row, so commented option rows can trigger a multiline preview.
Rows beyond `max_scan_lines` are rejected before reference detection.

The Lua syntax cache keeps checkpoints every 128 lines and up to 128 queried
results per buffer. Any edit/reload invalidates that cache; unloading or deleting
the buffer releases it. Tree-sitter instead keeps an incremental capture index:
edits invalidate the affected suffix and overlapping reference ranges, preserving
valid prefixes. Queries advance the index through the requested row, while LaTeX
argument decoding may look ahead to the reference's end within its configured
limits. Paths, custom resolvers, VimTeX roots and filesystem checks stay live.

The tests verify cache/index reuse using counters and reference identities. The
repository does not provide a maintained end-to-end latency benchmark; these
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
