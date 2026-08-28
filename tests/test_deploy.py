"""Guards on the deployment files - a typo here only shows up in production."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
COMPOSE = yaml.safe_load((ROOT / "docker-compose.yml").read_text())
DOCKERFILE = (ROOT / "Dockerfile").read_text()
ENV_EXAMPLE = (ROOT / ".env.example").read_text()
MAKEFILE = (ROOT / "Makefile").read_text()

SERVICE = COMPOSE["services"]["online-script"]


def test_compose_service_is_hardened_and_restarts():
    assert SERVICE["restart"] == "unless-stopped"
    assert SERVICE["read_only"] is True
    assert SERVICE["cap_drop"] == ["ALL"]
    assert "no-new-privileges:true" in SERVICE["security_opt"]
    assert "/tmp" in SERVICE["tmpfs"]
    assert SERVICE["healthcheck"]["test"]
    assert SERVICE["logging"]["options"]["max-size"]


def test_compose_port_and_image_are_overridable():
    assert SERVICE["ports"] == ["${HOST_PORT:-8080}:8080"]
    assert SERVICE["image"].startswith("${IMAGE:-")
    assert SERVICE["build"]["context"] == "."


def test_compose_exposes_the_settings_the_app_reads():
    env = SERVICE["environment"]
    for key in ("AUTH_TOKEN", "PUBLIC_BASE_URL", "APP_VERSION", "LOG_LEVEL"):
        assert key in env, f"{key} missing from the compose environment"


def test_env_example_documents_every_compose_variable():
    referenced = set(re.findall(r"\$\{([A-Z_]+)(?::-[^}]*)?\}", (ROOT / "docker-compose.yml").read_text()))
    documented = set(re.findall(r"^#?\s*([A-Z_]+)=", ENV_EXAMPLE, re.M))
    missing = referenced - documented - {"TZ"}
    assert not missing, f"undocumented in .env.example: {sorted(missing)}"


def test_dockerfile_runs_unprivileged_and_healthchecks():
    assert re.search(r"^USER appuser", DOCKERFILE, re.M)
    assert "HEALTHCHECK" in DOCKERFILE
    assert "EXPOSE 8080" in DOCKERFILE
    assert "COPY scripts/" in DOCKERFILE, "scripts must be baked into the image"
    assert "uvicorn app.main:app" in DOCKERFILE
    # the container must trust proxy headers so printed URLs are right
    assert "--proxy-headers" in DOCKERFILE


def test_makefile_keeps_podman_for_dev_and_docker_for_prod():
    assert re.search(r"^DEV_ENGINE\s+\?= podman", MAKEFILE, re.M)
    assert re.search(r"^PROD_ENGINE\s+\?= docker", MAKEFILE, re.M)
    for target in ("dev:", "prod-up:", "test:", "smoke:", "render-all:"):
        assert re.search(rf"^{re.escape(target)}", MAKEFILE, re.M), f"missing {target}"
