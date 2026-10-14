"""Run the real Neovim TUI against a deterministic Kitty-protocol responder.

Checks byte streams, replies, caching and lifecycle; does not claim a physical
Kitty window rendering or an end-to-end performance benchmark.
"""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
pattern = re.compile(rb"\x1b_G([^;\x1b]+)(?:;([^\x1b]*))?\x1b\\")
sgr_pattern = re.compile(rb"\x1b\[([0-9;:]*)m")


def has_rgb_color(output, channel, value):
    """Match an exact RGB SGR parameter, independent of terminfo separators."""
    red, green, blue = value >> 16, (value >> 8) & 255, value & 255
    # Semicolon form: 38;2;R;G;B. Colon form: 38:2:R:G:B, optionally
    # including an empty/default color-space field (38:2::R:G:B).
    color = re.compile(
        rb"(?:^|;)%d(?:;2;%d;%d;%d|:2:(?:[0-9]*:)?%d:%d:%d)(?:;|$)"
        % (channel, red, green, blue, red, green, blue)
    )
    return any(color.search(match[1]) for match in sgr_pattern.finditer(output))


def test_rgb_colors():
    # Keep both terminfo encodings covered even when the host emits only one.
    for channel in (38, 58):
        for parameters in (
            b"%d;2;12;34;56", b"%d:2:12:34:56",
            b"%d:2::12:34:56", b"%d:2:0:12:34:56",
        ):
            output = b"\x1b[0;" + parameters % channel + b";4m"
            assert has_rgb_color(output, channel, 0x0C2238), output
            assert not has_rgb_color(output, channel, 0x0C2239), output
        for output in (b"38;2;12;34;56", b"\x1b[38;5;56m", b"\x1b[38;2;12;34;560m"):
            assert not has_rgb_color(output, channel, 0x0C2238), output
    assert not has_rgb_color(b"\x1b[48;2;12;34;56m", 38, 0x0C2238)
    print("image-tools TUI: RGB SGR matching regressions passed")


