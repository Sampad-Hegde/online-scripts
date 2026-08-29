# =====================================================================
#  online-script    dev = podman, prod = docker
#
#    make help          list every target
#    make dev           build + run locally with podman on :8080
#    make smoke         hit every endpoint of the running container
#    make test          python tests + shell syntax + shellcheck
#    make prod-up       build + run with docker compose (Portainer host)
# =====================================================================

# ---------------------------------------------------------------------
#  configuration
#
#  precedence:  make command line  >  shell environment  >  $(ENV_FILE)  >
#               the defaults below.  The same .env is handed to compose and
#               to the dev container, so one file drives everything.
#  keep .env simple: KEY=value, no quotes, no $ substitution.
# ---------------------------------------------------------------------
ENV_FILE     ?= .env
-include $(ENV_FILE)

IMAGE_NAME   ?= online-script
TAG          ?= latest
REGISTRY     ?=
# IMAGE is the full reference and means exactly what ${IMAGE} means in
# docker-compose.yml, so setting it in .env just works
IMAGE        ?= $(if $(REGISTRY),$(REGISTRY)/,)$(IMAGE_NAME):$(TAG)
APP_VERSION  ?= 1.0.0
HOST_PORT    ?= 8080
CONTAINER    ?= online-script-dev

DEV_ENGINE   ?= podman
PROD_ENGINE  ?= docker

BASE_URL     ?= http://localhost:$(HOST_PORT)
# query string that authenticates smoke tests when AUTH_TOKEN is set
TQ           ?= $(if $(AUTH_TOKEN),?t=$(AUTH_TOKEN),)
RENDER_DIR   ?= build/rendered
SHELL_IMAGE  ?= docker.io/library/debian:stable-slim
PY           ?= $(shell command -v python3.13 || command -v python3.12 || \
                  command -v python3.11 || command -v python3.10 || command -v python3)
VENV         ?= .venv

# an inline "# comment" in .env would otherwise leave trailing blanks
IMAGE        := $(strip $(IMAGE))
TAG          := $(strip $(TAG))
HOST_PORT    := $(strip $(HOST_PORT))
APP_VERSION  := $(strip $(APP_VERSION))

# compose finds .env on its own, but be explicit so ENV_FILE=.env.prod works
ENV_ARG      := $(if $(wildcard $(ENV_FILE)),--env-file $(ENV_FILE),)
# a variable given on the make command line is exported by make itself, so it
# still overrides .env inside compose; only IMAGE has to be recomposed here
cmdline       = $(filter command,$(firstword $(origin $(1))))
IMAGE_ARG    := $(if $(call cmdline,IMAGE)$(call cmdline,IMAGE_NAME)$(call cmdline,TAG)$(call cmdline,REGISTRY),IMAGE=$(IMAGE),)

