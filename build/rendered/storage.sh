#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        storage
#@title       Storage health (SMART)
#@description Capacity, power-on hours, wear / lifespan left, reallocated sectors, read speed
#@root        required
#@params      speed
# shellcheck shell=sh disable=SC2086,SC2181,SC3043
# ======================================================================
#  online-script :: shared library
#  The server splices this file into every script it serves (see the
#  include directive in each one), so a served script is self-contained.
#  POSIX sh only (must run under dash, ash/busybox and bash).
# ======================================================================

OS_BASE_URL="http://localhost:8080"
OS_TOKEN_Q=""
OS_VERSION="1.0.0"

TAB=$(printf '\t')
OS_FS=$(printf '\001')   # table column separator (never appears in hw strings)

# ------------------------------------------------------------ scratch dir
OS_TMP="${TMPDIR:-/tmp}/onlinescript.$$"
if ! mkdir -p "$OS_TMP" 2>/dev/null; then
    echo "FATAL: cannot create temp dir $OS_TMP" >&2
    exit 1
fi
os_cleanup() { [ -n "$OS_TMP" ] && rm -rf "$OS_TMP" 2>/dev/null; }
trap 'os_cleanup' EXIT
trap 'os_cleanup; exit 130' INT
trap 'os_cleanup; exit 143' TERM

# ---------------------------------------------------------------- colours
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${PLAIN:-0}" != "1" ]; then
    CB=$(printf '\033[1m')      # bold
    CD=$(printf '\033[2m')      # dim
    CR=$(printf '\033[0m')      # reset
    CC=$(printf '\033[36m')     # cyan   (borders)
    CG=$(printf '\033[32m')     # green  (good)
    CY=$(printf '\033[33m')     # yellow (warn)
    CE=$(printf '\033[31m')     # red    (bad)
else
    CB= ; CD= ; CR= ; CC= ; CG= ; CY= ; CE=
fi

# ------------------------------------------------------- box drawing set
case "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) OS_UNI=1 ;;
    *) OS_UNI=0 ;;
esac
[ "${PLAIN:-0}" = "1" ] && OS_UNI=0
if [ "$OS_UNI" = "1" ]; then
    B_TL='+' ; B_TR='+' ; B_BL='+' ; B_BR='+'
    B_TL=$(printf '\342\225\255')   # top-left round
    B_TR=$(printf '\342\225\256')
    B_BL=$(printf '\342\225\260')
    B_BR=$(printf '\342\225\257')
    B_H=$(printf '\342\224\200')
    B_V=$(printf '\342\224\202')
    B_ML=$(printf '\342\224\234')
    B_MR=$(printf '\342\224\244')
    B_EQ=$(printf '\342\225\220')
else
    B_TL='+' ; B_TR='+' ; B_BL='+' ; B_BR='+'
    B_H='-'  ; B_V='|'  ; B_ML='+' ; B_MR='+' ; B_EQ='='
fi

# ------------------------------------------------------- terminal width
have() { command -v "$1" >/dev/null 2>&1; }

# "curl | sh" leaves stdin pointing at the pipe, so the window size has to
# come from stdout (tput) or from the controlling terminal (/dev/tty).
os_term_width() {
    _w=''
    if have tput; then
        _w=$(tput cols 2>/dev/null)
        case "$_w" in ''|*[!0-9]*) _w='' ;; esac
    fi
    if [ -z "$_w" ] && have stty; then
        _w=$(stty size 2>/dev/null < /dev/tty | awk '{ print $2 }')
        case "$_w" in ''|*[!0-9]*) _w='' ;; esac
    fi
    [ -z "$_w" ] && _w=${COLUMNS:-}
    case "$_w" in ''|*[!0-9]*) _w=120 ;; esac        # unknown: assume roomy
    [ "$_w" -lt 40 ] && _w=120                       # bogus reading
    [ "$_w" -gt 220 ] && _w=220                      # very wide is hard to read
    printf '%s' "$_w"
}

# COLS=200 (or ?cols=200 on the URL) overrides the detected width
OS_COLS=${COLS:-$(os_term_width)}
case "$OS_COLS" in ''|*[!0-9]*) OS_COLS=120 ;; esac
[ "$OS_COLS" -lt 40 ] && OS_COLS=40
[ "$OS_COLS" -gt 400 ] && OS_COLS=400

