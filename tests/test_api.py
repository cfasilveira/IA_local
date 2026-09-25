"""Smoke tests da mini-api (roda com o venv do projeto).

Uso:
    ../mini-api/venv/bin/python -m pytest tests/test_api.py -v
    (a partir da raiz do repo; sys.path aponta para mini-api/)
"""

import sys
from pathlib import Path

MINI_API = Path(__file__).resolve().parents[1] / "mini-api"
sys.path.insert(0, str(MINI_API))

from fastapi.testclient import TestClient

from main import app  # noqa: E402


client = TestClient(app)


def test_root():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert body["message"] == "Hello World"
    assert "environment" in body


def test_items_empty():
    r = client.get("/items/")
    assert r.status_code == 200
    assert r.json() == []


def test_items_health():
    r = client.get("/items/health")
    assert r.status_code == 200
    assert r.json() == {"status": "UP"}
