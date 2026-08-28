# online-script

Shell scripts for inspecting PC hardware, served over HTTP so you can run them
on any machine you can boot a live USB on:

```sh
curl -fsSL http://your-server:8080/sysinfo.sh | sudo sh
```

Built for walking into a shop with a refurbished PC, booting a live Ubuntu and
knowing in a few minutes what the hardware actually is and whether the drive is
worn out — without trusting anything Windows says about itself, and without
carrying USB sticks full of tools.

## What you get

| script         | what it reports |
| -------------- | --------------- |
| `sysinfo.sh`   | system/BIOS/Secure Boot/TPM, CPU (cores, threads, base + turbo clock, cache, features), memory modules per slot (size, type, configured vs rated speed, manufacturer, part number), motherboard + chipset, SATA ports used/free, M.2 and PCIe slots (free or occupied), block devices, network adapters (driver, link, negotiated + maximum speed), GPUs, display outputs, **PCIe link width/gen vs capability**, all temperature and fan sensors |
| `storage.sh`   | per drive: model, serial, firmware, capacity, SMART overall health, **lifespan left**, power-on hours, power cycles, data written/read, reallocated + pending sectors, temperature, sequential read speed, and a verdict |
| `cpu-load.sh`  | loads every thread, samples temperature / clock / package power every second, reports **min, max, average and median**, idle baseline, heat soak, throttle events, an ASCII timeline and a cooling verdict |
| `gpu-load.sh`  | same idea for the GPU: temperature, hotspot, utilisation, clock, power, PCIe link under load |
| `all.sh`       | `sysinfo` + `storage` back to back (`LOAD=1` adds the load tests) |

Each script is one self-contained POSIX `sh` file: the server splices a shared
library into it before handing it over, so there is nothing to install and no
second request to make.

## Endpoints

| endpoint | purpose |
| -------- | ------- |
| `GET /` | usage + script list (plain text for `curl`, a small page for a browser) |
| `GET /scripts` | JSON list of every script with its description and ready-made command |
| `GET /<name>.sh` | the script itself (`/<name>` works too) |
| `GET /healthz` | health probe, also used by the container healthcheck |
| `GET /docs` | OpenAPI UI |

## Running the scripts

```sh
# quick inventory
curl -fsSL http://server:8080/sysinfo.sh | sudo sh

# drive health - the thing that decides a purchase
curl -fsSL http://server:8080/storage.sh | sudo sh

# 10 minute CPU burn-in with thermals
curl -fsSL http://server:8080/cpu-load.sh | sudo DURATION=600 sh

# same, as a URL you can hand to someone else
curl -fsSL 'http://server:8080/cpu-load.sh?duration=600&threads=8' | sudo sh

# everything, including load tests
curl -fsSL http://server:8080/all.sh | sudo LOAD=1 sh
```

`sudo` matters: DMI (memory modules, slots), SMART data and automatic package
installation all need root. Without it the scripts still run and simply mark
the rows they cannot read.

### Options

Every option is an environment variable, and the safe ones can also be passed
as URL query parameters (`?duration=600`). The environment wins over the URL.

| variable | default | effect |
| -------- | ------- | ------ |
| `DURATION` | `60` | seconds of load (`cpu-load`, `gpu-load`) |
| `THREADS` | all threads | cpu-load workers |
| `INTERVAL` | `1` | seconds between samples |
| `BASELINE` | `8` | seconds of idle measurement before loading |
| `GPU` | `0` | which GPU index to test |
| `SPEED` | `1` | `0` skips the storage sequential-read check |
| `SPD` | `0` | `1` also decodes the memory SPD EEPROM (CAS latency) |
| `LOAD` | `0` | `1` makes `all.sh` include the load tests |
| `COLS` | terminal width | force the table width, e.g. `COLS=160` for a wide terminal |
| `PLAIN` | `0` | `1` for ASCII tables without colour |
| `NO_COLOR` | unset | any value disables colour |
| `NO_INSTALL` | `0` | `1` never installs packages, just reports what is missing |

### Dependencies

The scripts read `/sys` and `/proc` first, so a lot works with nothing
installed. When something better is available they install it themselves:
`dmidecode`, `pciutils`, `util-linux`, `smartmontools`, `nvme-cli`, `ethtool`,
`stress-ng`, `lm-sensors`, `glmark2`.

Package managers handled: `apt` (Debian/Ubuntu/Mint/Pop), `apk` (Alpine),
`dnf`/`yum` (Fedora/RHEL/Rocky/Alma), `pacman` (Arch), `zypper` (SUSE).
Debian/Ubuntu and Alpine are the tested paths. Only `curl` (or `wget`) is
assumed to exist.

## Deploying

Dev on a laptop uses **podman**, production uses **docker** (Portainer).
Everything is in the `Makefile`:

