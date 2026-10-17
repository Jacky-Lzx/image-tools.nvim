# Automated and manual validation

Run `sh tests/run.sh` from a checkout. Each Lua suite gets a fresh Neovim without
user configuration; generated files/caches/logs use a disposable directory. The
runner stops on the first failure and preserves its exit status. See README for
the optional dependency switches and the distinction between recognition,
window lifecycle, protocol responses and visible pixels.

`tests/core/startup.lua` checks that setup, refresh, diagnostics, cleanup and
reconfiguration retain deferred modules, and that file canvases and floats
share the first lazily created pixel pool. Set `IMAGE_TOOLS_LAZY_ROOT` to an
installed lazy.nvim checkout to run `tests/core/lazy.lua`. It executes the README
spec in isolated child processes and checks empty/unrelated buffers, document
filetypes, command/API loading, uppercase image/PDF reads, and actual startup
file arguments. No plugin installation or user-config writes are needed.
Startup timings are available through `tests/bench/startup.lua`; see
[performance](performance.md). A passing loading test does not establish visible
terminal rendering.

`tests/workflow/insert_mode.lua` runs through Neovim's main event loop so it can
verify actual Insert mode and queued typing after file insertion and simulated
clipboard paste. It covers all placement strategies, UTF-8 prefixes, existing
descriptions, multiline LaTeX captions, Typst reference ends, failures and window
focus preservation. LaTeX tests check the figure template, filename-derived labels,
batch undo and real graphicx compilation when available.

Template, processing and naming workflow suites cover their public configuration,
real conversion/resize, captured contexts, menus and rollback. Clipboard backend
tests exercise executable protocols with real binary fixtures, partial writes,
limits, timeout and cancellation; see [native coverage boundaries](clipboard-backends.md).
HTML tests cover escaped markup, entities, byte ranges, context exclusions and
cache edits. Adapter tests cover registration replacement/cleanup, captured
authority and offline project discovery. Cursor lifecycle and main-loop insertion
tests include HTML; the latter also exercises a registered Org adapter.

`tests/terminal/stream.lua` checks incremental Base64 boundaries, serialized
concurrent graphics, queued/partial cancellation, write failures, deferred
response timeouts and handler cleanup. `tests/document/tex_multiline.lua` also
checks shared decodes across rows, edit invalidation, nested command exclusion,
oversized neighboring lines and cache eviction. Encoding/scheduling measurements
are available through `tests/bench/upload.lua`; see [performance](performance.md).

## Continuous integration

`.github/workflows/ci.yml` runs on pushes, pull requests and manual dispatches:

| Job | Coverage |
| --- | --- |
| Format (Ubuntu 24.04) | Pinned StyLua over implementation/tests, shell syntax and whitespace |
| Basic (macOS 15) | Required headless suites and Python PTY protocol scenarios |
| Integration (macOS 15) | The same suite plus pinned real LaTeX/Typst parsers, real Snacks picker windows/TUI, LaTeX/Typst compilation and SVG/PDF tools |

GitHub Actions are pinned by commit. `tests/ci/versions.sh` pins Neovim, StyLua,
the Tree-sitter CLI, both parser revisions and Snacks. The integration installer
generates ABI 15 parsers and builds them with the runner's C/C++ compiler. No
external plugins are vendored into this repository. `tests/ci/preflight.lua`
requires both parsers, Snacks and integration executables before running suites,
so a missing promised dependency fails the job instead of silently skipping it.

Media tools and compilers come from Homebrew on the hosted macOS runner, whose
image and package revisions can change. CI saves their actual versions and the
suite output as job artifacts; this is a pinned plugin/parser/toolchain baseline,
not a hermetic operating-system image. Native clipboard tests remain manual.
The BasicTeX installation updates `tlmgr` itself before installing TeX packages;
CTAN can require a newer package manager than the one bundled with the installer.
Mocked formula-worker tests provide their own executable discovery and process
results, so the basic suite does not require `latex` or `dvipng`. Real formula
compilation remains optional locally and required by integration preflight.
Tree-sitter failure mocks also supply query compilation, so diagnostic tests
run without installed LaTeX/Typst grammars. Use a clean `XDG_DATA_HOME` and a PATH
without TeX to reproduce the basic environment locally; real parser/toolchain
coverage belongs to the integration configuration.
Hosted CI uses a simulated Kitty responder; it cannot establish visible rendering
in a real Kitty window. A newly added workflow is unverified on GitHub until an
actual run completes after pushing.

## Reproduce the integration fixtures locally

