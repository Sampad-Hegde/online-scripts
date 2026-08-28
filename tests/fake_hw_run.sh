#!/bin/sh
# Integration test: run cpu-load.sh and gpu-load.sh against a fake /sys tree
# with sensors that move, then assert the report says what it should.
# Must run on Linux (the scripts read /proc too).  Needs rendered scripts:
#     python -m app.render --out build/rendered
#     sh tests/fake_hw_run.sh build/rendered
S=${1:-build/rendered}
DUR=${DUR:-10}
BASE=${BASE:-3}
FAILED=0
F=$(mktemp -d)
trap 'rm -rf "$F"; kill $SIM 2>/dev/null' EXIT

for f in "$S/cpu-load.sh" "$S/gpu-load.sh"; do
    [ -r "$f" ] || { echo "missing $f - run 'python -m app.render' first"; exit 2; }
done

want() { # description needle file
    if grep -q -- "$2" "$3"; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s  (no match for [%s])\n' "$1" "$2"
        FAILED=$((FAILED + 1))
    fi
}
wantnot() { # $2 is an extended regexp
    if grep -qE -- "$2" "$3"; then
        printf '  FAIL  %s  (unexpected [%s])\n' "$1" "$2"
        FAILED=$((FAILED + 1))
    else
        printf '  ok    %s\n' "$1"
    fi
}

# ---------------------------------------------------------------- fake CPU
mkdir -p "$F/class/hwmon/hwmon0" \
         "$F/devices/system/cpu/cpu0/cpufreq" "$F/devices/system/cpu/cpu1/cpufreq" \
         "$F/devices/system/cpu/cpu0/thermal_throttle" \
         "$F/class/powercap/intel-rapl:0"
echo coretemp        > "$F/class/hwmon/hwmon0/name"
echo 'Package id 0'  > "$F/class/hwmon/hwmon0/temp1_label"
echo 100000          > "$F/class/hwmon/hwmon0/temp1_crit"
echo 35000           > "$F/class/hwmon/hwmon0/temp1_input"
echo 3600000         > "$F/devices/system/cpu/cpu0/cpufreq/base_frequency"
echo 5000000         > "$F/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
echo 800000          > "$F/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
echo 800000          > "$F/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
echo 0               > "$F/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count"
echo 1000000         > "$F/class/powercap/intel-rapl:0/energy_uj"

# ---------------------------------------------------------------- fake GPU
B="$F/bus/pci/devices/0000:03:00.0"
mkdir -p "$B/hwmon/hwmon3" "$F/class/drm/card0" "$F/driver/amdgpu"
echo 0x030000          > "$B/class"
echo 0x1002            > "$B/vendor"
echo 0x73df            > "$B/device"
echo '8.0 GT/s PCIe'   > "$B/current_link_speed"
echo 8                 > "$B/current_link_width"
echo '16.0 GT/s PCIe'  > "$B/max_link_speed"
echo 16                > "$B/max_link_width"
echo 12884901888       > "$B/mem_info_vram_total"
echo 2147483648        > "$B/mem_info_vram_used"
echo 0                 > "$B/gpu_busy_percent"
echo amdgpu            > "$B/hwmon/hwmon3/name"
echo edge              > "$B/hwmon/hwmon3/temp1_label"
echo 40000             > "$B/hwmon/hwmon3/temp1_input"
echo junction          > "$B/hwmon/hwmon3/temp2_label"
echo 43000             > "$B/hwmon/hwmon3/temp2_input"
echo 15000000          > "$B/hwmon/hwmon3/power1_average"
printf '0: 500Mhz\n1: 1200Mhz\n2: 2450Mhz *\n' > "$B/pp_dpm_sclk"
ln -sfn "$F/driver/amdgpu" "$B/driver"

# ------------------------------------------------- sensors that move in time
simulate() {
    t=35000; f=800000; e=1000000; gt=40000; gj=43000; n=0
    while [ "$n" -lt 300 ]; do
        n=$((n + 1))
        if [ "$n" -gt "$BASE" ]; then
            t=$((t + 12000)); [ "$t" -gt 100000 ] && t=100000
            f=4900000
            [ "$t" -ge 100000 ] && f=3200000           # thermal throttle
            [ "$t" -ge 100000 ] && echo $((n / 4)) > "$F/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count"
            e=$((e + 95000000))                        # 95 W
            gt=$((gt + 3000)); [ "$gt" -gt 78000 ] && gt=78000
            gj=$((gj + 4000)); [ "$gj" -gt 95000 ] && gj=95000
            echo 96 > "$B/gpu_busy_percent"
            echo 240000000 > "$B/hwmon/hwmon3/power1_average"
        else
            e=$((e + 12000000))                        # 12 W idle
        fi
        echo "$t" > "$F/class/hwmon/hwmon0/temp1_input"
        echo "$f" > "$F/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
        echo $((f - 100000)) > "$F/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
        echo "$e" > "$F/class/powercap/intel-rapl:0/energy_uj"
        echo "$gt" > "$B/hwmon/hwmon3/temp1_input"
        echo "$gj" > "$B/hwmon/hwmon3/temp2_input"
        sleep 1
    done
}
simulate & SIM=$!