# ====================================================================
#  tiny helpers
# ====================================================================
# read first line of a sysfs/proc file without spawning a process
# NOTE: stderr is redirected *before* the input redirection on purpose - a
# sysfs file can pass "test -r" and still fail to open (e.g. root-only DMI
# fields inside a rootless container), and the shell would print that itself.
rd() {
    _v=''
    [ -r "$1" ] || { printf ''; return 1; }
    read -r _v 2>/dev/null < "$1" || true
    printf '%s' "$_v"
}

# read whole file, newlines squashed to spaces
rdall() { [ -r "$1" ] || return 1; tr '\n' ' ' 2>/dev/null < "$1"; }

# default a value to "-" when empty / unknown
dv() {
    case "$1" in
        ''|'Unknown'|'unknown'|'To Be Filled By O.E.M.'|'To be filled by O.E.M.'|\
        'Not Specified'|'None'|'Default string'|'System manufacturer'|'0x0000'|'N/A'|\
        'System Product Name'|'System Version'|'Filled by OEM.')
            printf '%s' "${2--}" ;;
        *) printf '%s' "$1" ;;
    esac
}

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# 1024-based + decimal size from a byte count -> "465.8 GiB (500.1 GB)"
size_h() {
    awk -v b="$1" 'BEGIN{
        if (b+0 <= 0) { print "-"; exit }
        split("B KiB MiB GiB TiB PiB", u, " ");
        i=1; x=b; while (x>=1024 && i<6) { x/=1024; i++ }
        split("B KB MB GB TB PB", d, " ");
        j=1; y=b; while (y>=1000 && j<6) { y/=1000; j++ }
        if (i==1) printf "%d B\n", b;
        else printf "%.1f %s (%.1f %s)\n", x, u[i], y, d[j];
    }'
}

# plain 1024-based size, no decimal twin
size_s() {
    awk -v b="$1" 'BEGIN{
        if (b+0 <= 0) { print "-"; exit }
        split("B KiB MiB GiB TiB PiB", u, " ");
        i=1; while (b>=1024 && i<6) { b/=1024; i++ }
        if (i<=2) printf "%d %s\n", b, u[i]; else printf "%.1f %s\n", b, u[i];
    }'
}

# horizontal percentage bar:  pct_bar 72 20 -> [##############------]  72%
pct_bar() {
    awk -v p="$1" -v w="${2:-16}" 'BEGIN{
        if (p == "" || p+0 != p) { print "-"; exit }
        n = int(p*w/100 + 0.5); if (n<0) n=0; if (n>w) n=w;
        s="["; for (i=0;i<n;i++) s=s "#"; for (i=n;i<w;i++) s=s "-";
        printf "%s] %3d%%\n", s, p;
    }'
}

# printable URL for a script; quoted when it carries a token, so it survives
# being pasted into zsh as well as bash
os_url() {
    if [ -n "$OS_TOKEN_Q" ]; then
        printf "'%s%s%s'" "$OS_BASE_URL" "$1" "$OS_TOKEN_Q"
    else
        printf '%s%s' "$OS_BASE_URL" "$1"
    fi
}

# wrap free text to the terminal, with a hanging indent
#   os_wrap <first-indent> <continuation-indent> <colour> <text...>
os_wrap() {
    _i1="$1"; _i2="$2"; _c="$3"; shift 3
    awk -v i1="$_i1" -v i2="$_i2" -v col="$_c" -v rst="$CR" -v w="$OS_COLS" -v s="$*" '
    BEGIN {
        width = w - length(i2); if (width < 20) width = 20
        n = split(s, a, " "); line = ""; first = 1
        for (i = 1; i <= n; i++) {
            if (line == "") line = a[i]
            else if (length(line) + 1 + length(a[i]) <= width) line = line " " a[i]
            else { print col (first ? i1 : i2) line rst; first = 0; line = a[i] }
        }
        if (line != "" || first) print col (first ? i1 : i2) line rst
    }'
}

msg()   { printf '%s\n' "$*"; }
note()  { os_wrap "  "    "  "    "$CD" "$*"; }
warn()  { os_wrap "  ! "  "    "  "$CY" "$*"; }
err()   { os_wrap "  x "  "    "  "$CE" "$*"; }
step()  { os_wrap "  .. " "     " "$CD" "$*"; }

