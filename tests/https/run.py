"""Run HTTPS workflows against a local TLS fixture with real curl and Neovim.

No external site is contacted. The temporary certificate is trusted only by the
test downloader wrapper; TLS verification stays enabled.
"""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[2]


def main():
    if not all(shutil.which(tool) for tool in ("openssl", "curl", "nvim", "magick")):
        print("[skip] HTTPS integration requires openssl, curl, nvim and magick")
        return
    with tempfile.TemporaryDirectory(prefix="image-tools-https-test-") as directory:
        temporary = Path(directory).resolve()
        certificate, key = temporary / "cert.pem", temporary / "key.pem"
        configuration = temporary / "openssl.cnf"
        configuration.write_text("[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=localhost\n"
                                 "[v3]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
                                 "basicConstraints=CA:TRUE\nextendedKeyUsage=serverAuth\n")
        generated = subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(key), "-out", str(certificate), "-days", "1",
            "-config", str(configuration), "-extensions", "v3",
        ], capture_output=True, timeout=15)
        assert generated.returncode == 0, generated.stderr.decode()
        png = (root / "tests/fixtures/fixture.png").read_bytes()
        jpg_path = temporary / "fixture.jpg"
        subprocess.run(["magick", str(root / "tests/fixtures/fixture.png"), str(jpg_path)], check=True)
        jpg = jpg_path.read_bytes()
        counts = Counter()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                path = self.path.split("?", 1)[0]
                counts[path] += 1
                if path in ("/redirect", "/http-redirect", "/loop"):
                    location = {"/redirect": "/image.png", "/loop": "/loop",
                                "/http-redirect": "http://127.0.0.1/image.png"}[path]
                    self.send_response(302)
                    self.send_header("Location", location)
                    self.end_headers()
                    return
                if path == "/slow.png":
                    time.sleep(0.3)
                data = b"<html>not an image</html>" if path == "/invalid" else jpg if path == "/no-extension" else png
                if path == "/huge.png":
                    data = png + b"x" * 131072
                if path == "/broken.png":
                    data = png[:40]
                self.send_response(404 if path == "/missing" else 200)
                if path != "/huge.png":  # Also exercise the streaming limit without Content-Length.
                    self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        # Exec argv without shell interpolation; -q remains curl's first option.
        downloader = temporary / "curl-test"
        downloader.write_text("#!/usr/bin/env python3\nimport os,sys\nos.execv(" + repr(shutil.which("curl"))
                              + ", [" + repr(shutil.which("curl")) + ", '-q', '--cacert', "
                              + repr(str(certificate)) + "] + sys.argv[1:])\n")
        downloader.chmod(0o755)
        env = os.environ.copy()
        env.update(IMAGE_TOOLS_ROOT=str(root), IMAGE_TOOLS_TEST_TMP=str(temporary),
                   IMAGE_TOOLS_HTTPS_URL=f"https://127.0.0.1:{server.server_port}",
                   IMAGE_TOOLS_HTTPS_CURL=str(downloader),
                   XDG_CACHE_HOME=str(temporary / "cache"), XDG_STATE_HOME=str(temporary / "state"),
                   NVIM_LOG_FILE=str(temporary / "nvim.log"))
        try:
            subprocess.run(["nvim", "--headless", "-u", "NONE", "-i", "NONE", "--noplugin",
                            "-l", str(root / "tests/media/remote.lua")], env=env, check=True, timeout=60)
            assert counts["/shared.png"] == 1, counts
            assert counts["/image.png"] >= 2, counts  # Includes an explicit cache-bypassing reload.
            print("image-tools HTTPS: verified TLS, real curl, redirects, cache, streaming limits, preview and localization passed")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == "__main__":
    main()