echo "== cpu-load.sh against a CPU that overheats and throttles"
OS_SYSFS="$F" NO_INSTALL=1 NO_COLOR=1 PLAIN=1 DURATION="$DUR" BASELINE="$BASE" \
    sh "$S/cpu-load.sh" > "$F/cpu.out" 2> "$F/cpu.err"
rc=$?
check_empty() {
    if [ -s "$1" ]; then
        printf '  FAIL  %s wrote to stderr:\n' "$2"; sed 's/^/        /' "$1"
        FAILED=$((FAILED + 1))
    else
        printf '  ok    %s stderr is empty\n' "$2"
    fi
}
[ "$rc" = "0" ] && printf '  ok    cpu-load exit code 0\n' || {
    printf '  FAIL  cpu-load exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
check_empty "$F/cpu.err" cpu-load
want "reports the package sensor"   'coretemp/Package id 0' "$F/cpu.out"
want "reports the thermal limit"    '100 C'                 "$F/cpu.out"
want "reports rated clocks"         'base 3.60 GHz / max 5.00 GHz' "$F/cpu.out"
want "compares sustained clock"     'rated 3.60 GHz base clock' "$F/cpu.out"
want "samples the temperature"      '100.0 C'               "$F/cpu.out"
want "reads RAPL power"             '95.0 W'                "$F/cpu.out"
want "detects the thermal limit"    'reached the 100 C limit' "$F/cpu.out"
want "counts throttle events"       'thermal throttle event' "$F/cpu.out"
want "prints a timeline"            'TEMPERATURE TIMELINE'  "$F/cpu.out"
want "prints heat soak"             'Heat soak'             "$F/cpu.out"
wantnot "no unexpanded placeholder" '@@[A-Z_]+@@'           "$F/cpu.out"

echo "== gpu-load.sh against an AMD card on a downgraded PCIe link"
OS_SYSFS="$F" NO_INSTALL=1 NO_COLOR=1 PLAIN=1 DURATION="$DUR" BASELINE="$BASE" \
    sh "$S/gpu-load.sh" > "$F/gpu.out" 2> "$F/gpu.err"
rc=$?
[ "$rc" = "0" ] && printf '  ok    gpu-load exit code 0\n' || {
    printf '  FAIL  gpu-load exit code %s\n' "$rc"; FAILED=$((FAILED + 1)); }
check_empty "$F/gpu.err" gpu-load
want "finds the AMD card"          'amd'            "$F/gpu.out"
want "reads VRAM size"             '12.0 GiB'       "$F/gpu.out"
want "reads the edge sensor"       '78.0 C'         "$F/gpu.out"
want "reads the junction sensor"   'Hotspot'        "$F/gpu.out"
want "reads utilisation"           '96 %'           "$F/gpu.out"
want "parses pp_dpm_sclk"          '2450 MHz'       "$F/gpu.out"
want "reads power draw"            '240.0 W'        "$F/gpu.out"
want "flags the narrow PCIe link"  'linked at x8 of x16' "$F/gpu.out"
want "notes monitor-only mode"     'monitor only'   "$F/gpu.out"
wantnot "no unexpanded placeholder" '@@[A-Z_]+@@'   "$F/gpu.out"

# every rendered table row must line up
echo "== table alignment in real output"
for f in "$F/cpu.out" "$F/gpu.out"; do
    bad=$(awk '
        /^[+|]/ {
            if (block == 0) { block = 1; w = length($0) }
            else if (length($0) != w) { print FILENAME ": " NR; bad = 1 }
            next
        }
        { block = 0 }
        END { }' "$f")
    if [ -n "$bad" ]; then
        printf '  FAIL  misaligned rows in %s: %s\n' "$f" "$bad"
        FAILED=$((FAILED + 1))
    else
        printf '  ok    %s tables aligned\n' "$(basename "$f")"
    fi
done

printf '\n'
if [ "$FAILED" = "0" ]; then
    echo "fake hardware run: all checks passed"
    exit 0
fi
printf '%s check(s) FAILED\n' "$FAILED"
exit 1
