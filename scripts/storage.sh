#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        storage
#@title       Storage health (SMART)
#@description Capacity, power-on hours, wear / lifespan left, reallocated sectors, read speed
#@root        required
#@params      speed
#@include _lib.sh

os_init "storage"

SPEED=${SPEED:-1}          # 0 disables the sequential read check
SPEED_MB=${SPEED_MB:-512}  # MiB read per device for the speed check

if [ "$OS_ROOT" != "1" ]; then
    err "SMART data cannot be read without root."
    note "run:  curl -fsSL $(os_url /storage.sh) | sudo sh"
    exit 1
fi

HAS_SMART=0
ensure_cmd smartctl && HAS_SMART=1
[ "$HAS_SMART" = "1" ] || warn "smartctl unavailable - falling back to sysfs only"
ensure_cmd nvme >/dev/null 2>&1 || true

# ------------------------------------------------------------ parsers
sm_field() { # file label -> value
    awk -v k="$2" '{
        p = index($0, ":")
        if (p < 1) next
        key = substr($0, 1, p-1)
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        if (key == k) { v = substr($0, p+1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
    }' "$1"
}
sm_attr_val() { awk -v id="$2" '$1 == id && NF >= 10 { print $4 + 0; exit }' "$1"; }
sm_attr_raw() { awk -v id="$2" '$1 == id && NF >= 10 { print $10 + 0; exit }' "$1"; }
sm_has_attr() { awk -v id="$2" '$1 == id && NF >= 10 { f = 1 } END { exit !f }' "$1"; }

# grab the "[12.8 TB]" part of an NVMe counter if present
brackets() {
    case "$1" in
        *'['*']'*) printf '%s' "$1" | sed -e 's/.*\[//' -e 's/\].*//' ;;
        *) printf '%s' "$1" ;;
    esac
}

collect_smart() { # device -> writes $OS_TMP/sm, echoes the -d type used
    _dev="$1"
    for _t in auto sat scsi nvme; do
        if $SUDO smartctl -x -d "$_t" "$_dev" > "$OS_TMP/sm" 2>/dev/null; then
            if grep -q 'START OF INFORMATION\|Model Number\|Device Model\|Vendor:' "$OS_TMP/sm"; then
                printf '%s' "$_t"; return 0
            fi
        fi
    done
    : > "$OS_TMP/sm"
    return 1
}

read_speed() { # device -> "MB/s" using a short direct read, or "-"
    _dev="$1"
    [ "$SPEED" = "1" ] || { printf '%s' "skipped"; return; }
    if dd if="$_dev" of=/dev/null bs=1M count=1 iflag=direct 2>/dev/null; then
        _out=$($SUDO dd if="$_dev" of=/dev/null bs=1M count="$SPEED_MB" iflag=direct 2>&1)
        printf '%s' "$_out" | awk '
            /copied|bytes/ {
                for (i=1; i<=NF; i++) if ($i ~ /^[0-9.]+$/ && ($(i+1) == "MB/s" || $(i+1) == "GB/s")) {
                    if ($(i+1) == "GB/s") printf "%.0f MB/s\n", $i * 1000; else printf "%.0f MB/s\n", $i
                    exit
                }
            }
            END { }'
    elif have hdparm; then
        $SUDO hdparm -t --direct "$_dev" 2>/dev/null | awk '/MB\/sec/ { printf "%.0f MB/s\n", $(NF-1) }'
    else
        printf '%s' "-"
    fi
}

# ======================================================================
#  enumerate devices
# ======================================================================
: > "$OS_TMP/devs"
for b in /sys/block/*; do
    [ -d "$b" ] || continue
    name=${b##*/}
    case "$name" in loop*|ram*|zram*|dm-*|md*|sr*|fd*) continue ;; esac
    sectors=$(rd "$b/size")
    [ -z "$sectors" ] || [ "$sectors" = "0" ] && continue
    printf '%s\n' "$name" >> "$OS_TMP/devs"
done

if [ ! -s "$OS_TMP/devs" ]; then
    err "no block devices found"
    os_footer
    exit 1
