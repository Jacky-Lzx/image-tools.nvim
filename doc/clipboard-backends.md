# Clipboard readers

All readers feed a private temporary PNG into the same validation, processing,
naming and rollback pipeline. They do not modify the clipboard. Automatic
selection checks executable availability, not clipboard contents:

- macOS: `pngpaste output.png`, then `pbctl paste --type image/png --output output.png`
  if pngpaste is unavailable. An explicit legacy `pngpaste` path remains authoritative.
- Wayland: `wl-paste --no-newline --type image/png` in a Wayland session.
- X11: `xclip -selection clipboard -target image/png -out` in an X11 session.
- Windows/WSL: `powershell.exe -NoLogo -NoProfile -NonInteractive -STA -Command ...`.
  WinForms retrieves the image, saves PNG into a memory stream, then writes raw
  bytes to `Console.OpenStandardOutput`. No user path enters PowerShell source;
  WSL needs no Windows/Linux temporary-path translation.

Linux readers and pbctl request a PNG representation; the clipboard must offer
it. The PowerShell reader requires Windows desktop clipboard access. Installing
a reader does not provide GUI clipboard access in an isolated/headless session.

`insert.clipboard_backend` selects a reader explicitly; `insert.clipboard_tools`
maps backend names to executable paths. Both can be overridden per call. Readers
share `clipboard_timeout` (5000 ms default). Streaming readers write incrementally,
handle partial writes and terminate when output exceeds `max_bytes`. Cancellation
closes the descriptor, kills the process and suppresses late callbacks.

Protocols were checked against the installed pbctl/xclip help and the upstream
[pbctl command reference](https://github.com/hakonharnes/pbctl#paste),
[wl-clipboard manual](https://github.com/bugaevc/wl-clipboard/blob/master/data/wl-clipboard.1),
[WinForms GetImage](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.clipboard.getimage)
and [Image.Save](https://learn.microsoft.com/en-us/dotnet/api/system.drawing.image.save).

## Validation

`tests/workflow/clipboard_backend.lua` tests all command protocols with fake
executables returning real PNG fixture bytes. It covers platform/environment
selection, executable overrides, binary and short writes, invalid images, size
limits, timeouts and late cancellation. It does not access the native clipboard
or establish native Windows/WSL/Wayland/X11 behavior.

For native acceptance, copy `tests/fixtures/fixture.png` into the system clipboard
using the target platform's image application, then run:

```sh
export IMAGE_TOOLS_ROOT="$PWD"
export IMAGE_TOOLS_TEST_TMP="$(mktemp -d)"
export IMAGE_TOOLS_CLIPBOARD_BACKEND=auto # or a specific reader
nvim --headless -u NONE -i NONE --noplugin -l tests/manual/clipboard_native.lua
```

The manual test checks decoded pixels and the inserted reference. The caller
owns the prepared clipboard and any restoration. Record OS, reader version and
selected backend with results; no native platform is marked validated solely
because the automated protocol suite passes.
