#!/bin/sh
# Self test for scripts/_lib.sh - runs under dash, busybox ash and bash.
#   sh tests/lib_selftest.sh [path-to-_lib.sh]
LIB=${1:-scripts/_lib.sh}
[ -r "$LIB" ] || { echo "cannot read $LIB"; exit 2; }

PLAIN=1
NO_COLOR=1
export PLAIN NO_COLOR
# shellcheck disable=SC1090
. "$LIB"

FAILED=0
ESCCH=$(printf '\033')
check() { # description expected actual
    if [ "$2" = "$3" ]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s\n        expected [%s]\n        actual   [%s]\n' "$1" "$2" "$3"
        FAILED=$((FAILED + 1))
    fi
}
contains() { # description needle haystack
    case "$3" in
        *"$2"*) printf '  ok    %s\n' "$1" ;;
        *) printf '  FAIL  %s\n        [%s] does not contain [%s]\n' "$1" "$3" "$2"
           FAILED=$((FAILED + 1)) ;;
    esac
}

echo "== helpers"
check "size_h 500 GB drive"   "465.8 GiB (500.1 GB)" "$(size_h 500107862016)"
check "size_h 1 TB drive"     "931.5 GiB (1.0 TB)"   "$(size_h 1000204886016)"
check "size_h zero"           "-"                    "$(size_h 0)"
check "size_s 8 GiB"          "8.0 GiB"              "$(size_s 8589934592)"
check "size_s kilobytes"      "512 KiB"              "$(size_s 524288)"
check "dv on empty"           "-"                    "$(dv "")"
check "dv on OEM filler"      "-"                    "$(dv 'To Be Filled By O.E.M.')"
check "dv custom fallback"    "hidden"               "$(dv "" hidden)"
check "dv empty fallback"     ""                     "$(dv "" "")"
check "dv passthrough"        "ASUSTeK"              "$(dv ASUSTeK)"
check "trim"                  "a b"                  "$(trim '   a b  ')"
check "pcie_gen gen3"         "Gen3"                 "$(pcie_gen '8.0 GT/s PCIe')"
check "pcie_gen gen4"         "Gen4"                 "$(pcie_gen '16.0 GT/s PCIe')"
check "pcie_gen unknown"      "-"                    "$(pcie_gen 'Unknown')"
check "pct_bar"               "[#####-----]  50%"    "$(pct_bar 50 10)"
check "pct_bar zero"          "[----------]   0%"    "$(pct_bar 0 10)"
check "pct_bar full"          "[##########] 100%"    "$(pct_bar 100 10)"

echo "== statistics"
printf '10\n20\n30\n40\n' > "$OS_TMP/s1"
check "stats even count"      "10.0 40.0 25.0 25.0 4"  "$(stats_calc "$OS_TMP/s1" 1 1)"
printf '5\n1\n3\n' > "$OS_TMP/s2"
check "stats odd count, unsorted" "1.0 5.0 3.0 3.0 3"  "$(stats_calc "$OS_TMP/s2" 1 1)"
printf '45000\n61500\n72400\n' > "$OS_TMP/s3"
check "stats millidegrees"    "45.0 72.4 59.6 61.5 3"  "$(stats_calc "$OS_TMP/s3" 1000 1)"
: > "$OS_TMP/s4"
check "stats empty file"      "- - - - 0"              "$(stats_calc "$OS_TMP/s4" 1000 1)"
printf 'garbage\n42\n' > "$OS_TMP/s5"
check "stats ignores garbage" "42.0 42.0 42.0 42.0 1"  "$(stats_calc "$OS_TMP/s5" 1 1)"

echo "== sparkline"
i=0; : > "$OS_TMP/spark"
while [ "$i" -lt 40 ]; do printf '%s\n' "$((i * 100))" >> "$OS_TMP/spark"; i=$((i + 1)); done
sp=$(sparkline "$OS_TMP/spark" 20)
check "sparkline width"       "20"                     "$(printf '%s' "$sp" | wc -c | tr -d ' ')"
check "sparkline rises"       "_"                      "$(printf '%s' "$sp" | cut -c1)"
check "sparkline peaks"       "@"                      "$(printf '%s' "$sp" | cut -c20)"
check "sparkline empty input" "(no samples)"           "$(sparkline "$OS_TMP/s4" 20)"