# section heading (between tables)
hdr() { printf '\n%s%s%s\n' "$CB$CC" "$*" "$CR"; }

rule() { awk -v w="$OS_COLS" -v ch="$B_EQ" -v c="$CC" -v r="$CR" 'BEGIN{s="";for(i=0;i<w;i++)s=s ch; print c s r}'; }

# ====================================================================
#  table rendering
#     t_head "TITLE" col1 col2 ...     table with a header row
#     t_open "TITLE"                   table without header (key/value)
#     t_row  v1 v2 ...
#     t_end
# ====================================================================
OS_T_TITLE=''
OS_T_HDR=0

t_head() {
    OS_T_TITLE="$1"; shift
    : > "$OS_TMP/t"
    OS_T_HDR=1
    t_row "$@"
}

t_open() {
    OS_T_TITLE="$1"
    : > "$OS_TMP/t"
    OS_T_HDR=0
}

t_row() {
    _r=''; _first=1
    for _f in "$@"; do
        if [ "$_first" = 1 ]; then _r="$_f"; _first=0; else _r="$_r$OS_FS$_f"; fi
    done
    # one row must stay one line, and a stray tab must not split a cell
    _r=$(printf '%s' "$_r" | tr '\r\n\t' '   ')
    printf '%s\n' "$_r" >> "$OS_TMP/t"
}

# footnote printed under the table currently being built (or right away if
# no table is open)
t_note() {
    if [ -s "$OS_TMP/t" ]; then
        os_wrap "    " "    " "$CD" "$*" >> "$OS_TMP/n"
    else
        os_wrap "    " "    " "$CD" "$*"
    fi
}

