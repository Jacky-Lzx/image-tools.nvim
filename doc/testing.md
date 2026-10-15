# Automated and manual validation

Run `sh tests/run.sh` from a checkout. Each Lua suite gets a fresh Neovim without
user configuration; generated files/caches/logs use a disposable directory. The
runner stops on the first failure and preserves its exit status. See README for
the optional dependency switches and the distinction between recognition,
window lifecycle, protocol responses and visible pixels.

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
Hosted CI uses a simulated Kitty responder; it cannot establish visible rendering
in a real Kitty window. A newly added workflow is unverified on GitHub until an
actual run completes after pushing.

## Reproduce the integration fixtures locally

Install the Neovim/Tree-sitter versions in `tests/ci/versions.sh`, a C/C++ compiler,
Node.js, Python 3, ImageMagick with Ghostscript, Poppler, librsvg, pdflatex and
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
