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


def recipe(target: str) -> str:
    """The command lines of one make target."""
    m = re.search(rf"^{re.escape(target)}:[^\n]*\n((?:\t[^\n]*\n)+)", MAKEFILE, re.M)
    assert m, f"{target} recipe not found"
    return m.group(1)


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


# --------------------------------------------------------------- .env wiring
def test_makefile_loads_the_env_file():
    assert re.search(r"^ENV_FILE\s+\?= \.env", MAKEFILE, re.M)
    assert re.search(r"^-include \$\(ENV_FILE\)", MAKEFILE, re.M)


def test_prod_targets_do_not_shadow_the_env_file():
    """Forcing VAR=... in front of compose beats .env - that was the bug."""
    for target in ("prod-up", "prod-restart", "prod-down", "prod-logs", "dev-compose-up"):
        body = recipe(target)
        for var in ("HOST_PORT=", "APP_VERSION=", "LOG_LEVEL=", "AUTH_TOKEN="):
            assert var not in body, f"{target} forces {var}, which overrides .env"


def test_compose_calls_pass_the_env_file():
    for target in ("prod-up", "prod-down", "prod-logs", "prod-ps"):
        assert "$(ENV_ARG)" in recipe(target), f"{target} does not pass $(ENV_ARG)"


def test_dev_container_gets_the_env_file_too():
    body = recipe("run")
    assert "$(ENV_ARG)" in body
    assert "-p $(HOST_PORT):8080" in body


def test_image_variable_matches_compose_semantics():
    """IMAGE must be a full reference, like ${IMAGE} in docker-compose.yml."""
    assert re.search(r"^IMAGE\s+\?= \$\(if \$\(REGISTRY\)", MAKEFILE, re.M)
    assert "FULL_IMAGE" not in MAKEFILE, "stale variable"
    assert "$(IMAGE):$(TAG)" not in MAKEFILE, "IMAGE already carries the tag"


def test_env_example_matches_the_makefile_knobs():
    documented = set(re.findall(r"^#?\s*([A-Z_]+)=", ENV_EXAMPLE, re.M))
    for key in ("HOST_PORT", "IMAGE", "APP_VERSION", "AUTH_TOKEN", "LOG_LEVEL"):
        assert key in documented, f"{key} should be in .env.example"