t_end() {
    awk -v title="$OS_T_TITLE" -v hdr="$OS_T_HDR" -v maxw="$OS_COLS" \
        -v TL="$B_TL" -v TR="$B_TR" -v BL="$B_BL" -v BR="$B_BR" \
        -v H="$B_H" -v V="$B_V" -v ML="$B_ML" -v MR="$B_MR" \
        -v CB="$CB" -v CR="$CR" -v CC="$CC" -v CD="$CD" \
        -v ESC="$(printf '\033')" -v maxlines="${OS_T_MAXLINES:-8}" '
    function rep(s, n,   o, i) { o=""; for (i=0; i<n; i++) o = o s; return o }
    # cells may carry colour escapes, which take no space on screen
    function strip(s) { gsub(ESC "\\[[0-9;]*m", "", s); return s }
    function vislen(s) { return length(strip(s)) }
    # longest single word: shrinking a column past this splits a word in half
    function maxword(s,   words, n, i, m) {
        n = split(strip(s), words, " "); m = 0
        for (i=1; i<=n; i++) if (length(words[i]) > m) m = length(words[i])
        return m
    }

    # Split a cell over as many lines as it needs instead of cutting it off.
    # A colour that wraps the whole cell is re-applied to every line.
    function wrap(s, width, out,   pre, post, words, n, i, k, word, line, cnt) {
        delete out
        pre = ""; post = ""
        while (match(s, "^" ESC "\\[[0-9;]*m")) {
            pre = pre substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
        }
        while (match(s, ESC "\\[[0-9;]*m$")) {
            post = substr(s, RSTART) post; s = substr(s, 1, RSTART - 1)
        }
        s = strip(s)
        cnt = 0; line = ""
        n = split(s, words, " ")
        for (i = 1; i <= n; i++) {
            word = words[i]
            while (length(word) > width) {          # single unbreakable token
                if (line != "") { out[++cnt] = line; line = "" }
                out[++cnt] = substr(word, 1, width)
                word = substr(word, width + 1)
            }
            if (line == "") line = word
            else if (length(line) + 1 + length(word) <= width) line = line " " word
            else { out[++cnt] = line; line = word }
        }
        if (line != "" || cnt == 0) out[++cnt] = line
        if (cnt > maxlines) {                        # pathological value
            out[maxlines] = substr(out[maxlines], 1, width - 1) "~"
            for (k = maxlines + 1; k <= cnt; k++) delete out[k]
            cnt = maxlines
        }
        if (pre != "" || post != "")
            for (k = 1; k <= cnt; k++) out[k] = pre out[k] post
        return cnt
    }

    BEGIN { FS="\001"; gap=2; ncol=0; nrow=0 }
    {
        if (NF > ncol) ncol = NF
        for (i=1; i<=NF; i++) {
            v = $i
            sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
            if (v == "") v = "-"
            c[NR, i] = v
            if (vislen(v) > w[i]) w[i] = vislen(v)
            if (maxword(v) > mw[i]) mw[i] = maxword(v)
        }
        nrow = NR
    }
    END {
        tl = length(title)
        if (nrow == 0 || (hdr == 1 && nrow == 1)) {
            total = (tl > 10 ? tl : 10) + 2
            full = total + 4
            print CC TL H CR " " CB title CR " " CC rep(H, full-tl-5) TR CR
            print CC V CR " " CD "no data" CR rep(" ", total-7) " " CC V CR
            print CC BL rep(H, full-2) BR CR
            printf "\n"
            exit
        }
        for (i=1; i<=ncol; i++) if (w[i] < 1) w[i] = 1
        total = gap * (ncol-1)
        for (i=1; i<=ncol; i++) total += w[i]
        # Narrow the table until it fits. Prose columns give way first: a
        # column is only pushed below its longest word (splitting an address
        # or a part number in half) when nothing else can give.
        avail = maxw - 4
        while (total > avail) {
            b = 0; bi = 0
            for (i=1; i<=ncol; i++)
                if (w[i] > mw[i] && w[i] > b) { b = w[i]; bi = i }
            if (bi == 0) {
                for (i=1; i<=ncol; i++) if (w[i] > b) { b = w[i]; bi = i }
                if (b <= 12) break
            }
            w[bi]--; total--
        }
        if (total < tl + 2) { w[ncol] += (tl + 2 - total); total = tl + 2 }
        full = total + 4

        print CC TL H CR " " CB title CR " " CC rep(H, full-tl-5) TR CR
        for (r=1; r<=nrow; r++) {
            high = 1
            for (i=1; i<=ncol; i++) {
                v = c[r, i]; if (v == "") v = "-"
                nl[i] = wrap(v, w[i], seg)
                for (k=1; k<=nl[i]; k++) cell[i, k] = seg[k]
                if (nl[i] > high) high = nl[i]
            }
            for (k=1; k<=high; k++) {
                line = ""
                for (i=1; i<=ncol; i++) {
                    v = (k <= nl[i]) ? cell[i, k] : ""
                    line = line v rep(" ", w[i] - vislen(v))
                    if (i < ncol) line = line rep(" ", gap)
                }
                if (hdr == 1 && r == 1)
                    print CC V CR " " CB line CR " " CC V CR
                else
                    print CC V CR " " line " " CC V CR
            }
            if (hdr == 1 && r == 1) print CC ML rep(H, full-2) MR CR
        }
        print CC BL rep(H, full-2) BR CR
    }' "$OS_TMP/t"
    : > "$OS_TMP/t"
    if [ -s "$OS_TMP/n" ]; then
        cat "$OS_TMP/n"
        : > "$OS_TMP/n"
    fi
    printf '\n'
}

# ====================================================================
#  statistics  (samples are stored as integers -> divide at print time)
#     stats_row "Label" file divisor unit decimals
# ====================================================================
stats_calc() { # file divisor decimals -> "min max avg median count"
    sort -n "$1" 2>/dev/null | awk -v d="$2" -v dec="${3:-1}" '
        /^-?[0-9]+$/ { a[++n] = $1 }
        END {
            if (n == 0) { print "- - - - 0"; exit }
            mn = a[1]; mx = a[n]; s = 0
            for (i=1; i<=n; i++) s += a[i]
            if (n % 2) med = a[(n+1)/2]; else med = (a[n/2] + a[n/2+1]) / 2
            f = "%." dec "f"
            printf f " " f " " f " " f " %d\n", mn/d, mx/d, s/n/d, med/d, n
        }'
}

stats_row() { # label file divisor unit decimals
    _lbl="$1"; _f="$2"; _div="$3"; _unit="$4"; _dec="${5:-1}"
    [ -s "$_f" ] || { t_row "$_lbl" "-" "-" "-" "-" "-"; return; }
    # shellcheck disable=SC2046
    set -- $(stats_calc "$_f" "$_div" "$_dec")
    t_row "$_lbl" "$1 $_unit" "$2 $_unit" "$3 $_unit" "$4 $_unit" "$5"
}

