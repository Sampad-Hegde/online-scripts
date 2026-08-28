"""API + script assembly tests.  run with: make test-py"""

from __future__ import annotations

import importlib
import os
import re
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
EXPECTED = {"sysinfo", "storage", "cpu-load", "gpu-load", "all"}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.delenv("AUTH_TOKEN", raising=False)
    monkeypatch.delenv("PUBLIC_BASE_URL", raising=False)
    import app.main as main

    importlib.reload(main)
    return TestClient(main.app)


@pytest.fixture
def auth_client(monkeypatch):
    monkeypatch.setenv("AUTH_TOKEN", "s3cret")
    import app.main as main

    importlib.reload(main)
    yield TestClient(main.app)
    monkeypatch.delenv("AUTH_TOKEN", raising=False)
    importlib.reload(main)


# ------------------------------------------------------------------ basics
def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert EXPECTED.issubset(set(body["scripts"]))


def test_index_plain_for_curl(client):
    r = client.get("/", headers={"user-agent": "curl/8.4.0"})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert "sysinfo.sh" in r.text
    assert "curl -fsSL" in r.text


def test_index_html_for_browser(client):
    r = client.get("/", headers={"accept": "text/html", "user-agent": "Mozilla/5.0"})
    assert r.headers["content-type"].startswith("text/html")
    assert "<table>" in r.text


def test_list_scripts(client):
    r = client.get("/scripts")
    assert r.status_code == 200
    body = r.json()
    names = {s["name"] for s in body["scripts"]}
    assert EXPECTED.issubset(names)
    assert body["count"] == len(body["scripts"])
    for s in body["scripts"]:
        assert s["url"].endswith(f"/{s['name']}.sh")
        assert s["run"].startswith("curl -fsSL")
        assert s["description"]


# ----------------------------------------------------------------- scripts
@pytest.mark.parametrize("name", sorted(EXPECTED))
def test_script_is_served_and_assembled(client, name):
    r = client.get(f"/{name}.sh")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert r.headers["cache-control"] == "no-store, max-age=0"
    body = r.text
    # library was inlined, placeholders substituted
    assert "#@include" not in body
    assert "@@BASE_URL@@" not in body
    assert "@@VERSION@@" not in body
    assert "t_end()" in body, "library not injected"
    assert body.startswith("#!/bin/sh")
    assert 'OS_BASE_URL="http://testserver"' in body


def test_bare_name_also_works(client):
    assert client.get("/sysinfo").text == client.get("/sysinfo.sh").text


def test_library_is_not_served(client):
    assert client.get("/_lib.sh").status_code == 404
    assert client.get("/_lib").status_code == 404


def test_unknown_script_404(client):
    r = client.get("/nope.sh")
    assert r.status_code == 404
    assert "unknown script" in r.json()["detail"]


@pytest.mark.parametrize(
    "path", ["/..%2f..%2fetc%2fpasswd", "/../etc/passwd", "/etc/passwd", "/sysinfo.sh.bak"]
)
def test_traversal_and_junk_rejected(client, path):
    assert client.get(path).status_code in (404, 400, 307)


def test_query_params_become_shell_defaults(client):
    body = client.get("/cpu-load.sh?duration=123&threads=4").text
    assert "DURATION=${DURATION:-123}" in body
    assert "THREADS=${THREADS:-4}" in body


def test_unknown_or_unsafe_params_ignored(client):
    body = client.get("/cpu-load.sh?evil=%3Brm%20-rf%20%2F&duration=9%3Bid").text
    prelude = [l for l in body.splitlines() if l.startswith(("DURATION=$", "EVIL", "evil"))]
    # the shell default in the script body stays, nothing is injected from the URL
    assert prelude == ["DURATION=${DURATION:-60}"], prelude
    assert "9;id" not in body
    assert ";rm -rf /" not in body


def test_base_url_follows_forwarded_headers(client):
    body = client.get(
        "/sysinfo.sh",
        headers={"x-forwarded-proto": "https", "x-forwarded-host": "hw.example.com"},
    ).text
    assert 'OS_BASE_URL="https://hw.example.com"' in body


def test_public_base_url_override(monkeypatch):
    monkeypatch.setenv("PUBLIC_BASE_URL", "https://fixed.example.com/")
    import app.main as main

    importlib.reload(main)
    body = TestClient(main.app).get("/sysinfo.sh").text
    assert 'OS_BASE_URL="https://fixed.example.com"' in body
    monkeypatch.delenv("PUBLIC_BASE_URL")
    importlib.reload(main)