fi

: > "$OS_TMP/summary"

# ======================================================================
#  per device detail
# ======================================================================
while read -r name; do
    dev="/dev/$name"
    b="/sys/block/$name"
    sectors=$(rd "$b/size"); bytes=$((sectors * 512))
    rota=$(rd "$b/queue/rotational")
    lbs=$(rd "$b/queue/logical_block_size")
    pbs=$(rd "$b/queue/physical_block_size")
    sysmodel=$(trim "$(rd "$b/device/vendor") $(rd "$b/device/model")")

    hdr "DEVICE $dev"

    dtype=''
    if [ "$HAS_SMART" = "1" ]; then
        dtype=$(collect_smart "$dev") || true
    else
        : > "$OS_TMP/sm"
    fi

    is_nvme=0
    case "$name" in nvme*) is_nvme=1 ;; esac

    model=$(sm_field "$OS_TMP/sm" 'Device Model')
    [ -z "$model" ] && model=$(sm_field "$OS_TMP/sm" 'Model Number')
    [ -z "$model" ] && model=$(sm_field "$OS_TMP/sm" 'Product')
    [ -z "$model" ] && model="$sysmodel"
    serial=$(sm_field "$OS_TMP/sm" 'Serial Number')
    [ -z "$serial" ] && serial=$(rd "$b/device/serial")
    fw=$(sm_field "$OS_TMP/sm" 'Firmware Version')
    [ -z "$fw" ] && fw=$(rd "$b/device/firmware_rev")
    family=$(sm_field "$OS_TMP/sm" 'Model Family')
    rotrate=$(sm_field "$OS_TMP/sm" 'Rotation Rate')
    formf=$(sm_field "$OS_TMP/sm" 'Form Factor')
    satav=$(sm_field "$OS_TMP/sm" 'SATA Version is')
    health=$(sm_field "$OS_TMP/sm" 'SMART overall-health self-assessment test result')
    [ -z "$health" ] && health=$(sm_field "$OS_TMP/sm" 'SMART Health Status')
    trim=$(sm_field "$OS_TMP/sm" 'TRIM Command')
    smart_en=$(sm_field "$OS_TMP/sm" 'SMART support is')

    # ---- kind
    if [ "$is_nvme" = "1" ]; then kind="SSD (NVMe)"
    elif [ "$rota" = "0" ]; then kind="SSD (SATA)"
    else kind="HDD"; fi

    # ---- lifetime / wear
    life='-'; life_src='-'
    poh='-'; pcc='-'; temp='-'; written='-'; read_tot='-'
    realloc='-'; pending='-'; uncorr='-'; crc='-'; spare='-'; unsafe='-'; interr='-'

    if [ "$is_nvme" = "1" ]; then
        pu=$(sm_field "$OS_TMP/sm" 'Percentage Used')
        case "$pu" in
            *%) pu=${pu%\%}
                life=$((100 - pu)); life_src="NVMe Percentage Used ($pu% consumed)" ;;
        esac
        spare=$(sm_field "$OS_TMP/sm" 'Available Spare')
        poh=$(sm_field "$OS_TMP/sm" 'Power On Hours')
        pcc=$(sm_field "$OS_TMP/sm" 'Power Cycles')
        temp=$(sm_field "$OS_TMP/sm" 'Temperature')
        written=$(brackets "$(sm_field "$OS_TMP/sm" 'Data Units Written')")
        read_tot=$(brackets "$(sm_field "$OS_TMP/sm" 'Data Units Read')")
        unsafe=$(sm_field "$OS_TMP/sm" 'Unsafe Shutdowns')
        interr=$(sm_field "$OS_TMP/sm" 'Media and Data Integrity Errors')
        cw=$(sm_field "$OS_TMP/sm" 'Critical Warning')
        [ -z "$health" ] && [ -n "$cw" ] && {
            case "$cw" in 0x00|0) health="PASSED" ;; *) health="WARNING $cw" ;; esac
        }
        # nvme-cli fallback for the wear figure
        if [ "$life" = "-" ] && have nvme; then
            pu=$($SUDO nvme smart-log "$dev" 2>/dev/null | awk -F: '/percentage_used/{gsub(/[ %]/,"",$2); print $2; exit}')
            case "$pu" in ''|*[!0-9]*) : ;; *) life=$((100 - pu)); life_src="nvme smart-log percentage_used" ;; esac
        fi
    else
        poh=$(sm_attr_raw "$OS_TMP/sm" 9)
        pcc=$(sm_attr_raw "$OS_TMP/sm" 12)
        realloc=$(sm_attr_raw "$OS_TMP/sm" 5)
        pending=$(sm_attr_raw "$OS_TMP/sm" 197)
        uncorr=$(sm_attr_raw "$OS_TMP/sm" 198)
        crc=$(sm_attr_raw "$OS_TMP/sm" 199)
        tr=$(sm_attr_raw "$OS_TMP/sm" 194)
        [ -z "$tr" ] && tr=$(sm_attr_raw "$OS_TMP/sm" 190)
        [ -n "$tr" ] && temp="$tr C"
        lba=$(sm_attr_raw "$OS_TMP/sm" 241)
        if [ -n "$lba" ] && [ "$lba" != "0" ]; then
            written=$(size_s $((lba * 512)))
        fi
        lbar=$(sm_attr_raw "$OS_TMP/sm" 242)
        [ -n "$lbar" ] && [ "$lbar" != "0" ] && read_tot=$(size_s $((lbar * 512)))
        if [ "$rota" != "1" ]; then
            for pair in "231:SSD_Life_Left" "202:Percent_Lifetime_Remain" "233:Media_Wearout_Indicator" "177:Wear_Leveling_Count" "173:Wear_Leveling_Count"; do
                aid=${pair%%:*}; anm=${pair#*:}
                if sm_has_attr "$OS_TMP/sm" "$aid"; then
                    v=$(sm_attr_val "$OS_TMP/sm" "$aid")
                    case "$v" in ''|*[!0-9]*) continue ;; esac
                    [ "$v" -gt 100 ] && continue
                    life="$v"; life_src="SMART attr $aid $anm (normalised value)"
                    break
                fi
            done
        fi
    fi

    spd=$(read_speed "$dev")
    [ -z "$spd" ] && spd='-'

    # ---- verdict
    verdict="ok"; vcol="$CG"
    case "$health" in
        *FAILED*|*FAILING*|*WARNING*|*Bad*) verdict="SMART reports a problem"; vcol="$CE" ;;
    esac
    if [ "$verdict" = "ok" ]; then
        case "$realloc" in ''|-|0) ;; *) verdict="$realloc reallocated sector(s)"; vcol="$CE" ;; esac
    fi
    if [ "$verdict" = "ok" ]; then
        case "$pending" in ''|-|0) ;; *) verdict="$pending pending sector(s)"; vcol="$CE" ;; esac
    fi
    if [ "$verdict" = "ok" ] && [ "$life" != "-" ]; then
        if [ "$life" -lt 20 ] 2>/dev/null; then verdict="only ${life}% wear life left"; vcol="$CE"
        elif [ "$life" -lt 50 ] 2>/dev/null; then verdict="${life}% wear life left"; vcol="$CY"; fi
    fi
    if [ "$verdict" = "ok" ] && [ "$poh" != "-" ]; then
        pohn=$(printf '%s' "$poh" | tr -cd '0-9')
        case "$pohn" in
            ''|*[!0-9]*) ;;
            *) if [ "$pohn" -gt 40000 ]; then verdict="heavily used ($pohn h)"; vcol="$CY"
               elif [ "$pohn" -gt 20000 ]; then verdict="well used ($pohn h)"; vcol="$CY"; fi ;;
        esac
    fi

    t_open "IDENTITY $dev"
    t_row "Model"          "$(dv "$model")"
    t_row "Family"         "$(dv "$family")"
    t_row "Serial"         "$(dv "$serial")"
    t_row "Firmware"       "$(dv "$fw")"
    t_row "Kind"           "$kind"
    t_row "Capacity"       "$(size_h "$bytes")"
    t_row "Sector size"    "$(dv "$lbs") logical / $(dv "$pbs") physical"
    t_row "Rotation"       "$(dv "$rotrate")"
    t_row "Form factor"    "$(dv "$formf")"
    t_row "Interface"      "$(dv "$satav" "$([ "$is_nvme" = 1 ] && echo NVMe || echo '-')")"
    t_row "TRIM"           "$(dv "$trim")"
    t_row "SMART support"  "$(dv "$smart_en" "$([ "$HAS_SMART" = 1 ] && echo 'not reported' || echo 'smartctl missing')")"
    t_row "smartctl -d"    "$(dv "$dtype")"
    t_end

    t_open "HEALTH $dev"
    hcol="$CG"
    case "$health" in *PASSED*|*OK*) hcol="$CG" ;; '') hcol="$CD" ;; *) hcol="$CE" ;; esac
    t_row "SMART overall health" "${hcol}$(dv "$health")${CR}"
    if [ "$life" != "-" ]; then
        lcol="$CG"
        [ "$life" -lt 50 ] 2>/dev/null && lcol="$CY"
        [ "$life" -lt 20 ] 2>/dev/null && lcol="$CE"
        t_row "Lifespan left"  "${lcol}$(pct_bar "$life" 20)${CR}"
        t_row "  source"       "$life_src"
    else
        t_row "Lifespan left"  "n/a $CD(mechanical drive or no wear attribute)$CR"
    fi
    [ "$spare" != "-" ] && t_row "Available spare" "$(dv "$spare")"
    t_row "Power-on hours"     "$(dv "$poh")"
    t_row "Power cycles"       "$(dv "$pcc")"
    t_row "Temperature"        "$(dv "$temp")"
    t_row "Data written"       "$(dv "$written")"
    t_row "Data read"          "$(dv "$read_tot")"
    [ "$is_nvme" = "1" ] && t_row "Unsafe shutdowns" "$(dv "$unsafe")"
    [ "$is_nvme" = "1" ] && t_row "Integrity errors" "$(dv "$interr")"
    if [ "$is_nvme" != "1" ]; then
        t_row "Reallocated sectors" "$(dv "$realloc")"
        t_row "Pending sectors"     "$(dv "$pending")"
        t_row "Offline uncorrectable" "$(dv "$uncorr")"
        t_row "UDMA CRC errors"     "$(dv "$crc")"
    fi
    t_row "Sequential read"    "$(dv "$spd")"
    t_row "Verdict"            "${vcol}${verdict}${CR}"
    t_end

    # self-test log is a good "was it abused" signal
    if [ -s "$OS_TMP/sm" ]; then
        selftest=$(awk '/Self-test log|Self-test Log/{f=1} f && /# *1|Num  Test/{print; c++} c>3{exit}' "$OS_TMP/sm" | head -4)
        if [ -n "$selftest" ]; then
            t_open "LAST SELF-TESTS $dev"
            printf '%s\n' "$selftest" | while IFS= read -r l; do t_row "$(trim "$l")"; done
            t_end
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$dev" "$(dv "$model")" "$(size_s "$bytes")" "$kind" \
        "$([ "$life" != "-" ] && echo "${life}%" || echo "-")" \
        "$(dv "$poh")" "$(dv "$health")" "$verdict" >> "$OS_TMP/summary"
done < "$OS_TMP/devs"

# ======================================================================
#  summary
# ======================================================================
hdr "SUMMARY"
t_head "ALL DRIVES" "DEVICE" "MODEL" "SIZE" "KIND" "LIFE LEFT" "HOURS" "SMART" "VERDICT"
while IFS="$TAB" read -r a b c d e f g h; do t_row "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h"; done < "$OS_TMP/summary"
t_note "'LIFE LEFT' is the vendor wear estimate; HOURS is total power-on time"
t_note "reallocated / pending sectors on an HDD or <20% life on an SSD => walk away"
t_end

os_footer
