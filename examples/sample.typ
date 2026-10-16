// Source for sample.pdf; also usable for Typst image-reference preview checks.
#set document(title: "image-tools.nvim manual PDF sample", author: "image-tools.nvim")
#set page(width: 180mm, height: 240mm, margin: 16mm, numbering: "1 / 1")
#set text(size: 12pt, fill: rgb("#172033"))

= PAGE 1 / PORTRAIT

The first page has a red marker and a four-color image.
Floating and picker PDF previews should always show this page.

#rect(width: 100%, height: 12mm, fill: rgb("#e74c3c"), stroke: none)

#image("images/sample.png", width: 100%)

Open this PDF with `:ImageOpen examples/sample.pdf` from the repository root.
Use `]p` and `[p` to change pages, `+` / `-` to zoom, arrow keys to pan,
and `0` to restore fit.

#pagebreak()
#set page(width: 240mm, height: 180mm)

= PAGE 2 / LANDSCAPE

The second page is wider and has a green marker. The page orientation,
number and marker should change together when paging.

#rect(width: 100%, height: 12mm, fill: rgb("#27ae60"), stroke: none)

#image("images/wide.png", width: 100%)

#pagebreak()
#set page(width: 180mm, height: 240mm)

= PAGE 3 / DETAIL

The last page has a blue marker and a numbered grid for zoom/pan checks.
The outer border and every row/column should be visible at fit zoom.

#rect(width: 100%, height: 12mm, fill: rgb("#2980b9"), stroke: none)

#grid(
  columns: (1fr, 1fr, 1fr, 1fr),
  gutter: 3mm,
  ..range(1, 25).map(n => rect(
    width: 100%, height: 17mm,
    fill: if calc.rem(n, 2) == 0 { rgb("#e2e8f0") } else { rgb("#f8fafc") },
    stroke: 0.5pt + rgb("#64748b"),
    align(center + horizon, text(size: 16pt, str(n))),
  )),
)