Install the Neovim/Tree-sitter versions in `tests/ci/versions.sh`, a C/C++ compiler,
Node.js, Python 3, ImageMagick with Ghostscript, Poppler, librsvg, latex, dvipng,
amsmath/amssymb, pdflatex and
Typst. If you need a local CLI without installing it globally:

```sh
. tests/ci/versions.sh
npm install --prefix /tmp/image-tools-tree-sitter "tree-sitter-cli@$TREE_SITTER_VERSION"
export PATH="/tmp/image-tools-tree-sitter/node_modules/.bin:$PATH"
sh tests/ci/install-fixtures.sh /tmp/image-tools-ci-fixtures
export IMAGE_TOOLS_PARSER_ROOT=/tmp/image-tools-ci-fixtures/runtime
export IMAGE_TOOLS_SNACKS_ROOT=/tmp/image-tools-ci-fixtures/snacks.nvim
nvim --headless -u NONE -i NONE --noplugin -l tests/ci/preflight.lua
sh tests/run.sh
```

Use a new disposable fixture directory after changing pins. The installer refuses
to replace a checkout at a different revision. Fixture sources, generated parsers
and optional plugins remain outside the plugin checkout and active editor config.

## Real Kitty acceptance

The [manual test gallery](../examples/README.md) bundles all supported image
extensions, transparency and aspect-ratio examples, spaces/Unicode in paths and
a three-page PDF. It includes an isolated-editor command and expected results
for users testing their own setup. The smaller fixtures below remain useful for
the core acceptance sequence.

Run these checks in a direct local Kitty session, with multiplexers disabled.
Record `kitty --version`, `nvim --version`, platform and transport setting with
the result. From the repository, start an isolated editor:

```sh
nvim -u NONE -i NONE --noplugin \
  -c "lua vim.o.termguicolors=true; vim.opt.rtp:prepend(vim.fn.getcwd()); require('image_tools').setup()" \
  tests/fixtures/demo.md
```

1. Enter the image line. Verify four visible colored quadrants, correct aspect
   ratio and a preview after the automatic delay. Move within the reference and
   leave the line: it should stay stable, then disappear without residue.
2. Re-enter the line and run `:ImageInfo`. Check ready state/cache reuse. Open a
   second split, scroll, resize and change tabs; confirm clipping and cleanup.
3. Run `:ImageOpen tests/fixtures/fixture.pdf`. Check both pages with `]p`/`[p`,
   zoom with `+`/`-`, pan with arrows and restore fit with `0`. Two splits should
   retain independent zoom/pan and show the correct page pixels.
4. Preview a missing image explicitly and check `:ImageInfo` for the retained
   error/stage. Close/clear the preview and confirm there are no leftover hints,
   placeholders or images. Run `:ImagePreviewClearCache`, then reopen an image.
5. Repeat the preview checks with `transport="file"` and `transport="direct"`
   in setup. If using Snacks, repeat image selection, confirmation, cancellation
   and picker resizing in the actual configured picker.

Report the checks actually performed and any failures. Protocol-test success
alone does not satisfy this manual acceptance, and this guide does not mark a
terminal/platform as validated without an observed run.

## Formula coverage

`tests/document/math.lua` checks delimiters/environments, byte ranges, excluded
contexts, edits, budgets and mixed image/formula selection. The core formula
lifecycle suite checks pending/visible previews, edits, cross-row movement,
manual reload, automatic delay and stale-result rejection. `tests/media/math.lua`
checks keys, dependency errors, shared workers, leases and cancellation; when
latex/dvipng are installed it also compiles real inline/display/aligned formulas
and verifies transparency. TUI formula scenarios exercise actual TeX output
through file and direct Kitty transports, including shared Markdown/LaTeX pixels.
Resolution checks compare real 180/360-DPI outputs, confirm higher pixel counts
and stable logical display dimensions, and verify that the float uses the logical
size while diagnostics and upload retain the full raster dimensions.

For visible acceptance, open `examples/math.md` and `examples/math.tex` in Kitty.
Check readable fractions, roots, matrices and aligned rows on a transparent
background. Move inside and outside a multiline formula, edit its body, remove
a delimiter, change the colorscheme and run `:ImageReload` / `:ImageInfo`. Verify
that stale pixels and loading hints disappear, cached formulas return correctly,
and code/comment examples do not preview. Real compilation and simulated Kitty
traffic do not establish the visible-pixel result; record that check separately.

## Image move transactions

`tests/workflow/move.lua` checks destination-only rewriting across Markdown
inline/reference/wikilinks, multiline LaTeX, Typst and HTML. It exercises live
unsaved buffers, CRLF disk documents, stale snapshots, incomplete scans, exclusive
destinations, injected mid-commit filesystem failure/rollback, and review cancellation.
