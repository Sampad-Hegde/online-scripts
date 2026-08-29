#!/bin/sh
# shellcheck shell=sh disable=SC2086,SC2012,SC3043
#@name        cpu-load
#@title       CPU load + thermal test
#@description Pegs every thread, samples temperature / clock / power, reports min-max-avg-median
#@root        recommended
#@params      duration,threads,interval,baseline
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

# try_cmd: like ensure_cmd, but for optional extras (load generators). A
# failure here is normal, so it is not reported as a missing tool.
try_cmd() {
    _saved="$OS_MISSING"
    if ensure_cmd "$@"; then
        return 0
    fi
    OS_MISSING="$_saved"
    return 1
}

# ====================================================================
#  PCI helpers  (lspci -mm is machine readable; sysfs is the fallback)
#  OS_SYSFS lets the test suite point every sysfs read at a fake tree.
# ====================================================================
OS_SYSFS=${OS_SYSFS:-/sys}
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
        _v=$(rd "$OS_SYSFS/bus/pci/devices/$1/vendor")
        _d=$(rd "$OS_SYSFS/bus/pci/devices/$1/device")
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
# ====================================================================
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
    [ -n "$OS_MISSING" ] && warn "not installed, so some rows are blank:$OS_MISSING"
    printf '%s  more:%s' "$CD" "$CR"
    printf '%s curl -fsSL %s | sudo sh%s\n' "$CD" "$(os_url /sysinfo.sh)" "$CR"
    printf '%s        curl -fsSL %s   # list every script%s\n' \
        "$CD" "$(os_url /scripts)" "$CR"
    printf '\n'
}

os_init "cpu-load"

# ------------------------------------------------------------- settings
DURATION=${DURATION:-60}
THREADS=${THREADS:-0}
INTERVAL=${INTERVAL:-1}
BASELINE=${BASELINE:-8}

while [ $# -gt 0 ]; do
    case "$1" in
        --duration|-d) DURATION="$2"; shift 2 ;;
        --threads|-t)  THREADS="$2"; shift 2 ;;
        --interval|-i) INTERVAL="$2"; shift 2 ;;
        --baseline|-b) BASELINE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

NPROC=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
[ "$THREADS" = "0" ] && THREADS="$NPROC"

case "$DURATION" in ''|*[!0-9]*) DURATION=60 ;; esac
case "$THREADS"  in ''|*[!0-9]*) THREADS="$NPROC" ;; esac
[ "$DURATION" -gt 3600 ] && DURATION=3600
[ "$DURATION" -lt 5 ] && DURATION=5

TEMP_LOG="$OS_TMP/temp.log"
FREQ_LOG="$OS_TMP/freq.log"
PWR_LOG="$OS_TMP/pwr.log"
BASE_LOG="$OS_TMP/base.log"
: > "$TEMP_LOG"; : > "$FREQ_LOG"; : > "$PWR_LOG"; : > "$BASE_LOG"

os_find_cpu_temp || warn "no CPU temperature sensor found - thermal stats will be empty"
os_find_rapl || true

# rated clocks, so the sustained figure can be compared against them
CPUFREQ="$OS_SYSFS/devices/system/cpu/cpu0/cpufreq"
BASE_KHZ=$(rd "$CPUFREQ/base_frequency")
MAX_KHZ=$(rd "$CPUFREQ/cpuinfo_max_freq")
khz_ghz() { [ -n "$1" ] && awk -v k="$1" 'BEGIN{ printf "%.2f GHz", k/1000000 }'; }

TJMAX=''
if [ -n "$CPU_TEMP_PATH" ]; then
    for s in crit max; do
        f="${CPU_TEMP_PATH%_input}_$s"
        [ -r "$f" ] && { TJMAX=$(rd "$f"); break; }
    done
fi

LOAD_PIDS=''
MON_PID=''
stop_all() {
    touch "$OS_TMP/stop" 2>/dev/null
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
    [ -n "$MON_PID" ] && kill $MON_PID 2>/dev/null
    have pkill && pkill -P $$ 2>/dev/null
}
trap 'stop_all; os_cleanup; exit 130' INT
trap 'stop_all; os_cleanup; exit 143' TERM
trap 'stop_all; os_cleanup' EXIT

