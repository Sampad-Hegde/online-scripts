"""Loading, assembling and caching of the shell scripts we hand out."""

from __future__ import annotations

import os
import re
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

DEFAULT_SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
SCRIPTS_DIR = Path(os.environ.get("SCRIPTS_DIR", DEFAULT_SCRIPTS_DIR)).resolve()
VERSION = os.environ.get("APP_VERSION", "1.0.0")

# scripts starting with "_" are library fragments, not served on their own
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
INCLUDE_NAME_RE = re.compile(r"^[a-z0-9_][a-z0-9._-]*\.sh$")
INCLUDE_RE = re.compile(r"^[ \t]*#@include[ \t]+(\S+)[ \t]*$", re.MULTILINE)
META_RE = re.compile(r"^[ \t]*#@(name|title|description|root|params)[ \t]+(.*)$", re.MULTILINE)

# query parameters a client may pass through to a script, and the shell
# variable each one maps to
ALLOWED_PARAMS: Dict[str, str] = {
    "duration": "DURATION",
    "threads": "THREADS",
    "interval": "INTERVAL",
    "baseline": "BASELINE",
    "gpu": "GPU",
    "speed": "SPEED",
    "spd": "SPD",
    "load": "LOAD",
    "plain": "PLAIN",
    "cols": "COLS",
    "no_install": "NO_INSTALL",
}
PARAM_VALUE_RE = re.compile(r"^[A-Za-z0-9._:/-]{1,32}$")


@dataclass
class Script:
    name: str
    path: Path
    title: str = ""
    description: str = ""
    root: str = "optional"
    params: List[str] = field(default_factory=list)
    template: str = ""
    mtimes: Tuple = ()

    @property
    def filename(self) -> str:
        return f"{self.name}.sh"


class ScriptError(Exception):
    pass


class Registry:
    """Reads scripts from disk, resolves #@include, caches by mtime."""

    def __init__(self, scripts_dir: Path = SCRIPTS_DIR) -> None:
        self.dir = Path(scripts_dir).resolve()
        self._lock = threading.Lock()
        self._cache: Dict[str, Script] = {}

    # ------------------------------------------------------------ helpers
    def _script_path(self, name: str) -> Path:
        if not NAME_RE.match(name) or name.startswith("_"):
            raise ScriptError(f"invalid script name: {name!r}")
        path = (self.dir / f"{name}.sh").resolve()
        # never escape the scripts directory
        if path.parent != self.dir or not path.is_file():
            raise ScriptError(f"no such script: {name}")
        return path

    def _resolve_includes(
        self, text: str, path: Path, depth: int = 0
    ) -> Tuple[str, List[Path]]:
        if depth > 4:
            raise ScriptError("include nesting too deep")
        used: List[Path] = []

        def repl(match: re.Match) -> str:
            inc_name = match.group(1)
            if not INCLUDE_NAME_RE.match(inc_name) or "/" in inc_name:
                raise ScriptError(f"invalid include: {inc_name!r}")
            inc_path = (self.dir / inc_name).resolve()
            if inc_path.parent != self.dir or not inc_path.is_file():
                raise ScriptError(f"missing include: {inc_name}")
            body, nested = self._resolve_includes(
                inc_path.read_text(encoding="utf-8"), inc_path, depth + 1
            )
            used.append(inc_path)
            used.extend(nested)
            # drop the shebang of the fragment, keep everything else
            lines = body.splitlines()
            if lines and lines[0].startswith("#!"):
                lines = lines[1:]
            return "\n".join(lines)

        return INCLUDE_RE.sub(repl, text), used

    # -------------------------------------------------------------- public
    def names(self) -> List[str]:
        return sorted(
            p.stem
            for p in self.dir.glob("*.sh")
            if not p.name.startswith("_") and p.is_file()
        )

    def get(self, name: str) -> Script:
        path = self._script_path(name)
        with self._lock:
            cached = self._cache.get(name)
            raw = path.read_text(encoding="utf-8")
            body, includes = self._resolve_includes(raw, path)
            mtimes = tuple(
                sorted((str(p), p.stat().st_mtime_ns) for p in [path, *includes])
            )
            if cached is not None and cached.mtimes == mtimes:
                return cached

            meta = {k: v.strip() for k, v in META_RE.findall(raw)}
            script = Script(
                name=name,
                path=path,
                title=meta.get("title", name),
                description=meta.get("description", ""),
                root=meta.get("root", "optional"),
                params=[p for p in re.split(r"[,\s]+", meta.get("params", "")) if p],
                template=body,
                mtimes=mtimes,
            )
            self._cache[name] = script
            return script

    def all(self) -> List[Script]:
        out = []
        for name in self.names():
            try:
                out.append(self.get(name))
            except ScriptError:
                continue
        return out

    def render(
        self,
        name: str,
        base_url: str,
        token: Optional[str] = None,
        params: Optional[Dict[str, str]] = None,
    ) -> str:
        script = self.get(name)
        token_q = f"?t={token}" if token else ""
        text = (
            script.template.replace("@@BASE_URL@@", base_url)
            .replace("@@TOKEN_QUERY@@", token_q)
            .replace("@@VERSION@@", VERSION)
        )
        prelude = build_prelude(params or {})
        if prelude:
            text = insert_prelude(text, prelude)
        return text


def build_prelude(params: Dict[str, str]) -> str:
    """Turn safe query params into `VAR=${VAR:-value}` lines."""
    lines = []
    for key, value in params.items():
        var = ALLOWED_PARAMS.get(key.lower())
        if not var or not PARAM_VALUE_RE.match(value):
            continue
        lines.append(f"{var}=${{{var}:-{value}}}")
    if not lines:
        return ""
    return (
        "# ---- values from the request URL (environment still wins) ----\n"
        + "\n".join(lines)
        + "\n"
    )


def insert_prelude(text: str, prelude: str) -> str:
    """Insert the prelude directly after the shebang line."""
    lines = text.splitlines(keepends=True)
    idx = 1 if lines and lines[0].startswith("#!") else 0
    return "".join(lines[:idx]) + prelude + "".join(lines[idx:])
