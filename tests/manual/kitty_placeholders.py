"""Opt-in native Kitty screenshot acceptance; creates and closes its own OS window."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[2]
kitty = os.environ.get("IMAGE_TOOLS_KITTY", shutil.which("kitty") or "kitty")
kitten = os.environ.get("IMAGE_TOOLS_KITTEN", shutil.which("kitten") or "kitten")
with tempfile.TemporaryDirectory(prefix="image-tools-native-kitty-") as directory:
    tmp = Path(directory).resolve()
    socket = "unix:" + str(tmp / "kitty.sock")
    subprocess.run(["magick", "-size", "400x240", "xc:white", str(tmp / "white.png")], check=True)
    env = dict(os.environ, IMAGE_TOOLS_ROOT=str(root), IMAGE_TOOLS_TEST_TMP=str(tmp),
               XDG_CACHE_HOME=str(tmp / "cache"), XDG_STATE_HOME=str(tmp / "state"), NVIM_LOG_FILE=str(tmp / "nvim.log"))
    for name in ("TMUX", "ZELLIJ", "SSH_CONNECTION", "SSH_TTY"):
        env.pop(name, None)
    command = [kitty, "--config", "NONE", "--override", "allow_remote_control=yes", "--override",
               "remember_window_size=no", "--override", "initial_window_width=1100", "--override",
               "initial_window_height=650", "--override", "window_padding_width=0", "--listen-on", socket,
               "--title", "image-tools native placeholder test", "nvim", "-u", "NONE", "-i", "NONE", "--noplugin",
               "-c", "luafile " + str(root / "tests/manual/kitty_placeholders.lua")]
    process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def remote(*args):
        return subprocess.run([kitten, "@", "--to", socket, *args], check=True, capture_output=True, timeout=10)
    def state(phase):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            error = tmp / "error.txt"
            if error.exists():
                raise AssertionError(error.read_text())
            try:
                value = json.loads((tmp / "state.json").read_text())
                if value["phase"] == phase:
                    return value
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.05)
        raise AssertionError("Native Kitty state timed out")
    def screenshot(phase, value):
        path = tmp / ("phase-" + str(phase) + ".png")
        remote("screenshot", str(path))
        artifacts = os.environ.get("IMAGE_TOOLS_KITTY_ARTIFACTS")
        if artifacts:
            destination = Path(artifacts)
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination / path.name)
            (destination / ("phase-" + str(phase) + ".json")).write_text(json.dumps(value))
        # Analyze solid white components in the actual screenshot. Terminal
        # padding/backing scale need not match Neovim's fallback cell metrics.
        components = subprocess.check_output(["magick", str(path), "-alpha", "off", "-colorspace", "Gray",
            "-threshold", "98%", "-define", "connected-components:verbose=true", "-connected-components", "4", "null:"], text=True)
        rectangles = []
        for line in components.splitlines():
            match = re.match(r"\s*\d+:\s+(\d+)x(\d+)\+(\d+)\+(\d+)\s+\S+\s+(\S+)\s+gray\(255\)", line)
            if match:
                width, height, x, y = map(int, match.groups()[:4])
                area = float(match[5])
                if width >= 100 and height >= 50 and 1.6 < width / height < 1.72 and area / (width * height) > 0.999:
                    rectangles.append((x, y, width, height))
        assert len(rectangles) == len(value["rects"]), ("Visible lines or missing/incorrect image", str(path), components, value)

    try:
        initial = state(1)
        assert len(initial["rects"]) == 2 and initial["rects"][0]["id"] != initial["rects"][1]["id"]
        assert initial["cache"]["uploads"] == 2
        screenshot(1, initial)
        remote("send-key", "F6")
        resized = state(2)
        assert resized["cache"]["uploads"] == 2
        screenshot(2, resized)
        remote("send-key", "F7")
        remaining = state(3)
        assert len(remaining["rects"]) == 1 and remaining["cache"]["placements"] == 1
        screenshot(3, remaining)
        remote("send-key", "F8")
        closed = state(4)
        assert not closed["rects"] and closed["cache"]["images"] == 0
        screenshot(4, closed)
        print("Native Kitty screenshots: no underline artifacts; independent sizes, resize reuse and cleanup passed")
    finally:
        try:
            remote("close-window")
        except (subprocess.SubprocessError, OSError):
            pass
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=3)
