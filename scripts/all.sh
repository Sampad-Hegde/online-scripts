#!/bin/sh
# shellcheck shell=sh disable=SC2086
#@name        all
#@title       Everything (shop visit check)
#@description Runs sysinfo + storage back to back; add LOAD=1 for the cpu/gpu load tests too
#@root        recommended
#@params      load,duration
#@include _lib.sh

os_init "all"

LOAD=${LOAD:-0}
DURATION=${DURATION:-60}

fetch() {
    if have curl; then curl -fsSL "$1"
    elif have wget; then wget -qO- "$1"
    else err "neither curl nor wget is installed"; return 1; fi
}

run_part() {
    _name="$1"; shift
    rule
    printf ' %s>>> %s%s\n' "$CB" "$_name" "$CR"
    rule
    if ! fetch "$OS_BASE_URL/$_name.sh$OS_TOKEN_Q" > "$OS_TMP/$_name.sh"; then
        err "could not download $_name.sh from $OS_BASE_URL"
        return 1
    fi
    # shellcheck disable=SC2086
    env "$@" sh "$OS_TMP/$_name.sh" || warn "$_name exited non-zero"
}

note "chaining scripts from $OS_BASE_URL"
printf '\n'

run_part sysinfo
run_part storage

if [ "$LOAD" = "1" ]; then
    run_part cpu-load "DURATION=$DURATION"
    run_part gpu-load "DURATION=$DURATION"
else
    note "load tests skipped - re-run with LOAD=1 (adds ~$((DURATION * 2 / 60)) min):"
    note "  curl -fsSL $(os_url /all.sh) | sudo LOAD=1 sh"
fi

rule
printf ' %sall done%s\n' "$CB" "$CR"
rule