echo "== tables"
OS_COLS=80
t_head "TITLE" "COL A" "COL B" "COL C"
t_row "a" "bb" "ccc"
t_row "longer value here" "x" ""
t_row "with|pipe" "tab	inside" "ok"   # embedded tab must not add a column
out=$(t_end)
printf '%s\n' "$out" | sed 's/^/    /'
widths=$(printf '%s\n' "$out" | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')
check "every table line has the same width" "1" "$widths"
contains "header present"     "COL A"      "$out"
contains "empty cell becomes dash" "-"     "$out"
contains "header separator"   "+---"       "$out"

t_open "KV"
t_row "key" "value"
out2=$(t_end)
widths2=$(printf '%s\n' "$out2" | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')
check "kv table aligned"      "1" "$widths2"

# long values must wrap inside the table, never spill past the border and
# never silently disappear
OS_COLS=40
t_head "NARROW" "A" "B"
t_row "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
out3=$(t_end)
printf '%s\n' "$out3" | sed 's/^/    /'
maxlen=$(printf '%s\n' "$out3" | awk 'NF { if (length($0) > m) m = length($0) } END { print m }')
check "narrow table fits 40 cols" "1" "$([ "$maxlen" -le 40 ] && echo 1 || echo "0 (was $maxlen)")"
check "long value kept in full (48 a)" "48" "$(printf '%s' "$out3" | tr -cd 'a' | wc -c | tr -d ' ')"
check "second value kept in full (36 b)" "36" "$(printf '%s' "$out3" | tr -cd 'b' | wc -c | tr -d ' ')"
widths3=$(printf '%s\n' "$out3" | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')
check "wrapped rows stay aligned" "1" "$widths3"

# wrapping happens on word boundaries when there are any
OS_COLS=44
t_open "WRAPPED"
t_row "Verdict" "peak 97 C reached the 100 C limit, throttling or a dry cooler"
out6=$(t_end)
printf '%s\n' "$out6" | sed 's/^/    /'
contains "wraps on a word boundary" "throttling" "$out6"
check "no word was split" "0" "$(printf '%s\n' "$out6" | grep -c 'thrott[^l]' || true)"
widths6=$(printf '%s\n' "$out6" | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')
check "wrapped kv rows aligned" "1" "$widths6"

# a coloured value keeps its colour on every wrapped line
OS_COLS=40
Y=$(printf '\033[33m'); Z=$(printf '\033[0m')
t_open "WRAPCOLOUR"
t_row "Note" "${Y}this yellow sentence is long enough to need three separate lines${Z}"
out7=$(t_end)
nlines=$(printf '%s\n' "$out7" | grep -c "$(printf '\033')\[33m")
check "colour re-applied per wrapped line" "1" "$([ "$nlines" -ge 3 ] && echo 1 || echo "0 (was $nlines)")"
widths7=$(printf '%s\n' "$out7" | sed "s/${ESCCH}\\[[0-9;]*m//g" | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')
check "coloured wrapped rows aligned" "1" "$widths7"

# and a value that would wrap forever is still cut off eventually
OS_COLS=40
OS_T_MAXLINES=2
t_open "CAPPED"
t_row "K" "$(i=0; while [ $i -lt 60 ]; do printf 'word%s ' $i; i=$((i+1)); done)"
out8=$(t_end)
OS_T_MAXLINES=8
# 2 capped content lines plus the two borders
check "cell line cap respected" "4" "$(printf '%s\n' "$out8" | wc -l | tr -d ' ')"
contains "cap leaves a marker" "~" "$out8"

# colour escapes must not count towards the column width
OS_COLS=80
GREEN=$(printf '\033[32m'); RESET=$(printf '\033[0m'); BOLD=$(printf '\033[1m')
t_open "COLOURED"
t_row "plain" "healthy"
t_row "green" "${GREEN}healthy${RESET}"
t_row "long"  "${BOLD}a much longer coloured value${RESET}"
outc=$(t_end)
# strip the escapes, then every line must still be the same width
widthsc=$(printf '%s\n' "$outc" | sed "s/${ESCCH}\\[[0-9;]*m//g" \
    | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')
check "coloured cells stay aligned" "1" "$widthsc"

t_head "EMPTY" "A" "B"
out4=$(t_end)
contains "header only table says no data" "no data" "$out4"
OS_COLS=80

echo "== stats_row wiring"
t_head "M" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$OS_TMP/s3" 1000 "C" 1
stats_row "Missing" "$OS_TMP/nothere" 1000 "C" 1
out5=$(t_end)
printf '%s\n' "$out5" | sed 's/^/    /'
contains "min in column 2"    "45.0 C"  "$out5"
contains "max in column 3"    "72.4 C"  "$out5"
contains "avg in column 4"    "59.6 C"  "$out5"
contains "median in column 5" "61.5 C"  "$out5"
contains "sample count"       "3"       "$out5"

echo "== sensor discovery (fake sysfs tree)"
FAKE="$OS_TMP/sys"
mkdir -p "$FAKE/class/hwmon/hwmon0" "$FAKE/class/hwmon/hwmon1" \
         "$FAKE/class/thermal/thermal_zone0" \
         "$FAKE/class/powercap/intel-rapl:0" \
         "$FAKE/devices/system/cpu/cpu0/cpufreq" \
         "$FAKE/devices/system/cpu/cpu1/cpufreq" \
         "$FAKE/devices/system/cpu/cpu0/thermal_throttle" \
         "$FAKE/devices/system/cpu/cpu1/thermal_throttle"
# hwmon0 is an unrelated chip, hwmon1 is the CPU with a package sensor
echo nvme            > "$FAKE/class/hwmon/hwmon0/name"
echo 41000           > "$FAKE/class/hwmon/hwmon0/temp1_input"
echo coretemp        > "$FAKE/class/hwmon/hwmon1/name"
echo 'Core 0'        > "$FAKE/class/hwmon/hwmon1/temp2_label"
echo 61000           > "$FAKE/class/hwmon/hwmon1/temp2_input"
echo 'Package id 0'  > "$FAKE/class/hwmon/hwmon1/temp1_label"
echo 74000           > "$FAKE/class/hwmon/hwmon1/temp1_input"
echo 100000          > "$FAKE/class/hwmon/hwmon1/temp1_crit"
echo x86_pkg_temp    > "$FAKE/class/thermal/thermal_zone0/type"
echo 70000           > "$FAKE/class/thermal/thermal_zone0/temp"
echo 123456789       > "$FAKE/class/powercap/intel-rapl:0/energy_uj"
echo 4200000         > "$FAKE/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
echo 3800000         > "$FAKE/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
echo 7               > "$FAKE/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count"
echo 5               > "$FAKE/devices/system/cpu/cpu1/thermal_throttle/core_throttle_count"

OS_SYSFS="$FAKE"
CPU_TEMP_PATH=''; CPU_TEMP_LABEL=''
os_find_cpu_temp
check "picks the CPU package sensor" "$FAKE/class/hwmon/hwmon1/temp1_input" "$CPU_TEMP_PATH"
check "sensor label"          "coretemp/Package id 0" "$CPU_TEMP_LABEL"
check "reads temperature"     "74000"                 "$(cpu_temp_mc)"
check "averages cpu clocks"   "4000000"               "$(cpu_freq_khz)"
check "sums throttle counters" "12"                   "$(cpu_throttle_count)"
os_find_rapl
check "finds the RAPL counter" "$FAKE/class/powercap/intel-rapl:0/energy_uj" "$RAPL_PATH"
check "reads RAPL energy"     "123456789"             "$(rapl_uj)"

# thermal_zone fallback when no hwmon chip matches
rm -f "$FAKE/class/hwmon/hwmon1/name"
echo somethingelse > "$FAKE/class/hwmon/hwmon1/name"
rm -f "$FAKE/class/hwmon/hwmon0/temp1_input" "$FAKE/class/hwmon/hwmon1/temp1_input"
CPU_TEMP_PATH=''; CPU_TEMP_LABEL=''
os_find_cpu_temp
check "falls back to thermal_zone" "$FAKE/class/thermal/thermal_zone0/temp" "$CPU_TEMP_PATH"
check "reads fallback temp"   "70000" "$(cpu_temp_mc)"

# no sensors at all must not explode
OS_SYSFS="$OS_TMP/none"
CPU_TEMP_PATH=''; CPU_TEMP_LABEL=''; RAPL_PATH=''
os_find_cpu_temp || true
check "no sensor -> empty path" "" "$CPU_TEMP_PATH"
check "no sensor -> empty temp" "" "$(cpu_temp_mc)"
check "no cpufreq -> empty"     "" "$(cpu_freq_khz)"
check "no throttle files -> 0"  "0" "$(cpu_throttle_count)"
os_find_rapl || true
check "no rapl -> empty"        "" "$RAPL_PATH"
OS_SYSFS=/sys

echo "== distro / package mapping"
os_detect_distro
contains "package manager detected" "$PKG" "apt apk dnf yum pacman zypper"
check "pkg_for smartctl"      "smartmontools" "$(pkg_for smartctl)"
check "pkg_for lspci"         "pciutils"      "$(pkg_for lspci)"
case "$PKG" in
    apt|apk) check "pkg_for sensors" "lm-sensors" "$(pkg_for sensors)" ;;
    dnf|yum|pacman) check "pkg_for sensors" "lm_sensors" "$(pkg_for sensors)" ;;
esac

echo "== dmidecode record parser"
dmi_fields() { # exercised with canned output instead of real dmidecode
    awk -v keys="$2" '
    function flush() {
        if (inr && got) {
            out = ""
            for (i=1; i<=nk; i++) out = out (i>1 ? "\t" : "") V[K[i]]
            print out
        }
        inr = 0; got = 0; delete V
    }
    BEGIN { nk = split(keys, K, "|") }
    /^Handle / { flush(); inr = 1; next }
    inr && /^[ \t]/ {
        line = $0
        sub(/^[ \t]+/, "", line)
        p = index(line, ": ")
        if (p > 0) { V[substr(line, 1, p-1)] = substr(line, p+2); got = 1 }
    }
    END { flush() }' "$1"
}
cat > "$OS_TMP/dmi" <<'DMI'
# dmidecode 3.5
Getting SMBIOS data from sysfs.

Handle 0x0040, DMI type 17, 92 bytes
Memory Device
	Array Handle: 0x003E
	Size: 8 GB
	Form Factor: DIMM
	Locator: DIMM_A1
	Bank Locator: BANK 0
	Type: DDR4
	Type Detail: Synchronous Unbuffered (Unregistered)
	Speed: 3200 MT/s
	Manufacturer: Samsung
	Part Number: M378A1K43EB2-CWE
	Rank: 1
	Configured Memory Speed: 2666 MT/s

Handle 0x0042, DMI type 17, 92 bytes
Memory Device
	Array Handle: 0x003E
	Size: No Module Installed
	Form Factor: Unknown
	Locator: DIMM_B1
	Type: Unknown
DMI
res=$(dmi_fields "$OS_TMP/dmi" 'Locator|Size|Type|Configured Memory Speed|Manufacturer|Part Number')
check "dmi record count"   "2" "$(printf '%s\n' "$res" | wc -l | tr -d ' ')"
check "dmi first record"   "DIMM_A1	8 GB	DDR4	2666 MT/s	Samsung	M378A1K43EB2-CWE" "$(printf '%s\n' "$res" | sed -n 1p)"
check "dmi empty slot"     "DIMM_B1	No Module Installed	Unknown			" "$(printf '%s\n' "$res" | sed -n 2p)"

printf '\n'
if [ "$FAILED" = "0" ]; then
    printf 'all library self tests passed (%s)\n' "$(readlink -f "$LIB" 2>/dev/null || echo "$LIB")"
    exit 0
fi
printf '%s check(s) FAILED\n' "$FAILED"
exit 1
