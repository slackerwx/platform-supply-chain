"""A stdlib-only HTTP service.

It exists to be built into a container image, so the pipeline has something real to sign,
describe (SBOM) and attest. Keeping it dependency-free keeps its SBOM short enough to read
by hand in the learning exercises.
"""

from __future__ import annotations

import json
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from hello import __version__

DEFAULT_PORT = 8080


class HelloHandler(BaseHTTPRequestHandler):
    """Answers ``/healthz`` and ``/`` with JSON; anything else is a 404."""

    server_version = "hello-supply-chain"
    sys_version = ""

    def do_GET(self) -> None:  # noqa: N802 — name imposed by BaseHTTPRequestHandler
        if self.path == "/healthz":
            self._respond(HTTPStatus.OK, {"status": "ok"})
        elif self.path == "/":
            self._respond(HTTPStatus.OK, {"app": "hello-supply-chain", "version": __version__})
        else:
            self._respond(HTTPStatus.NOT_FOUND, {"error": "not found", "path": self.path})

    def _respond(self, status: HTTPStatus, payload: dict[str, str]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        """Log to stdout so `kubectl logs` shows requests without stderr interleaving."""
        print(f'{self.address_string()} "{format % args}"', flush=True)


def build_server(port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    """Bind without serving. Port 0 asks the kernel for an ephemeral port (used by the tests)."""
    return ThreadingHTTPServer(("", port), HelloHandler)


def serve(port: int = DEFAULT_PORT) -> None:
    server = build_server(port)
    print(f"hello-supply-chain {__version__} listening on :{server.server_port}", flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    serve()
