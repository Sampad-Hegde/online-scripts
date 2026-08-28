"""Write assembled scripts to a directory - handy for offline USB copies.

    python -m app.render --out dist --base-url http://hw.lan:8080
"""

from __future__ import annotations

import argparse
from pathlib import Path

from .registry import VERSION, Registry


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="build/rendered", help="output directory")
    ap.add_argument(
        "--base-url",
        default="http://localhost:8080",
        help="URL the scripts should print for follow-up commands",
    )
    ap.add_argument("--token", default=None, help="AUTH_TOKEN to bake into URLs")
    args = ap.parse_args()

    registry = Registry()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    for name in registry.names():
        body = registry.render(
            name, base_url=args.base_url.rstrip("/"), token=args.token
        )
        path = out / f"{name}.sh"
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
        print(f"  {path}  ({len(body)} bytes)")
    print(f"online-script {VERSION}: {len(registry.names())} scripts -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