def run_case(mode, reject_file=False, evict=False, picker=False, buffer=False, latex=False, cursor=False):
    with tempfile.TemporaryDirectory(prefix="image-tools-tui-") as directory:
        temporary = Path(directory).resolve()
        fixture = (root / "tests/fixture.png").read_bytes()
        shutil.copyfile(root / "tests/fixture.png", temporary / "中文 image (1).png")
        if cursor:
            shutil.copyfile(root / "tests/fixture.png", temporary / "second.png")
        if buffer:
            shutil.copyfile(root / "tests/fixture.pdf", temporary / "pages.pdf")
        if latex:
            shutil.copyfile(root / "tests/fixture.pdf", temporary / "SC_multiplier_accurate.pdf")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 1000, 640))
        env = os.environ.copy()
        env.update(
            TERM="xterm-kitty", KITTY_WINDOW_ID="image-tools-pty-test",
            IMAGE_TOOLS_ROOT=str(root), IMAGE_TOOLS_TEST_TMP=str(temporary),
            IMAGE_TOOLS_TEST_TRANSPORT=mode,
            XDG_CACHE_HOME=str(temporary / "cache"), XDG_STATE_HOME=str(temporary / "state"),
            NVIM_LOG_FILE=str(temporary / "nvim.log"),
        )
        for name in ("TMUX", "ZELLIJ", "SSH_CONNECTION", "SSH_TTY"):
            env.pop(name, None)
        command = ["nvim", "-u", "NONE", "-i", "NONE", "--noplugin", "-c", "luafile " + str(root / ("tests/tui_picker.lua" if picker else "tests/tui.lua"))]
        if cursor:
            command = ["nvim", "-u", "NONE", "-i", "NONE", "--noplugin", "-c", "luafile " + str(root / "tests/tui_cursor.lua")]
        if latex:
            command = ["nvim", "-u", "NONE", "-i", "NONE", "--noplugin", "-c", "luafile " + str(root / "tests/tui_latex.lua")]
        if buffer:
            command = ["nvim", "-u", str(root / "tests/tui_buffer.lua"), "-i", "NONE", "--noplugin", str(temporary / "中文 image (1).png")]
        process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True)
        os.close(slave)
        output, commands, uploads, resident = bytearray(), [], [], set()
        offset, pending, rejected, evicted = 0, None, False, False
        underline_query_answered = False

        def reply(identifier, message, quiet, placement=None):
            if quiet != b"2":
                os.write(master, b"\x1b_Gi=" + identifier + (b",p=" + placement if placement else b"") + b";" + message + b"\x1b\\")

        def handle(fields, payload):
            nonlocal pending, rejected, evicted
            commands.append((fields, payload))
            action, identifier, quiet = fields.get(b"a"), fields.get(b"i"), fields.get(b"q")
            if action == b"t":
                if fields[b"t"] == b"f":
                    uploads.append((fields, payload))
                    if reject_file and not rejected:
                        rejected = True
                        reply(identifier, b"EBADF:Failed to read image file", quiet)
                    else:
                        path = Path(base64.b64decode(payload).decode())
                        data = path.read_bytes()
                        if buffer or latex:
                            assert data[:8] == b"\x89PNG\r\n\x1a\n", "buffer upload is not a PNG"
                        else:
                            assert data == fixture, "file transport did not reference the PNG fixture"
                        resident.add(identifier)
                        reply(identifier, b"OK", quiet)
                else:
                    pending = [fields, [payload]]
                    if fields.get(b"m") == b"0":
                        finish_upload()
            elif pending is not None and b"m" in fields:
                pending[1].append(payload)
                if fields[b"m"] == b"0":
                    finish_upload()
            elif action == b"p":
                reply(identifier, b"OK" if identifier in resident else b"ENOENT:image not found", quiet, fields.get(b"p"))
            elif action == b"d":
                if fields[b"d"] == b"I":
                    resident.discard(identifier)
                elif evict and not evicted:
                    resident.discard(identifier)  # Simulate Kitty's quota eviction after hiding.
                    evicted = True

        def finish_upload():
            nonlocal pending
            fields, chunks = pending
            data = b"".join(chunks)
            assert base64.b64decode(data) == fixture, "direct transport changed PNG bytes"
            uploads.append((fields, data))
            resident.add(fields[b"i"])
            reply(fields[b"i"], b"OK", fields.get(b"q"))
            pending = None

        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    output.extend(data)
                    # When terminfo lacks extended underline capabilities,
                    # Neovim probes them with DECRQSS. Simulate Kitty's reply.
                    # A complete Kitty terminfo enables SGR 58 without a probe;
                    # assertions below check emitted colors in either case.
                    if not underline_query_answered and b"\x1bP$qm\x1b\\" in output:
                        os.write(master, b"\x1bP1$r0;4:3m\x1b\\")
                        underline_query_answered = True
                    for match in pattern.finditer(output, offset):
                        offset = match.end()
                        fields = dict(part.split(b"=", 1) for part in match[1].split(b","))
                        handle(fields, match[2])
                elif process.poll() is not None:
                    break
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                raise AssertionError("TUI test timed out: " + repr(bytes(output[-1000:])))
            error = temporary / "error.txt"
            if process.returncode != 0:
                log = temporary / "responses.log"
                raise AssertionError((error.read_text() if error.exists() else repr(bytes(output[-1000:])))
                    + "\ncommands: " + repr([f for f, _ in commands])
                    + "\nresponses: " + (log.read_text() if log.exists() else "none"))
            result = json.loads((temporary / "result.json").read_text())
            if cursor:
                assert result["cursor"] and result["lifecycle"], result
            elif latex:
                assert result["latex"] and result["range_preserved"] and result["range_lifecycle"], result
            elif buffer:
                assert result["buffer"] and result["lifecycle"] and result["statusline"] and result["shared"], result
                for placement in result["shared_placements"]:
                    observed = [match[1] for match in sgr_pattern.finditer(output) if b"58" in match[1]]
                    assert has_rgb_color(output, 58, placement), (
                        "TUI did not emit independent placement as underline color: "
                        + f"placement={placement}, query_answered={underline_query_answered}, "
                        + f"observed SGR={observed[-20:]!r}"
                    )
            elif picker:
                assert result["picker"] and result["inserted"], result
            else:
                assert result["geometry"] == [16, 5] and result["position"] == "bottom_right", result
                assert result["same_line"] and result["image_line_transition"] and result["lifecycle"], result
            assert len(uploads) == (3 if buffer else 2 if cursor or reject_file or evict else 1), uploads
            assert result["cache"]["uploads"] == (3 if buffer else len(uploads)), result
            if picker or buffer or latex:
                assert result["cache"]["hits"] >= 1, result
            else:
                assert result["cache"]["hits"] == (1 if evict else 2), result
            assert len(resident) == 0, "exit must release all retained terminal images"
            assert any(f.get(b"d") == b"i" for f, _ in commands), "close must hide without freeing"
            assert any(f.get(b"d") == b"I" for f, _ in commands), "exit must free cached data"
            assert not any(f.get(b"d") in (b"A", b"a") for f, _ in commands)
            successful = uploads[1:] if reject_file else uploads
            for fields, _ in successful:
                identifier = int(fields[b"i"])
                observed = [match[1] for match in sgr_pattern.finditer(output) if b"38" in match[1]]
                assert has_rgb_color(output, 38, identifier), (
                    "TUI did not emit the image id as true color: "
                    + f"id={identifier}, rgb={(identifier >> 16, (identifier >> 8) & 255, identifier & 255)}, "
                    + f"observed SGR={observed[-20:]!r}"
                )
                assert any(f.get(b"a") == b"p" and f.get(b"U") == b"1" and f.get(b"i") == fields[b"i"] for f, _ in commands)
            assert chr(0x10EEEE).encode() in output
            if reject_file:
                assert uploads[0][0][b"t"] == b"f" and uploads[1][0][b"t"] == b"d"
            else:
                assert all(f[b"t"] == (b"d" if mode == "direct" else b"f") for f, _ in uploads)
            label = ("cursor " if cursor else "latex " if latex else "buffer " if buffer else "picker " if picker else "") + mode + (" fallback" if reject_file else " eviction" if evict else "")
            print("image-tools TUI: " + label + ", replies, cache reuse, line lifecycle and cleanup passed")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)


test_rgb_colors()

run_case("auto")
run_case("direct")
run_case("auto", reject_file=True)
run_case("auto", evict=True)

if os.environ.get("IMAGE_TOOLS_SNACKS_ROOT"):
    run_case("auto", picker=True)

run_case("auto", buffer=True)

run_case("auto", latex=True)

run_case("auto", cursor=True)