# sparkline of a sample file (integers), width columns
sparkline() {
    awk -v w="${2:-60}" -v uni="$OS_UNI" '
    /^-?[0-9]+$/ { a[++n] = $1 }
    END {
        if (n == 0) { print "(no samples)"; exit }
        if (uni == 1) {
            split("\342\226\201 \342\226\202 \342\226\203 \342\226\204 \342\226\205 \342\226\206 \342\226\207 \342\226\210", L, " ")
        } else {
            split("_ . - = + * # @", L, " ")
        }
        mn = a[1]; mx = a[1]
        for (i=1; i<=n; i++) { if (a[i]<mn) mn=a[i]; if (a[i]>mx) mx=a[i] }
        if (mx == mn) mx = mn + 1
        if (n < w) w = n
        out = ""
        for (b=0; b<w; b++) {
            lo = int(b*n/w) + 1; hi = int((b+1)*n/w); if (hi < lo) hi = lo
            s = 0; k = 0
            for (i=lo; i<=hi; i++) { s += a[i]; k++ }
            v = s/k
            idx = int((v-mn) * 7 / (mx-mn) + 0.5) + 1
            if (idx < 1) idx = 1; if (idx > 8) idx = 8
            out = out L[idx]
        }
        print out
    }' "$1"
}

# ====================================================================
#  privilege + package management
# ====================================================================
SUDO=''
OS_ROOT=0
OS_INSTALLED=''
OS_MISSING=''
OS_PKG_REFRESHED=''
PKG=''
DISTRO_ID=''
DISTRO_LIKE=''
DISTRO_NAME=''

os_detect_priv() {
    if [ "$(id -u)" = "0" ]; then
        OS_ROOT=1; SUDO=''
    elif have sudo && sudo -n true 2>/dev/null; then
        OS_ROOT=1; SUDO='sudo -n'
    else
        OS_ROOT=0; SUDO=''
    fi
}

os_detect_distro() {
    if [ -r /etc/os-release ]; then
        DISTRO_ID=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
        DISTRO_LIKE=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")
        DISTRO_NAME=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-}}")
    fi
    [ -z "$DISTRO_NAME" ] && DISTRO_NAME="unknown Linux"

    case " $DISTRO_ID $DISTRO_LIKE " in
        *alpine*)                          PKG=apk ;;
        *debian*|*ubuntu*|*mint*|*pop*)    PKG=apt ;;
        *fedora*|*rhel*|*centos*|*almalinux*|*rocky*) PKG=dnf ;;
        *arch*|*manjaro*|*endeavouros*)    PKG=pacman ;;
        *suse*)                            PKG=zypper ;;
        *)                                 PKG='' ;;
    esac
    if [ -z "$PKG" ]; then   # fall back to whatever tool exists
        if   have apt-get; then PKG=apt
        elif have apk;     then PKG=apk
        elif have dnf;     then PKG=dnf
        elif have yum;     then PKG=yum
        elif have pacman;  then PKG=pacman
        elif have zypper;  then PKG=zypper
        fi
    fi
    [ "$PKG" = dnf ] && ! have dnf && have yum && PKG=yum
}

# package name for a given command, per package manager
pkg_for() {
    case "$1" in
        dmidecode)   echo dmidecode ;;
        lspci|setpci) echo pciutils ;;
        lsusb)       echo usbutils ;;
        lscpu|lsblk|findmnt)
            case "$PKG" in apk) echo "util-linux" ;; *) echo util-linux ;; esac ;;
        smartctl)    echo smartmontools ;;
        nvme)        echo nvme-cli ;;
        hdparm)      echo hdparm ;;
        ethtool)     echo ethtool ;;
        ip)          echo iproute2 ;;
        sensors)
            case "$PKG" in
                apt|apk) echo lm-sensors ;;
                dnf|yum|pacman) echo lm_sensors ;;
                zypper) echo sensors ;;
                *) echo lm-sensors ;;
            esac ;;
        stress-ng)   echo stress-ng ;;
        glmark2)     echo glmark2 ;;
        glmark2-es2-drm|glmark2-drm)
            case "$PKG" in apt) echo glmark2-drm ;; *) echo glmark2 ;; esac ;;
        vkmark)      echo vkmark ;;
        clpeak)      echo clpeak ;;
        clinfo)      echo clinfo ;;
        mokutil)     echo mokutil ;;
        decode-dimms) echo i2c-tools ;;
        lshw)        echo lshw ;;
        fio)         echo fio ;;
        *)           echo "$1" ;;
    esac
}