# ------------------------------------------------------------- sampling
sample_once() { # $1 = temp log, $2 = freq log, $3 = pwr log
    t=$(cpu_temp_mc); [ -n "$t" ] && printf '%s\n' "$t" >> "$1"
    f=$(cpu_freq_khz); [ -n "$f" ] && printf '%s\n' "$f" >> "$2"
    if [ -n "$RAPL_PATH" ]; then
        e=$(rapl_uj)
        if [ -n "$e" ] && [ -n "$PREV_UJ" ]; then
            d=$((e - PREV_UJ))
            if [ "$d" -ge 0 ]; then
                # milliwatts = uJ / interval_seconds / 1000
                awk -v d="$d" -v i="$INTERVAL" 'BEGIN{ printf "%d\n", d/i/1000 }' >> "$3"
            fi
        fi
        PREV_UJ="$e"
    fi
}

monitor() { # $1 endtime  $2 templog  $3 freqlog  $4 pwrlog  $5 show-progress
    PREV_UJ=''
    n=0
    while [ ! -f "$OS_TMP/stop" ]; do
        now=$(date +%s)
        [ "$now" -ge "$1" ] && break
        sample_once "$2" "$3" "$4"
        n=$((n + 1))
        if [ "$5" = "1" ] && [ $((n % 5)) = 0 ]; then
            tc='-'; fc='-'; wc='-'
            tl=$(tail -1 "$2" 2>/dev/null); [ -n "$tl" ] && tc=$(awk -v v="$tl" 'BEGIN{printf "%.1f C", v/1000}')
            fl=$(tail -1 "$3" 2>/dev/null); [ -n "$fl" ] && fc=$(awk -v v="$fl" 'BEGIN{printf "%.2f GHz", v/1000000}')
            wl=$(tail -1 "$4" 2>/dev/null); [ -n "$wl" ] && wc=$(awk -v v="$wl" 'BEGIN{printf "%.1f W", v/1000}')
            printf '%s  [%3ds/%ds]  temp %-10s clock %-11s package %s%s\n' \
                "$CD" "$((n * INTERVAL))" "$DURATION" "$tc" "$fc" "$wc" "$CR"
        fi
        sleep "$INTERVAL"
    done
}

# ------------------------------------------------------------ load engine
ENGINE=''
ENGINE_DESC=''
if ensure_cmd stress-ng; then
    ENGINE=stress-ng
    ENGINE_DESC="stress-ng --cpu $THREADS (heaviest, uses vector units)"
elif have openssl; then
    ENGINE=openssl
    ENGINE_DESC="openssl speed -multi $THREADS (AES/SHA load)"
else
    ENGINE='awk'
    ENGINE_DESC="pure awk busy loops x $THREADS (lightest - install stress-ng for a real burn-in)"
fi

start_load() {
    end="$1"
    case "$ENGINE" in
        stress-ng)
            ( stress-ng --cpu "$THREADS" --timeout "${DURATION}s" --metrics-brief \
                > "$OS_TMP/stress.out" 2>&1 ) &
            LOAD_PIDS="$!"
            ;;
        openssl)
            i=0
            while [ "$i" -lt "$THREADS" ]; do
                ( while [ ! -f "$OS_TMP/stop" ]; do
                      [ "$(date +%s)" -ge "$end" ] && break
                      openssl speed -seconds 2 -evp aes-256-cbc >/dev/null 2>&1 || \
                          openssl speed -seconds 2 aes-256-cbc >/dev/null 2>&1 || break
                  done ) &
                LOAD_PIDS="$LOAD_PIDS $!"
                i=$((i + 1))
            done
            ;;
        awk)
            i=0
            while [ "$i" -lt "$THREADS" ]; do
                ( while [ ! -f "$OS_TMP/stop" ]; do
                      [ "$(date +%s)" -ge "$end" ] && break
                      awk 'BEGIN{s=0; for(j=0;j<1500000;j++) s += sqrt(j) + j%7; exit}'
                  done ) &
                LOAD_PIDS="$LOAD_PIDS $!"
                i=$((i + 1))
            done
            ;;
    esac
}

# ======================================================================
#  plan
# ======================================================================
t_open "TEST PLAN"
t_row "CPU"            "$(dv "$(awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo | sed -e 's/(R)//g' -e 's/(TM)//g')")"
t_row "Logical CPUs"   "$NPROC"
t_row "Load threads"   "$THREADS"
t_row "Duration"       "${DURATION}s  (+${BASELINE}s idle baseline)"
t_row "Sample interval" "${INTERVAL}s"
t_row "Load engine"    "$ENGINE_DESC"
t_row "Rated clocks"   "base $(dv "$(khz_ghz "$BASE_KHZ")") / max $(dv "$(khz_ghz "$MAX_KHZ")")"
t_row "Temp sensor"    "$(dv "$CPU_TEMP_LABEL" 'none')"
t_row "Thermal limit"  "$([ -n "$TJMAX" ] && awk -v t="$TJMAX" 'BEGIN{printf "%.0f C", t/1000}' || echo '-')"
t_row "Package power"  "$([ -n "$RAPL_PATH" ] && echo "RAPL ($RAPL_PATH)" || echo 'not available')"
t_end

