# Preview performance

Reference detection rejects ordinary LaTeX/Typst lines before scanning preceding
text. Syntax checkpoints every 128 lines and up to 128 queried results per buffer
avoid rescanning unchanged prefixes. Any edit/reload invalidates the buffer cache;
unloading or deleting the buffer releases it. Paths, custom resolvers, VimTeX
roots and filesystem existence checks are evaluated on each request.

A local headless Neovim measurement of a 10,000-line synthetic document showed
ordinary-line detection around 0.01 ms for both LaTeX and Typst, versus roughly
8 ms / 28 ms before this optimization. Warm candidate queries were about 0.03 ms.
These are Lua/parser measurements, not terminal decode/render latency. The first
candidate query after an edit may still need to scan its preceding context.

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
remain protected until their preparation handles are cancelled/closed. Readers
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
