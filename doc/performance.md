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