# ======================================================================
#  1. idle baseline
# ======================================================================
hdr "IDLE BASELINE (${BASELINE}s)"
b_end=$(( $(date +%s) + BASELINE ))
PREV_UJ=''
while [ "$(date +%s)" -lt "$b_end" ]; do
    sample_once "$BASE_LOG" "$OS_TMP/bfreq.log" "$OS_TMP/bpwr.log"
    sleep "$INTERVAL"
done
idle_temp=$(stats_calc "$BASE_LOG" 1000 1 | awk '{print $3}')
idle_freq=$(stats_calc "$OS_TMP/bfreq.log" 1000000 2 | awk '{print $3}')
idle_pwr=$(stats_calc "$OS_TMP/bpwr.log" 1000 1 | awk '{print $3}')

t_head "IDLE" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$BASE_LOG" 1000 "C" 1
stats_row "Clock" "$OS_TMP/bfreq.log" 1000000 "GHz" 2
[ -s "$OS_TMP/bpwr.log" ] && stats_row "Package power" "$OS_TMP/bpwr.log" 1000 "W" 1
t_end

# ======================================================================
#  2. load run
# ======================================================================
hdr "LOAD RUN (${DURATION}s, $THREADS threads)"

thr_before=$(cpu_throttle_count)
l_end=$(( $(date +%s) + DURATION ))
start_load "$l_end"
monitor "$l_end" "$TEMP_LOG" "$FREQ_LOG" "$PWR_LOG" 1
touch "$OS_TMP/stop"
[ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null
wait 2>/dev/null
thr_after=$(cpu_throttle_count)
thr_delta=$((thr_after - thr_before))
rm -f "$OS_TMP/stop"

printf '\n'
t_head "UNDER LOAD" "METRIC" "MIN" "MAX" "AVG" "MEDIAN" "SAMPLES"
stats_row "Temperature" "$TEMP_LOG" 1000 "C" 1
stats_row "Clock (all-core avg)" "$FREQ_LOG" 1000000 "GHz" 2
[ -s "$PWR_LOG" ] && stats_row "Package power" "$PWR_LOG" 1000 "W" 1
t_end

# heat soak: first quarter vs last quarter of the samples
soak='-'
if [ -s "$TEMP_LOG" ]; then
    soak=$(awk '{a[++n]=$1} END{
        if (n < 8) { print "-"; exit }
        q = int(n/4); s1=0; s2=0
        for (i=1;i<=q;i++) s1 += a[i]
        for (i=n-q+1;i<=n;i++) s2 += a[i]
        printf "%.1f C -> %.1f C  (drift %+.1f C)", s1/q/1000, s2/q/1000, (s2/q - s1/q)/1000
    }' "$TEMP_LOG")
fi

t_open "THERMAL BEHAVIOUR"
t_row "Idle avg temp"      "$(dv "$idle_temp") C"
t_row "Load avg temp"      "$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $3}') C"
t_row "Peak temp"          "$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $2}') C"
t_row "Rise over idle"     "$(awk -v a="$idle_temp" -v b="$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $2}')" 'BEGIN{ if(a=="-"||b=="-"){print "-"} else printf "%+.1f C", b-a }')"
t_row "Heat soak (1st vs last quarter)" "$soak"
t_row "Idle avg clock"     "$(dv "$idle_freq") GHz"
t_row "Load avg clock"     "$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $3}') GHz"
t_row "Throttle events"    "$thr_delta $CD(core_throttle_count delta)$CR"
[ -s "$PWR_LOG" ] && t_row "Idle / load power" "$(dv "$idle_pwr") W  ->  $(stats_calc "$PWR_LOG" 1000 1 | awk '{print $3}') W"
t_end

# ------------------------------------------------------------- timeline
if [ -s "$TEMP_LOG" ]; then
    hdr "TEMPERATURE TIMELINE"
    tmin=$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $1}')
    tmax=$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $2}')
    printf '  %s%s%s\n' "$CC" "$(sparkline "$TEMP_LOG" $((OS_COLS - 12)))" "$CR"
    printf '  %s%s C (low) .. %s C (high), left = start of load%s\n\n' "$CD" "$tmin" "$tmax" "$CR"