SCRIPTS      := $(wildcard scripts/*.sh)
# SC2086 word splitting is intentional for $SUDO / package lists
# SC2012 ls|wc is fine for counting sysfs entries
# SC1090 the library is spliced in by the server, not sourced
# SC3043 'local' is supported by dash, ash and bash alike
# SC2034 variables in _lib.sh are used by the scripts that include it
# SC1091 /etc/os-release is only there at run time
SC_EXCLUDE   := SC2086,SC2012,SC1090,SC1091,SC2034,SC3043,SC2317,SC2166

# podman ships "podman compose"; fall back to podman-compose
DEV_COMPOSE  := $(shell if $(DEV_ENGINE) compose version >/dev/null 2>&1; \
                  then echo "$(DEV_ENGINE) compose"; else echo "podman-compose"; fi)
PROD_COMPOSE := $(shell if $(PROD_ENGINE) compose version >/dev/null 2>&1; \
                  then echo "$(PROD_ENGINE) compose"; else echo "docker-compose"; fi)

.DEFAULT_GOAL := help
.PHONY: help env dev build run stop restart logs shell ps clean smoke test test-py \
        test-sh test-lib test-cuda test-hw lint serve venv prod-build prod-up \
        prod-down \
        prod-logs prod-restart prod-ps push save render render-all run-scripts \
        dev-compose-up dev-compose-down

## ---------------------------------------------------------------- help
help: ## show this help
	@printf '\nonline-script  -  make targets\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN{FS=":.*?## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@printf '\nrun "make env" to see the effective settings\n\n'

env: ## show the effective configuration (defaults + $(ENV_FILE) + command line)
	@printf '\n  %-14s %s\n' 'ENV_FILE' \
	  '$(ENV_FILE)$(if $(wildcard $(ENV_FILE)), (loaded), (not present - using defaults))'
	@printf '  %-14s %s\n' 'IMAGE'        '$(IMAGE)'
	@printf '  %-14s %s\n' 'APP_VERSION'  '$(APP_VERSION)'
	@printf '  %-14s %s\n' 'HOST_PORT'    '$(HOST_PORT)'
	@printf '  %-14s %s\n' 'LOG_LEVEL'    '$(if $(LOG_LEVEL),$(LOG_LEVEL),INFO (default))'
	@printf '  %-14s %s\n' 'AUTH_TOKEN'   '$(if $(AUTH_TOKEN),set - every request needs ?t=...,empty - service is open)'
	@printf '  %-14s %s\n' 'PUBLIC_BASE_URL' '$(if $(PUBLIC_BASE_URL),$(PUBLIC_BASE_URL),unset - taken from the request)'
	@printf '  %-14s %s\n' 'DEV_ENGINE'   '$(DEV_ENGINE) ($(DEV_COMPOSE))'
	@printf '  %-14s %s\n' 'PROD_ENGINE'  '$(PROD_ENGINE) ($(PROD_COMPOSE))'
	@printf '\n  compose will be called as:  %s\n\n' '$(IMAGE_ARG) $(PROD_COMPOSE) $(ENV_ARG) up -d --build'

## ------------------------------------------------------------ dev (podman)
dev: build run smoke ## build, run and smoke test with podman

build: ## build the image with podman
	$(DEV_ENGINE) build $(if $(filter podman,$(DEV_ENGINE)),--format docker,) \
	  --build-arg APP_VERSION=$(APP_VERSION) -t $(IMAGE) .

run: ## run the container with podman on $(HOST_PORT)
	-$(DEV_ENGINE) rm -f $(CONTAINER) >/dev/null 2>&1
	$(DEV_ENGINE) run -d --name $(CONTAINER) \
	  -p $(HOST_PORT):8080 \
	  $(ENV_ARG) \
	  -e APP_VERSION=$(APP_VERSION) \
	  -e LOG_LEVEL=$(if $(LOG_LEVEL),$(LOG_LEVEL),INFO) \
	  $(if $(AUTH_TOKEN),-e AUTH_TOKEN=$(AUTH_TOKEN),) \
	  -v ./scripts:/app/scripts:ro,z \
	  $(IMAGE)
	@printf '\nrunning at %s   (scripts mounted live from ./scripts)\n' '$(BASE_URL)'
	@printf 'try:  curl -fsSL %s/ \n\n' '$(BASE_URL)'

stop: ## stop and remove the dev container
	-$(DEV_ENGINE) rm -f $(CONTAINER)

restart: stop run ## restart the dev container

logs: ## follow dev container logs
	$(DEV_ENGINE) logs -f $(CONTAINER)

shell: ## shell inside the dev container
	$(DEV_ENGINE) exec -it $(CONTAINER) sh

ps: ## show the dev container
	$(DEV_ENGINE) ps --filter name=$(CONTAINER)

dev-compose-up: ## run the compose stack with podman instead of plain run
	$(IMAGE_ARG) $(DEV_COMPOSE) $(ENV_ARG) up -d --build

dev-compose-down: ## stop the podman compose stack
	$(DEV_COMPOSE) $(ENV_ARG) down

## ----------------------------------------------------------------- checks
smoke: ## curl every endpoint of the running service
	@set -e; \
	printf '\n== /healthz\n';  curl -fsS  $(BASE_URL)/healthz$(TQ) | head -c 400; echo; \
	printf '\n== /scripts\n';  curl -fsS  $(BASE_URL)/scripts$(TQ) | head -c 600; echo; \
	printf '\n== / (plain)\n'; curl -fsS -A curl $(BASE_URL)/$(TQ); \
	for s in $(basename $(notdir $(SCRIPTS))); do \
	  case "$$s" in _*) continue ;; esac; \
	  printf '\n== /%s.sh  ' "$$s"; \
	  curl -fsS -o /tmp/os-$$s.sh -w '%{size_download} bytes  http %{http_code}' \
	    $(BASE_URL)/$$s.sh$(TQ); \
	  sh -n /tmp/os-$$s.sh && printf '  syntax ok\n'; \
	done; \
	printf '\n== 404 handling  '; \
	code=$$(curl -s -o /dev/null -w '%{http_code}' $(BASE_URL)/nope.sh$(TQ)); \
	test "$$code" = "404" && printf 'ok (404)\n\n'

test: test-py test-sh test-lib test-cuda test-hw lint ## run everything

test-py: venv ## python tests (api, script assembly, auth)
	$(VENV)/bin/pytest

test-sh: ## POSIX syntax check every script (host sh, dash, busybox ash)
	@for f in $(SCRIPTS); do sh -n $$f && printf '  sh -n        %s ok\n' $$f; done
	@printf '\nchecking with dash and busybox ash inside a container...\n'
	@$(DEV_ENGINE) run --rm -v ./scripts:/s:ro $(SHELL_IMAGE) sh -c '\
	  set -e; \
	  export DEBIAN_FRONTEND=noninteractive; \
	  apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y dash busybox >/dev/null 2>&1; \
	  for f in /s/*.sh; do dash -n $$f && echo "  dash -n      $$f ok"; done; \
	  for f in /s/*.sh; do busybox ash -n $$f && echo "  busybox -n   $$f ok"; done'

test-lib: ## run the library self test under dash, busybox ash and bash
	@sh tests/lib_selftest.sh | tail -1
	@$(DEV_ENGINE) run --rm -v ./scripts:/w/scripts:ro -v ./tests:/w/tests:ro \
	  -w /w $(SHELL_IMAGE) sh -c '\
	  export DEBIAN_FRONTEND=noninteractive; \
	  apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y dash busybox >/dev/null 2>&1; \
	  rc=0; \
	  for s in dash "busybox ash" bash; do \
	    printf "  %-12s " "$$s"; \
	    $$s tests/lib_selftest.sh > /tmp/out 2>&1 || rc=1; \
	    tail -1 /tmp/out; \
	    grep -E "^  FAIL" /tmp/out || true; \
	  done; exit $$rc'

lint: ## shellcheck the scripts (skipped when shellcheck is absent)
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -s sh -e $(SC_EXCLUDE) $(SCRIPTS) && echo 'shellcheck clean'; \
	else \
	  printf 'shellcheck not installed - running it in a container\n'; \
	  $(DEV_ENGINE) run --rm -v ./scripts:/mnt:ro docker.io/koalaman/shellcheck:stable \
	    -s sh -e $(SC_EXCLUDE) $(patsubst scripts/%,/mnt/%,$(SCRIPTS)) \
	    && echo 'shellcheck clean'; \
	fi

test-cuda: ## compile-check the CUDA sources embedded in nvidia-gpu.sh
	@$(DEV_ENGINE) run --rm -v ./scripts:/s:ro -v ./tests:/t:ro -w /tmp $(SHELL_IMAGE) sh -c '\
	  export DEBIAN_FRONTEND=noninteractive; \
	  apt-get -qq update >/dev/null 2>&1 && apt-get -qq install -y g++ >/dev/null 2>&1; \
	  sh /t/cuda_syntax_check.sh /s/nvidia-gpu.sh'

test-hw: render-all ## run cpu-load and gpu-load against a fake /sys tree
	$(DEV_ENGINE) run --rm -e LANG=C.UTF-8 \
	  -v ./$(RENDER_DIR):/r:ro -v ./tests:/t:ro -w /tmp $(SHELL_IMAGE) \
	  sh /t/fake_hw_run.sh /r

run-scripts: render-all ## really execute the scripts inside a container
	$(DEV_ENGINE) run --rm --privileged -e LANG=C.UTF-8 -v ./$(RENDER_DIR):/r:ro \
	  $(SHELL_IMAGE) sh -c 'sh /r/sysinfo.sh; sh /r/storage.sh; \
	    DURATION=15 BASELINE=3 sh /r/cpu-load.sh'

render: ## print one assembled script, e.g. make render S=sysinfo
	@curl -fsS $(BASE_URL)/$(or $(S),sysinfo).sh$(TQ)

render-all: venv ## write standalone copies of every script to $(RENDER_DIR)
	@$(VENV)/bin/python -m app.render --out $(RENDER_DIR) --base-url $(BASE_URL) \
	  $(if $(AUTH_TOKEN),--token $(AUTH_TOKEN),)

## -------------------------------------------------------------- local py
venv: $(VENV)/.stamp ## create the dev virtualenv

$(VENV)/.stamp: requirements-dev.txt requirements.txt
	$(PY) -m venv $(VENV)
	$(VENV)/bin/pip install -q --upgrade pip
	$(VENV)/bin/pip install -q -r requirements-dev.txt
	@touch $@

serve: venv ## run uvicorn on the host with autoreload (no container)
	$(VENV)/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port $(HOST_PORT)

## ----------------------------------------------------------- prod (docker)
prod-build: ## build the production image with docker
	$(PROD_ENGINE) build --build-arg APP_VERSION=$(APP_VERSION) -t $(IMAGE) .

prod-up: ## deploy the compose stack with docker
	$(IMAGE_ARG) $(PROD_COMPOSE) $(ENV_ARG) up -d --build
	@printf '\ndeployed on port %s. check:  curl -fsSL http://<server>:%s/\n\n' \
	  '$(HOST_PORT)' '$(HOST_PORT)'

prod-down: ## stop the compose stack
	$(PROD_COMPOSE) $(ENV_ARG) down

prod-restart: ## recreate the stack
	$(IMAGE_ARG) $(PROD_COMPOSE) $(ENV_ARG) up -d --force-recreate --build

prod-logs: ## follow stack logs
	$(PROD_COMPOSE) $(ENV_ARG) logs -f --tail=100

prod-ps: ## stack status
	$(PROD_COMPOSE) $(ENV_ARG) ps

push: prod-build ## push the image to $(REGISTRY)
	@test -n "$(REGISTRY)" || { echo 'set REGISTRY=registry.example.com/you'; exit 1; }
	$(PROD_ENGINE) push $(IMAGE)

save: build ## export the podman image as a tarball for an offline server
	$(DEV_ENGINE) save -o $(IMAGE_NAME)-$(TAG).tar $(IMAGE)
	@echo "wrote $(IMAGE_NAME)-$(TAG).tar  ->  docker load -i $(IMAGE_NAME)-$(TAG).tar"

clean: stop ## remove venv, caches, rendered scripts and image tarballs
	rm -rf $(VENV) .pytest_cache app/__pycache__ tests/__pycache__ build *.tar
