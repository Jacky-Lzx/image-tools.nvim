# Formula preview examples

Open this file in Kitty with image-tools.nvim loaded. Move onto each expression
or run `:ImagePreview`. Formulas use floating previews and retain the source text.
Install `latex`, `dvipng`, `amsmath` and `amssymb` first.

Inline: $e^{i\pi} + 1 = 0$ and $\frac{a+b}{c}$ on the same line.

Parentheses: \(\alpha^2 + \beta^2 = \gamma^2\).

$$
\sum_{k=1}^{n} k = \frac{n(n+1)}{2}
$$

\[
\begin{pmatrix} a & b \\ c & d \end{pmatrix}
\begin{pmatrix} x \\ y \end{pmatrix}
\]

\begin{align*}
f(x) &= x^2 + 2x + 1 \\
&= (x+1)^2
\end{align*}

\[
f(x) = \begin{cases}
x^2, & x \geq 0 \\
-x, & x < 0
\end{cases}
\]

The code span `$not_rendered$` and the fenced example below should not preview:

```latex
$$x^2 + y^2$$
```

<!-- $not_rendered$ -->

Move between rows of a display formula: the preview should stay open. Edit a
formula: the preview should update. Leave its range: the preview should close.
Run `:ImageInfo`, `:ImageReload` and `:ImageCacheClear` to inspect/reload/reuse it.
The matching [LaTeX example](math.tex) also contains an excluded comment and verbatim block.