# -------------------------------------------------------------------- auth
def test_auth_required_when_token_set(auth_client):
    assert auth_client.get("/sysinfo.sh").status_code == 401
    assert auth_client.get("/scripts").status_code == 401
    assert auth_client.get("/healthz").status_code == 200  # for the healthcheck


def test_auth_accepts_query_header_and_bearer(auth_client):
    assert auth_client.get("/sysinfo.sh?t=s3cret").status_code == 200
    assert (
        auth_client.get(
            "/sysinfo.sh", headers={"authorization": "Bearer s3cret"}
        ).status_code
        == 200
    )
    assert (
        auth_client.get("/sysinfo.sh", headers={"x-auth-token": "s3cret"}).status_code
        == 200
    )
    assert auth_client.get("/sysinfo.sh?t=wrong").status_code == 401


def test_token_is_propagated_into_the_script(auth_client):
    body = auth_client.get("/all.sh?t=s3cret").text
    assert 'OS_TOKEN_Q="?t=s3cret"' in body


# ------------------------------------------------------------- shell hygiene
def test_every_script_has_metadata():
    for path in SCRIPTS.glob("*.sh"):
        if path.name.startswith("_"):
            continue
        text = path.read_text()
        assert re.search(r"^#@name\s+\S+", text, re.M), f"{path.name} lacks #@name"
        assert re.search(r"^#@description\s+\S+", text, re.M), f"{path.name} lacks #@description"
        assert "#@include _lib.sh" in text, f"{path.name} does not include the library"


@pytest.mark.parametrize(
    "name", sorted(p.name for p in SCRIPTS.glob("*.sh"))
)
def test_scripts_pass_sh_syntax_check(name):
    proc = subprocess.run(
        ["sh", "-n", str(SCRIPTS / name)], capture_output=True, text=True
    )
    assert proc.returncode == 0, proc.stderr


def test_assembled_script_passes_syntax_check(client, tmp_path):
    for name in sorted(EXPECTED):
        f = tmp_path / f"{name}.sh"
        f.write_text(client.get(f"/{name}.sh?duration=30").text)
        proc = subprocess.run(["sh", "-n", str(f)], capture_output=True, text=True)
        assert proc.returncode == 0, f"{name}: {proc.stderr}"


def test_no_placeholder_left_in_repo_scripts():
    lib = (SCRIPTS / "_lib.sh").read_text()
    assert "@@BASE_URL@@" in lib and "@@VERSION@@" in lib
    for path in SCRIPTS.glob("*.sh"):
        if path.name.startswith("_"):
            continue
        assert "@@" not in path.read_text(), f"{path.name} should not use placeholders"


def test_library_selftest_passes():
    """scripts/_lib.sh self test - table layout, statistics, parsers."""
    proc = subprocess.run(
        ["sh", str(ROOT / "tests" / "lib_selftest.sh"), str(SCRIPTS / "_lib.sh")],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "all library self tests passed" in proc.stdout


def test_urls_with_a_token_are_quoted_for_the_shell(auth_client):
    """?t=... must be quoted or zsh/csh will try to glob the '?'."""
    text = auth_client.get("/?t=s3cret", headers={"user-agent": "curl/8"}).text
    assert "curl -fsSL 'http://testserver/sysinfo.sh?t=s3cret'" in text
    run = auth_client.get("/scripts?t=s3cret").json()["scripts"][0]["run"]
    assert run.startswith("curl -fsSL '")


def test_urls_without_a_token_are_bare(client):
    text = client.get("/", headers={"user-agent": "curl/8"}).text
    assert "curl -fsSL http://testserver/sysinfo.sh | sudo sh" in text


def test_cols_can_be_set_from_the_url(client):
    body = client.get("/sysinfo.sh?cols=200").text
    assert "COLS=${COLS:-200}" in body


def test_table_width_falls_back_when_the_terminal_is_unknown():
    """No tput/stty and no COLUMNS must still give a roomy default."""
    lib = (SCRIPTS / "_lib.sh").read_text()
    assert "_w=120" in lib, "the no-terminal fallback should be wide"
    assert "stty size" in lib and "/dev/tty" in lib
