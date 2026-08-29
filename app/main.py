"""online-script - serve hardware test shell scripts over HTTP.

    curl -fsSL http://host:8080/sysinfo.sh | sudo sh
"""

from __future__ import annotations

import logging
import os
import secrets
from typing import Dict, Optional

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse, PlainTextResponse, Response

from .registry import ALLOWED_PARAMS, VERSION, Registry, ScriptError

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=LOG_LEVEL, format="%(asctime)s %(levelname)-7s %(name)s  %(message)s"
)
log = logging.getLogger("online-script")

AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "").strip()
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "").strip().rstrip("/")

registry = Registry()

app = FastAPI(
    title="online-script",
    version=VERSION,
    description="Shell scripts for quick hardware inspection of second-hand PCs.",
    docs_url="/docs",
    redoc_url=None,
)

SH_HEADERS = {
    "Cache-Control": "no-store, max-age=0",
    "X-Content-Type-Options": "nosniff",
}


# ---------------------------------------------------------------- helpers
def base_url(request: Request) -> str:
    """Public URL of this service, honouring reverse proxy headers."""
    if PUBLIC_BASE_URL:
        return PUBLIC_BASE_URL
    proto = request.headers.get("x-forwarded-proto", request.url.scheme).split(",")[0]
    host = request.headers.get("x-forwarded-host") or request.headers.get("host")
    if not host:
        host = f"{request.url.hostname}:{request.url.port or 80}"
    return f"{proto}://{host.strip()}".rstrip("/")


def check_auth(request: Request, token: Optional[str]) -> None:
    if not AUTH_TOKEN:
        return
    supplied = token or ""
    if not supplied:
        auth = request.headers.get("authorization", "")
        if auth.lower().startswith("bearer "):
            supplied = auth[7:].strip()
    if not supplied:
        supplied = request.headers.get("x-auth-token", "")
    if not secrets.compare_digest(supplied, AUTH_TOKEN):
        raise HTTPException(status_code=401, detail="missing or bad token")


def client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
    return request.client.host if request.client else "-"


def script_params(request: Request) -> Dict[str, str]:
    return {
        k: v
        for k, v in request.query_params.items()
        if k.lower() in ALLOWED_PARAMS and v != ""
    }


def token_for_links(token: Optional[str]) -> Optional[str]:
    return token if (AUTH_TOKEN and token) else None


# ----------------------------------------------------------------- routes
@app.get("/healthz", include_in_schema=False)
def healthz() -> JSONResponse:
    return JSONResponse({"ok": True, "version": VERSION, "scripts": registry.names()})


@app.get("/scripts", summary="List every available script")
def list_scripts(request: Request, t: Optional[str] = Query(default=None)) -> JSONResponse:
    check_auth(request, t)
    root = base_url(request)
    suffix = f"?t={t}" if token_for_links(t) else ""
    items = [
        {
            "name": s.name,
            "file": s.filename,
            "title": s.title,
            "description": s.description,
            "root": s.root,
            "params": s.params,
            "url": f"{root}/{s.filename}{suffix}",
            "run": f"curl -fsSL {show_url(root, '/' + s.filename, suffix)} | "
            + ("sudo sh" if s.root in ("required", "recommended") else "sh"),
        }
        for s in registry.all()
    ]
    return JSONResponse({"version": VERSION, "count": len(items), "scripts": items})


def show_url(root: str, path: str, suffix: str) -> str:
    """URL for pasting into a shell; quoted when it has a query string."""
    url = f"{root}{path}{suffix}"
    return f"'{url}'" if suffix else url


def index_text(root: str, suffix: str) -> str:
    scripts = registry.all()
    width = max((len(s.filename) for s in scripts), default=12)
    lines = [
        "",
        "  online-script  -  quick hardware inspection over curl",
        f"  version {VERSION}",
        "",
        "  USAGE",
        f"    curl -fsSL {show_url(root, '/sysinfo.sh', suffix)} | sudo sh",
        "",
        "  SCRIPTS",
    ]
    for s in scripts:
        need = " (root)" if s.root == "required" else ""
        lines.append(f"    {s.filename:<{width}}  {s.description}{need}")
    lines += [
        "",
        "  OPTIONS  (environment variables, or ?name=value on the URL)",
        "    DURATION=300   load test length in seconds",
        "    THREADS=4      cpu-load worker threads",
        "    INSTANCES=2    parallel GPU load processes (nvidia-gpu)",
        "    LOAD_CMD=...   your own GPU burn command, e.g. 'gpu_burn 600' (env only)",
        "    VRAM_TEST=0    skip the nvidia-gpu VRAM pattern test",
        "    SPEED=0        skip the storage read benchmark",
        "    SPD=1          also decode the memory SPD EEPROM (CAS latency)",
        "    LOAD=1         all.sh: include the load tests",
        "    COLS=160       force the table width (default: your terminal)",
        "    PLAIN=1        ASCII tables, no colour",
        "    NO_INSTALL=1   never install packages",
        "",
        "  EXAMPLES",
        f"    curl -fsSL {show_url(root, '/storage.sh', suffix)} | sudo sh",
        f"    curl -fsSL '{root}/cpu-load.sh{suffix or '?'}"
        + ("&" if suffix else "")
        + "duration=600' | sudo sh",
        f"    curl -fsSL {show_url(root, '/cpu-load.sh', suffix)} | sudo DURATION=600 THREADS=8 sh",
        f"    curl -fsSL {show_url(root, '/scripts', suffix)}        # JSON list",
        "",
        "  Assumes a Debian/Ubuntu or Alpine live system with curl or wget; other",
        "  distro families (fedora, arch, suse) are handled on a best-effort basis.",
        "  Missing tools are installed automatically when running as root.",
        "",
    ]
    return "\n".join(lines)