pkg_refresh() {
    [ -n "$OS_PKG_REFRESHED" ] && return 0
    OS_PKG_REFRESHED=1
    case "$PKG" in
        apt)    step "refreshing package index (apt-get update)"
                $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true ;;
        apk)    step "refreshing package index (apk update)"
                $SUDO apk update -q >/dev/null 2>&1 || true ;;
        pacman) step "refreshing package index (pacman -Sy)"
                $SUDO pacman -Syq --noconfirm >/dev/null 2>&1 || true ;;
        *)      : ;;
    esac
}

pkg_install() {
    case "$PKG" in
        apt)    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                    -o Dpkg::Use-Pty=0 "$@" ;;
        apk)    $SUDO apk add --no-cache -q "$@" ;;
        dnf)    $SUDO dnf install -y -q "$@" ;;
        yum)    $SUDO yum install -y -q "$@" ;;
        pacman) $SUDO pacman -S --noconfirm --needed -q "$@" ;;
        zypper) $SUDO zypper --non-interactive --quiet install "$@" ;;
        *)      return 1 ;;
    esac
}

# ensure_cmd <command> [package]   -> 0 if the command is usable afterwards
ensure_cmd() {
    _cmd="$1"
    have "$_cmd" && return 0
    if [ "${NO_INSTALL:-0}" = "1" ]; then
        OS_MISSING="$OS_MISSING $_cmd"; return 1
    fi
    if [ "$OS_ROOT" != "1" ]; then
        OS_MISSING="$OS_MISSING $_cmd"; return 1
    fi
    _pkg="${2:-$(pkg_for "$_cmd")}"
    [ -z "$_pkg" ] && { OS_MISSING="$OS_MISSING $_cmd"; return 1; }
    pkg_refresh
    step "installing $_pkg (provides $_cmd)"
    if pkg_install $_pkg >/dev/null 2>&1 && have "$_cmd"; then
        OS_INSTALLED="$OS_INSTALLED $_pkg"
        return 0
    fi
    OS_MISSING="$OS_MISSING $_cmd"
    return 1
}

# ====================================================================
#  PCI helpers  (lspci -mm is machine readable; sysfs is the fallback)
# ====================================================================
os_lspci_cache() {
    [ -f "$OS_TMP/lspci" ] && return 0
    if ensure_cmd lspci; then
        lspci -mm 2>/dev/null > "$OS_TMP/lspci" || : > "$OS_TMP/lspci"
    else
        : > "$OS_TMP/lspci"
    fi
}