fi

if [ -s "$FREQ_LOG" ]; then
    hdr "CLOCK TIMELINE"
    fmin=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $1}')
    fmax=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $2}')
    printf '  %s%s%s\n' "$CC" "$(sparkline "$FREQ_LOG" $((OS_COLS - 12)))" "$CR"
    printf '  %s%s GHz (low) .. %s GHz (high)%s\n\n' "$CD" "$fmin" "$fmax" "$CR"
fi

# ------------------------------------------------------------ throughput
if [ "$ENGINE" = "stress-ng" ] && [ -s "$OS_TMP/stress.out" ]; then
    bogo=$(awk '{ for (i=1;i<=NF;i++) if ($i=="cpu" && (i+5)<=NF) { print $(i+1) "\t" $(i+5); exit } }' "$OS_TMP/stress.out")
    if [ -n "$bogo" ]; then
        t_open "THROUGHPUT (stress-ng)"
        t_row "Bogo ops"       "$(printf '%s' "$bogo" | cut -f1)"
        t_row "Bogo ops/s"     "$(printf '%s' "$bogo" | cut -f2)"
        t_note "compare the same figure between machines only with identical stress-ng versions"
        t_end
    fi
fi

# ======================================================================
#  verdict
# ======================================================================
hdr "VERDICT"
peak=$(stats_calc "$TEMP_LOG" 1000 0 | awk '{print $2}')
avgclk=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $3}')
tj='-'
[ -n "$TJMAX" ] && tj=$(awk -v t="$TJMAX" 'BEGIN{printf "%.0f", t/1000}')

t_open "ASSESSMENT"
if [ "$peak" = "-" ]; then
    t_row "Cooling" "${CY}unknown - no temperature sensor${CR}"
else
    if [ "$tj" != "-" ] && [ "$peak" -ge "$tj" ] 2>/dev/null; then
        t_row "Cooling" "${CE}peak ${peak} C reached the ${tj} C limit - throttling / bad cooler / dry paste${CR}"
    elif [ "$peak" -ge 95 ] 2>/dev/null; then
        t_row "Cooling" "${CE}peak ${peak} C - too hot for sustained load${CR}"
    elif [ "$peak" -ge 85 ] 2>/dev/null; then
        t_row "Cooling" "${CY}peak ${peak} C - warm, expect throttling in a hot room${CR}"
    else
        t_row "Cooling" "${CG}peak ${peak} C - healthy${CR}"
    fi
fi
if [ "$thr_delta" -gt 0 ] 2>/dev/null; then
    t_row "Throttling" "${CE}$thr_delta thermal throttle event(s) during the run${CR}"
else
    t_row "Throttling" "${CG}none reported by the kernel${CR}"
fi
if [ -n "$BASE_KHZ" ] && [ "$avgclk" != "-" ]; then
    verdict_clk=$(awk -v a="$avgclk" -v b="$BASE_KHZ" 'BEGIN{
        pc = a * 1000000 / b * 100
        printf "%.0f%% of the rated %.2f GHz base clock", pc, b/1000000 }')
    below=$(awk -v a="$avgclk" -v b="$BASE_KHZ" 'BEGIN{ print (a*1000000 < b*0.95) ? 1 : 0 }')
    if [ "$below" = "1" ]; then
        t_row "Sustained all-core clock" "${CY}$avgclk GHz - $verdict_clk${CR}"
    else
        t_row "Sustained all-core clock" "${CG}$avgclk GHz - $verdict_clk${CR}"
    fi
else
    t_row "Sustained all-core clock" "$avgclk GHz"
fi
nt=$(stats_calc "$TEMP_LOG" 1000 1 | awk '{print $5}')
nf=$(stats_calc "$FREQ_LOG" 1000000 2 | awk '{print $5}')
t_row "Stability" "${CG}completed ${DURATION}s of load${CR}  ${CD}($nt temperature / $nf clock samples)${CR}"
if [ "$nt" = "0" ]; then
    t_note "no temperature samples: this machine exposes no CPU sensor, so only the clock and throughput figures are meaningful"
fi
t_end
note "for a real burn-in run 15-30 min:  curl -fsSL $(os_url /cpu-load.sh) | sudo DURATION=1800 sh"

os_footer