```sh
make            # list targets
make dev        # podman build + run + smoke test on :8080
make test       # everything below, in one go
make test-py    #   api, assembly, auth, deployment-file guards
make test-sh    #   POSIX syntax under host sh, dash and busybox ash
make test-lib   #   library self test (tables, statistics, parsers, fake sysfs)
make test-hw    #   cpu-load + gpu-load driven by a fake /sys tree that heats up
make lint       #   shellcheck (containerised if not installed locally)
make serve      # uvicorn on the host with autoreload, no container
make logs       # follow the dev container
make stop
```

`make run` mounts `./scripts` into the container read-only, so editing a script
and re-running `curl` is enough — no rebuild.

Need the scripts without the server (a USB stick, an air-gapped machine)?

```sh
make render-all BASE_URL=http://hw.lan:8080     # -> build/rendered/*.sh
python -m app.render --out dist --base-url https://hw.example.com --token SECRET
```

### Production (Portainer)

Portainer → *Stacks* → *Add stack* → point it at this repository (or paste
`docker-compose.yml`), then set the variables from `.env.example` in the
*Environment variables* box and deploy. Or from a shell on the server:

```sh
make prod-up          # docker compose up -d --build
make prod-logs
make prod-down
```

The compose service is a single container: read-only root filesystem, all
capabilities dropped, `no-new-privileges`, unprivileged user, log rotation and
a healthcheck.

If your server cannot build images, build elsewhere and ship the image:

```sh
make push REGISTRY=registry.example.com/you   # or
make save                                     # image tarball -> docker load
```

### Exposing it to the internet

The service only serves text, but anything you expose gets found. Options:

- keep it on a VPN (Tailscale/WireGuard) — simplest and what this is designed for;
- put it behind your existing reverse proxy with TLS and set
  `PUBLIC_BASE_URL=https://hw.example.com` so the scripts print correct URLs;
- set `AUTH_TOKEN=<random>`; then every request needs `?t=<token>` (or an
  `Authorization: Bearer` / `X-Auth-Token` header), and the token is baked into
  the URLs the scripts print. `/healthz` stays open for the healthcheck.

## Layout

```
app/main.py            FastAPI app: index, /scripts, /<name>.sh, auth, proxy headers
app/registry.py        loads scripts, splices in _lib.sh, caches by mtime, URL params
app/render.py          writes standalone script copies to a directory
scripts/_lib.sh        tables, statistics, sparklines, sensors, package install
scripts/sysinfo.sh     hardware inventory
scripts/storage.sh     SMART health and wear
scripts/cpu-load.sh    CPU load + thermal test
scripts/gpu-load.sh    GPU load + thermal test
scripts/all.sh         chains the above
tests/test_api.py      API, assembly, auth, traversal, parameter safety
tests/test_deploy.py   Dockerfile / compose / Makefile guards
tests/lib_selftest.sh  library self test (tables, stats, parsers, fake sysfs)
tests/fake_hw_run.sh   load tests run against a simulated overheating machine
```

### Adding a script

Drop `scripts/mytest.sh` in place, start it with the metadata header and the
include line, and it appears in `/`, `/scripts` and `/mytest.sh` immediately:

```sh
#!/bin/sh
#@name        mytest
#@title       My test
#@description What it reports
#@root        recommended
#@include _lib.sh

os_init "mytest"

t_open "SOMETHING"
t_row "Field" "value"
t_end

os_footer
```

### Table width

Tables are laid out for the width of your terminal (`tput cols`, then
`stty size </dev/tty`, then `$COLUMNS`, falling back to 120). Anything that
still does not fit is **wrapped inside the cell** rather than cut off, and
columns holding unbreakable values (MAC addresses, part numbers, bus IDs) are
the last to be squeezed. Override it when you want:

```sh
curl -fsSL http://server:8080/sysinfo.sh | sudo COLS=200 sh
curl -fsSL 'http://server:8080/sysinfo.sh?cols=200' | sudo sh
```

## Notes and limits

- CAS latency is not in DMI; `SPD=1` reads the SPD EEPROM over i2c instead,
  which needs root and a board that exposes it.
- Reported SATA port count comes from the ATA ports the chipset exposes, which
  can differ from the number of physical connectors.
- A PCIe link showing a lower generation at idle is usually power saving —
  check it again while `gpu-load.sh` is running.
- Memory testing needs a reboot to do properly (memtest86+); the load tests
  here run in userspace.
- `stress-ng` gives the heaviest CPU load; without it the script falls back to
  `openssl speed`, then to plain `awk` loops.
- A GPU load generator needs a working GL/Vulkan/OpenCL stack. On a bare
  console `glmark2-drm` or `stress-ng --gpu` work; otherwise the script says so
  and runs monitor-only while you load the GPU yourself.