pci_clean() {
    sed -e 's/ Corporation//g' -e 's/ Corp\.//g' -e 's/, Inc\.//g' -e 's/ Inc\.//g' \
        -e 's/ Co\., Ltd\.//g' -e 's/ Technology Group//g' -e 's/ Semiconductor//g' \
        -e 's/\[AMD\/ATI\]/AMD/g' -e 's/Advanced Micro Devices/AMD/g' \
        -e 's/ PCI Express / /g' -e 's/ Controller$//' -e 's/ Network Adapter$//' \
        -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# pci_name 0000:01:00.0 -> "NVIDIA GP106 [GeForce GTX 1060 6GB]"
pci_name() {
    _b=${1#0000:}
    os_lspci_cache
    _n=$(awk -F'"' -v b="$_b" 'index($0, b) == 1 { print $4 " " $6; exit }' "$OS_TMP/lspci" | pci_clean)
    if [ -z "$_n" ] || [ "$_n" = " " ]; then
        _v=$(rd "/sys/bus/pci/devices/$1/vendor"); _d=$(rd "/sys/bus/pci/devices/$1/device")
        _n="${_v#0x}:${_d#0x}"
    fi
    printf '%s' "$_n"
}

# pci_class 0000:01:00.0 -> "VGA compatible controller"
pci_class() {
    _b=${1#0000:}
    os_lspci_cache
    awk -F'"' -v b="$_b" 'index($0, b) == 1 { print $2; exit }' "$OS_TMP/lspci"
}

# compact label for a PCI class, so the class column stays narrow
pci_class_short() {
    case "$1" in
        'VGA compatible controller')          echo "VGA" ;;
        '3D controller')                      echo "3D" ;;
        'Display controller')                 echo "Display" ;;
        'Non-Volatile memory controller')     echo "NVMe" ;;
        'SATA controller')                    echo "SATA" ;;
        'IDE interface')                      echo "IDE" ;;
        'RAID bus controller')                echo "RAID" ;;
        'SCSI storage controller')            echo "SCSI" ;;
        'USB controller')                     echo "USB" ;;
        'Ethernet controller')                echo "Ethernet" ;;
        'Network controller')                 echo "Wi-Fi" ;;
        'Audio device'|'Multimedia audio controller') echo "Audio" ;;
        'PCI bridge')                         echo "PCI bridge" ;;
        'Host bridge')                        echo "Host bridge" ;;
        'ISA bridge')                         echo "ISA bridge" ;;
        'SMBus')                              echo "SMBus" ;;
        'Serial controller')                  echo "Serial" ;;
        'SD Host controller')                 echo "SD host" ;;
        'Signal processing controller')       echo "Signal proc" ;;
        'System peripheral')                  echo "Sys periph" ;;
        'Encryption controller')              echo "Crypto" ;;
        'Communication controller')           echo "Comms" ;;
        'Memory controller')                  echo "Memory" ;;
        '')                                   echo "-" ;;
        *) printf '%s' "$1" | sed -e 's/ controller$//' -e 's/ interface$//' ;;
    esac
}

# PCIe generation from a "8.0 GT/s PCIe" style string
pcie_gen() {
    case "$1" in
        2.5*) echo "Gen1" ;;  5.0*|5\ *) echo "Gen2" ;;  8.0*) echo "Gen3" ;;
        16.0*) echo "Gen4" ;; 32.0*) echo "Gen5" ;;      64.0*) echo "Gen6" ;;
        *) echo "-" ;;
    esac
}

# ====================================================================
#  temperature / frequency / power sensors
#  OS_SYSFS exists so the test suite can point these at a fake tree.
# ====================================================================
OS_SYSFS=${OS_SYSFS:-/sys}
CPU_TEMP_PATH=''
CPU_TEMP_LABEL=''

OS_MODPROBED=''

# A live USB often boots without the hwmon drivers loaded, which leaves the
# machine looking like it has no sensors at all. Nudge the usual suspects.
os_try_sensor_modules() {
    [ -n "$OS_MODPROBED" ] && return 1
    OS_MODPROBED=1
    [ "$OS_ROOT" = "1" ] || return 1
    have modprobe || return 1
    for _m in coretemp k10temp zenpower nct6775 nct6683 jc42 drivetemp; do
        $SUDO modprobe "$_m" 2>/dev/null
    done
    return 0
}

os_find_cpu_temp() {
    [ -n "$CPU_TEMP_PATH" ] && return 0
    if ! os_scan_cpu_temp; then
        os_try_sensor_modules && os_scan_cpu_temp
    fi
    [ -n "$CPU_TEMP_PATH" ]
}

os_scan_cpu_temp() {
    for h in "$OS_SYSFS"/class/hwmon/hwmon*; do
        [ -d "$h" ] || continue
        n=$(rd "$h/name")
        case "$n" in
            coretemp|k10temp|zenpower|k8temp|cpu_thermal|soc_thermal) ;;
            *) continue ;;
        esac
        # prefer the package / Tdie sensor
        for l in "$h"/temp*_label; do
            [ -r "$l" ] || continue
            lv=$(rd "$l")
            case "$lv" in
                'Package id 0'|Tdie|Tctl|CPU)
                    CPU_TEMP_PATH="${l%_label}_input"
                    CPU_TEMP_LABEL="$n/$lv"
                    [ -r "$CPU_TEMP_PATH" ] && return 0 ;;
            esac
        done
        if [ -r "$h/temp1_input" ]; then
            CPU_TEMP_PATH="$h/temp1_input"; CPU_TEMP_LABEL="$n/temp1"; return 0
        fi
    done
    for z in "$OS_SYSFS"/class/thermal/thermal_zone*; do
        [ -r "$z/type" ] || continue
        t=$(rd "$z/type")
        case "$t" in
            x86_pkg_temp|cpu-thermal|cpu_thermal|soc_thermal|acpitz)
                CPU_TEMP_PATH="$z/temp"; CPU_TEMP_LABEL="thermal/$t"; return 0 ;;
        esac
    done
    # last resort: the first hwmon sensor we can find
    for h in "$OS_SYSFS"/class/hwmon/hwmon*/temp1_input; do
        [ -r "$h" ] || continue
        CPU_TEMP_PATH="$h"; CPU_TEMP_LABEL="hwmon (generic)"; return 0
    done
    return 1
}

