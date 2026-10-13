"""Exercise the real Neovim TUI in a PTY and inspect its graphics byte stream.

This is a transport/lifecycle test, not a physical Kitty screenshot test.
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
with tempfile.TemporaryDirectory(prefix="image-tools-tui-") as directory:
    temporary = Path(directory).resolve()
    shutil.copyfile(root / "tests/fixture.png", temporary / "中文 image (1).png")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 1000, 640))
    env = os.environ.copy()
    env.update(
        TERM="xterm-kitty",
        KITTY_WINDOW_ID="image-tools-pty-test",
        IMAGE_TOOLS_ROOT=str(root),
        IMAGE_TOOLS_TEST_TMP=str(temporary),
        XDG_CACHE_HOME=str(temporary / "cache"),
        XDG_STATE_HOME=str(temporary / "state"),
        NVIM_LOG_FILE=str(temporary / "nvim.log"),
    )
    env.pop("TMUX", None)
    env.pop("ZELLIJ", None)
    process = subprocess.Popen(
        ["nvim", "-u", "NONE", "-i", "NONE", "--noplugin", "-c", "luafile " + str(root / "tests/tui.lua")],
        stdin=slave, stdout=slave, stderr=slave, env=env, start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
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
            elif process.poll() is not None:
                break
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            raise AssertionError("TUI test timed out: " + repr(bytes(output[-3000:])))
        error = temporary / "error.txt"
        assert process.returncode == 0, error.read_text() if error.exists() else "TUI process failed"
        result = json.loads((temporary / "result.json").read_text())
        assert result["geometry"] == [16, 5], result
        assert result["position"] == "bottom_right", result
        assert result["same_line"] and result["image_line_transition"], result
        assert result["lifecycle"], result
        commands = []
        for match in re.finditer(rb"\x1b_G([^;\x1b]+)(?:;([^\x1b]*))?\x1b\\", output):
            fields = dict(part.split(b"=", 1) for part in match[1].split(b","))
            commands.append((fields, match[2]))
        uploads = [(fields, data) for fields, data in commands if fields.get(b"a") == b"t"]
        assert len(uploads) == 3, [(fields, len(data or b"")) for fields, data in commands]
        fixture = (root / "tests/fixture.png").read_bytes()
        for fields, data in uploads:
            assert base64.b64decode(data) == fixture
            identifier = int(fields[b"i"])
            color = b"38;2;%d;%d;%d" % (identifier >> 16, (identifier >> 8) & 255, identifier & 255)
            assert color in output, "Neovim TUI did not emit the image id as true color"
            assert any(f.get(b"a") == b"p" and f.get(b"U") == b"1" and f.get(b"i") == fields[b"i"] for f, _ in commands)
            assert any(f.get(b"a") == b"d" and f.get(b"d") == b"I" and f.get(b"i") == fields[b"i"] for f, _ in commands)
        assert chr(0x10EEEE).encode() in output, "Neovim TUI did not emit Unicode placeholders"
        assert not any(f.get(b"d") in (b"A", b"a") for f, _ in commands)
        print("image-tools TUI: persistent line preview, Insert mode, line transitions, protocol and cleanup passed")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
        os.close(master)