def index_html(root: str, suffix: str) -> str:
    rows = []
    for s in registry.all():
        cmd = f"curl -fsSL {show_url(root, '/' + s.filename, suffix)} | " + (
            "sudo sh" if s.root in ("required", "recommended") else "sh"
        )
        rows.append(
            f"<tr><td><a href='{root}/{s.filename}{suffix}'>{s.filename}</a></td>"
            f"<td>{s.description}</td><td>{s.root}</td>"
            f"<td><code>{cmd}</code></td></tr>"
        )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>online-script</title>
<style>
 :root {{ color-scheme: dark light; }}
 body {{ font: 15px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
        margin: 2rem auto; max-width: 60rem; padding: 0 1rem; }}
 h1 {{ font-size: 1.4rem; margin-bottom: .2rem; }}
 p.sub {{ opacity: .7; margin-top: 0; }}
 table {{ border-collapse: collapse; width: 100%; margin: 1.5rem 0; }}
 th, td {{ text-align: left; padding: .5rem .6rem; border-bottom: 1px solid #8884;
          vertical-align: top; }}
 code {{ background: #8882; padding: .1rem .35rem; border-radius: 4px;
        white-space: pre-wrap; word-break: break-all; }}
 ul {{ opacity: .85; }}
</style></head><body>
<h1>online-script</h1>
<p class="sub">quick hardware inspection over <code>curl</code> &middot; v{VERSION}</p>
<table>
<tr><th>script</th><th>what it reports</th><th>privileges</th><th>run it</th></tr>
{''.join(rows)}
</table>
<h2>Options</h2>
<ul>
 <li><code>DURATION</code> load test seconds &middot; <code>THREADS</code> cpu workers
     &middot; <code>INSTANCES</code> parallel GPU load processes</li>
 <li><code>SPEED=0</code> skip storage read benchmark &middot; <code>SPD=1</code> read memory SPD (CAS latency)</li>
 <li><code>LOAD=1</code> make <code>all.sh</code> include the load tests</li>
 <li><code>COLS=160</code> force table width &middot; <code>PLAIN=1</code> ASCII only
     &middot; <code>NO_INSTALL=1</code> never install packages</li>
 <li>same names work as URL query params: <code>?duration=600</code></li>
</ul>
<p><a href="{root}/scripts{suffix}">JSON script list</a> &middot;
   <a href="{root}/docs">API docs</a></p>
</body></html>
"""


@app.get("/", summary="Usage and script list")
def index(request: Request, t: Optional[str] = Query(default=None)) -> Response:
    check_auth(request, t)
    root = base_url(request)
    suffix = f"?t={t}" if token_for_links(t) else ""
    accept = request.headers.get("accept", "")
    agent = request.headers.get("user-agent", "").lower()
    wants_html = "text/html" in accept and not any(
        a in agent for a in ("curl", "wget", "httpie", "fetch/")
    )
    if wants_html:
        return Response(content=index_html(root, suffix), media_type="text/html")
    return PlainTextResponse(index_text(root, suffix))


@app.get("/{name}", summary="Fetch a script")
def get_script(
    request: Request, name: str, t: Optional[str] = Query(default=None)
) -> Response:
    check_auth(request, t)
    if name in ("favicon.ico", "robots.txt"):
        raise HTTPException(status_code=404, detail="not found")
    stem = name[:-3] if name.endswith(".sh") else name
    try:
        body = registry.render(
            stem,
            base_url=base_url(request),
            token=token_for_links(t),
            params=script_params(request),
        )
    except ScriptError:
        raise HTTPException(
            status_code=404,
            detail=f"unknown script {stem!r}; available: {', '.join(registry.names())}",
        ) from None
    log.info("serve %s -> %s (%d bytes)", stem, client_ip(request), len(body))
    return PlainTextResponse(body, headers=SH_HEADERS)