# millidegrees C, or empty
cpu_temp_mc() { [ -n "$CPU_TEMP_PATH" ] && rd "$CPU_TEMP_PATH"; }

# average current CPU frequency in kHz
cpu_freq_khz() {
    if [ -r "$OS_SYSFS/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq" ]; then
        awk '{ s += $1; n++ } END { if (n) printf "%d\n", s/n }' \
            "$OS_SYSFS"/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null
    else
        awk -F: '/^cpu MHz/ { s += $2; n++ } END { if (n) printf "%d\n", (s/n)*1000 }' \
            /proc/cpuinfo 2>/dev/null
    fi
}

# RAPL energy counter in microjoules (Intel; needs root on recent kernels)
RAPL_PATH=''
os_find_rapl() {
    for p in "$OS_SYSFS"/class/powercap/intel-rapl:0/energy_uj \
             "$OS_SYSFS"/class/powercap/intel-rapl-mmio:0/energy_uj; do
        if [ -r "$p" ]; then RAPL_PATH="$p"; return 0; fi
    done
    return 1
}
rapl_uj() { [ -n "$RAPL_PATH" ] && rd "$RAPL_PATH"; }

# summed in shell rather than awk: an unmatched glob would make awk bail out
# before its END block and print nothing at all
cpu_throttle_count() {
    _n=0
    for _f in "$OS_SYSFS"/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
        [ -r "$_f" ] || continue
        _v=$(rd "$_f")
        case "$_v" in ''|*[!0-9]*) continue ;; esac
        _n=$((_n + _v))
    done
    printf '%s\n' "$_n"
}

# ====================================================================
#  banner / init / footer
# ====================================================================
os_init() {
    OS_SCRIPT="$1"
    os_detect_priv
    os_detect_distro
    printf '\n'
    rule
    printf ' %sonline-script%s %s/%s %s%s\n' \
        "$CB" "$CR" "$CD" "$CR" "$CB$OS_SCRIPT$CR" "$CD  v$OS_VERSION$CR"
    printf ' %shost%s  %s   %skernel%s %s %s\n' \
        "$CD" "$CR" "$(hostname 2>/dev/null || rd /proc/sys/kernel/hostname)" \
        "$CD" "$CR" "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)"
    printf ' %sos%s    %s\n' "$CD" "$CR" "$DISTRO_NAME"
    printf ' %sdate%s  %s   %spriv%s %s\n' "$CD" "$CR" \
        "$(date -u '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)" "$CD" "$CR" \
        "$([ "$OS_ROOT" = 1 ] && echo root || echo 'unprivileged')"
    rule
    printf '\n'
    if [ "$OS_ROOT" != "1" ]; then
        warn "not running as root - DMI/SMART data and dependency install are unavailable"
        note "re-run as:  curl -fsSL $(os_url "/$OS_SCRIPT.sh") | sudo sh"
        printf '\n'
    fi
}

os_footer() {
    [ -n "$OS_INSTALLED" ] && note "packages installed during this run:$OS_INSTALLED"
    [ -n "$OS_MISSING" ] && warn "tools unavailable (some rows are blank):$OS_MISSING"
    printf '%s  more:%s' "$CD" "$CR"
    printf '%s curl -fsSL %s | sudo sh%s\n' "$CD" "$(os_url /sysinfo.sh)" "$CR"
    printf '%s        curl -fsSL %s   # list every script%s\n' \
        "$CD" "$(os_url /scripts)" "$CR"
    printf '\n'
}

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
