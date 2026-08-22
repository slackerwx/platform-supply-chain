"""The example is tiny but still tested: a build that ships an untested artifact signs a lie."""

from __future__ import annotations

import json
import threading
import urllib.error
import urllib.request
from collections.abc import Iterator
from typing import Any

import pytest

from hello import __version__
from hello.app import build_server


@pytest.fixture
def base_url() -> Iterator[str]:
    """Serve on an ephemeral port in a background thread, then shut it down cleanly."""
    server = build_server(0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def _get(url: str) -> tuple[int, dict[str, Any]]:
    with urllib.request.urlopen(url, timeout=5) as response:
        payload: dict[str, Any] = json.loads(response.read())
        return response.status, payload


def test_healthz_reports_ok(base_url: str) -> None:
    status, payload = _get(f"{base_url}/healthz")
    assert status == 200
    assert payload == {"status": "ok"}


def test_root_reports_the_running_version(base_url: str) -> None:
    status, payload = _get(f"{base_url}/")
    assert status == 200
    assert payload == {"app": "hello-supply-chain", "version": __version__}


def test_unknown_path_is_404(base_url: str) -> None:
    with pytest.raises(urllib.error.HTTPError) as excinfo:
        _get(f"{base_url}/nope")
    assert excinfo.value.code == 404
