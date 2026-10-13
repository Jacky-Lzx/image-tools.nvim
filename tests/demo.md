# Image preview fixture

Move the cursor onto the image line, or run `:ImagePreview` on that line.
The fixture has four colored quadrants. The float should preserve its aspect
ratio, persist during horizontal movement, and disappear when you leave the
line or change buffers.

![Four colored quadrants](fixture.png)

After closing it, this text should be visible without any image residue.
