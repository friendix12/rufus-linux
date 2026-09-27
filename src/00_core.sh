#!/usr/bin/env bash
# ==============================================================================
#  rufus-linux.sh  --  Bootable USB creator for Linux  (Rufus-style)
#
#  Kya karta hai:
#    * ISO image se bootable pendrive banata hai -- bilkul Rufus ki tarah
#    * 3 modes : Auto / ISO-Hybrid (dd) / Partition & Copy
#    * MBR (BIOS + UEFI) aur GPT (UEFI) dono partition schemes
#    * FAT32 / NTFS / ext4 file systems
#    * Live progress bar, checksum verify, aur safety checks
#
#  Usage:
#    sudo ./rufus-linux.sh                       # interactive menu
#    sudo ./rufus-linux.sh -i ubuntu.iso -d /dev/sdb -y
#    sudo ./rufus-linux.sh -i ubuntu.iso -d /dev/sdb -m dd -y --verify
#    sudo ./rufus-linux.sh -h
#
#  NOTE: Linux ISOs ke liye "dd / ISO-Hybrid" mode sabse reliable hai aur
#        default raha hai. Rufus bhi zyada tar Linux ISOs ko isi tarah likhta hai.
# ==============================================================================

set -u
set -o pipefail

VERSION="2.0"
# SELF = khud ka ABSOLUTE path.  zaroori hai kyunki pkexec hamesha cwd ko "/"
# bana deta hai -> relative "./rufus-linux.sh" wahan "No such file" de deta hai.
SELF=${BASH_SOURCE[0]:-$0}
[[ $SELF == /* ]] || SELF="$PWD/$SELF"
if command -v readlink >/dev/null 2>&1; then
    _self=$(readlink -f -- "$SELF" 2>/dev/null || true)
    [[ -n ${_self:-} ]] && SELF=$_self
    unset _self
fi

# ------------------------------- colors ---------------------------------------
if [[ -t 1 ]]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
    C_BLU=$'\033[34m'; C_CYN=$'\033[36m'
else
    C_RST=''; C_B=''; C_DIM=''; C_RED=''; C_GRN=''; C_YLW=''; C_BLU=''; C_CYN=''
fi

# ------------------------------- globals --------------------------------------
ISO=""
DEV=""
SCHEME="mbr"        # mbr | gpt
FS="fat32"          # auto | fat32 | ntfs | ext4
MODE="auto"         # auto | dd | part
VOLLBL=""
# Rufus jaisa auto-fill: user ne option ko khud chhua ya nahi.
# 0 = abhi tak auto recommendation chali aa rahi hai -> auto_defaults_*
#     ise override kar sakta hai.  1 = user/CLI ne khud set kiya -> chhod do.
SCHEME_SET=0
FS_SET=0
MODE_SET=0
VOLLBL_SET=0
DO_VERIFY=0
ASSUME_YES=0
FINALIZE_EJECT=1

# persistence
PERSIST_MB=0            # 0 = OFF
PERSIST_KIND=""         # casper | live | none
PERSIST_PART=""         # persistence partition device
PERSIST_SIZE_MB=0

# Ventoy-style multi-ISO
VENTOY_ENABLED=0
VENTOY_BOOT_PART=""      # FAT32 boot/ESP partition
VENTOY_ISO_PART=""       # storage partition (ISOs yahan)
VENTOY_STORAGE_FS="ext4" # ext4 | ntfs

# GUI
GUI_PROGRESS=0
GUI_FIFO=""
GUI_PID=""
# progress ka phase -- overall 0-100% bar me is step ka hissa
# (Rufus ki tarah har step apna % dikhata hai, seedha 0% pe atka nahi rehta)
GUI_PHASE_BASE=0
GUI_PHASE_SPAN=100
GUI_TOOL=""              # yad | zenity | ""

# CLI action dispatch
ACTION="menu"
DL_ID=""
ADD_ISO=""
VERIFY_FILE=""

TMPDIR_P=""
MNT=""              # target partition mount
ISOMNT=""           # loop-mounted ISO mount

banner() {
    cat <<EOF
${C_CYN}${C_B}
========================================================================
  RUFUS-LINUX  ::  Bootable USB Creator   v${VERSION}
========================================================================
${C_RST}
EOF
}

info() { printf '%s\n' "${C_GRN}[OK]${C_RST}   $*"; }
warn() { printf '%s\n' "${C_YLW}[WARN]${C_RST} $*"; }
err()  { printf '%s\n' "${C_RED}[ERR]${C_RST}  $*" >&2; }
die()  { err "$*"; exit 1; }

# ------------------------------- helpers --------------------------------------
human() {
    local b=${1:-0}
    if   (( b >= 1073741824 )); then printf '%d.%02d GiB' $((b/1073741824)) $(((b%1073741824)*100/1073741824))
    elif (( b >= 1048576 ));    then printf '%d.%02d MiB' $((b/1048576))    $(((b%1048576)*100/1048576))
    elif (( b >= 1024 ));       then printf '%d KiB'     $((b/1024))
    else                              printf '%d B'      "$b"
    fi
}

cleanup() {
    local rc=$?
    # GUI progress window khuli ho to band karo (warna zombie/dialog bachega)
    if declare -F gui_progress_close >/dev/null 2>&1; then
        gui_progress_close 2>/dev/null || true
    fi

    # 1) WRITE wale bachche abhi bhi chal rahe honge (rsync / dd / mount.ntfs /
    #    7z / bsdtar).  Inhe pehle ROKO -- warna dialog band karte hi orphan
    #    process chalta rehta hai aur pendrive par ADHURA data reh jaata hai.
    #    Pattern = sirf humara temp dir, isliye koi aur process nahi marega.
    if [[ -n ${TMPDIR_P:-} && -d ${TMPDIR_P:-} ]]; then
        local kids
        kids=$(pgrep -f -- "$TMPDIR_P" 2>/dev/null | grep -vx -- "$$" || true)
        if [[ -n $kids ]]; then
            # shellcheck disable=SC2086
            kill -TERM $kids 2>/dev/null || true
            sleep 1
            kids=$(pgrep -f -- "$TMPDIR_P" 2>/dev/null | grep -vx -- "$$" || true)
            # shellcheck disable=SC2086
            [[ -n $kids ]] && kill -KILL $kids 2>/dev/null || true
        fi
        # dd ka cmdline me temp dir nahi hota (if=$ISO of=$DEV) -> alag se roko
        if [[ -n ${ISO:-} && -n ${DEV:-} && -f ${ISO:-} ]]; then
            pkill -TERM -f -- "dd if=$ISO of=$DEV" 2>/dev/null || true
        fi
    fi

    # 2) mounts hatao -- busy ho to lazy umount (varna EXIT hamesha fail)
    if [[ -n ${MNT:-} && -d ${MNT:-} ]]; then
        mountpoint -q "$MNT" 2>/dev/null && { umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null; }
    fi
    if [[ -n ${ISOMNT:-} && -d ${ISOMNT:-} ]]; then
        mountpoint -q "$ISOMNT" 2>/dev/null && { umount "$ISOMNT" 2>/dev/null || umount -l "$ISOMNT" 2>/dev/null; }
    fi
    if declare -F ventoy_umount >/dev/null 2>&1; then
        ventoy_umount 2>/dev/null || true
    fi

    # 3) temp dir -- sirf tabhi hatao jab path humara apna ho (guard: rm -rf)
    if [[ -n ${TMPDIR_P:-} && -d ${TMPDIR_P:-} ]]; then
        case $TMPDIR_P in
            /tmp/rufus-linux.*)
                rm -rf -- "$TMPDIR_P" 2>/dev/null || true
                ;;
            *)
                rm -f "$TMPDIR_P"/*.log "$TMPDIR_P"/gui.fifo 2>/dev/null
                rmdir "$TMPDIR_P" 2>/dev/null
                ;;
        esac
    fi
    return $rc
}
trap cleanup EXIT
trap 'echo; warn "User ne cancel kiya."; exit 130' INT TERM

# ------------------------------- deps -----------------------------------------
require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Root chahiye. Chalao:  sudo $0 $*"
}

have() { command -v "$1" >/dev/null 2>&1; }

check_base_deps() {
    local miss=()
    for c in lsblk blkid mount umount dd awk grep sed find sync; do
        have "$c" || miss+=("$c")
    done
    (( ${#miss[@]} )) && die "Missing tools: ${miss[*]}  (util-linux/coreutils install karo)"
}

# ---------------------- disk discovery / safety --------------------------------
# /dev/sda -> sda  (root disk ka top-level name)
top_disk_name() {
    local n=$1 p i
    for i in 1 2 3 4 5 6; do
        p=$(lsblk -ndo PKNAME "/dev/$n" 2>/dev/null | head -1)
        [[ -z $p ]] && break
        n=$p
    done
    printf '%s\n' "$n"
}

root_disk_name() {
    local src
    src=$(findmnt -n -o SOURCE / 2>/dev/null) || { echo ""; return; }
    src=${src%%[*}
    local b=${src##*/}
    # LVM/mapper case -> resolve via lsblk
    if [[ $b == *"/"* || -z $b ]]; then
        b=$(lsblk -ndo PKNAME "$src" 2>/dev/null | head -1)
    fi
    top_disk_name "$b"
}

is_usb_like() {
    local name=$1 tran rm
    tran=$(lsblk -dn -o TRAN "/dev/$name" 2>/dev/null | xargs)
    rm=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
    [[ $tran == usb || $rm == 1 || $tran == "mmcrd" ]]
}

list_removable_disks() {
    local name type size model tran out
    for d in /sys/block/*; do
        [[ -e $d ]] || continue
        name=${d##*/}
        [[ $name =~ ^(loop|ram|zram|sr|fd|dm-|md|nvme[0-9]+n[0-9]+)$ ]] && continue
        [[ -b /dev/$name ]] || continue
        type=$(lsblk -dn -o TYPE "/dev/$name" 2>/dev/null)
        [[ $type == disk ]] || continue
        is_usb_like "$name" || continue
        size=$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null)
        model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | xargs)
        printf '%s|%s|%s|%s\n' "$name" "$size" "${model:-n/a}" "$(lsblk -dn -o TRAN /dev/$name | xargs)"
    done
}

unmount_target() {
    local dev=$1 mp p
    while read -r mp; do
        [[ -z $mp || $mp == "[SWAP]" ]] && continue
        umount -l "$mp" 2>/dev/null || true
    done < <(lsblk -ln -o MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$')
    while read -r p; do
        [[ -z $p ]] && continue
        swapoff "/dev/$p" 2>/dev/null || true
    done < <(lsblk -ln -o NAME "$dev" 2>/dev/null | tail -n +2)
    udevadm settle 2>/dev/null || true
}

assert_safe_device() {
    local name=${DEV##*/}
    [[ -b $DEV ]] || die "$DEV ek block device nahi hai."

    # pehle: optical / loop / ram devices -- inpar kabhi mat likho
    # (sirf integration-test ke liye RUFUS_ALLOW_LOOP=1 se bypass hota hai)
    if [[ $name =~ ^(loop|ram|zram|sr|fd) ]]; then
        [[ ${RUFUS_ALLOW_LOOP:-0} == 1 && $name == loop* ]] || \
            die "$DEV optical/loop/ram device hai — uspar likhna allowed nahi hai."
    fi

    local ptype
    ptype=$(lsblk -dn -o TYPE "$DEV" 2>/dev/null)
    if [[ $ptype != disk ]]; then
        die "$DEV poora disk nahi hai (type='$ptype'). Partition ki jagah pura disk select karo (e.g. /dev/sdb, /dev/sdc)."
    fi

    # 1) device ke koi bhi partition root/boot/home par mount to nahi
    local mp
    while read -r mp; do
        [[ -z $mp ]] && continue
        case $mp in
            /|/boot|/boot/*|/home|/home/*|/usr|/usr/*|/var|/var/*)
                die "REFUSED: $DEV par '$mp' mount hai. Yeh system disk lag rahi hai." ;;
        esac
    done < <(lsblk -ln -o MOUNTPOINT "$DEV" 2>/dev/null)

    # 2) yehi disk root ko hold kar rahi hai?
    local rdk
    rdk=$(root_disk_name)
    if [[ -n $rdk && $rdk == "$name" ]]; then
        die "REFUSED: $DEV wahi disk hai jispar root filesystem hai (${rdk}). Barbaad mat karo!"
    fi

    # 3) removable na ho to strict confirm  (-y se skip hota hai)
    if ! is_usb_like "$name" && ! (( ASSUME_YES )); then
        warn "$DEV removable/USB nahi lag rahi (internal disk ho sakti hai)."
        printf '%s' "Type karo exact '${name}' likhkar confirm karne ke liye (ya ENTER cancel): "
        local ans; read -r ans || true
        [[ $ans == "$name" ]] || die "Cancel kiya gaya."
    fi
}

confirm_write() {                # $1 = effective mode (optional)
    (( ASSUME_YES )) && return 0
    local shown_mode=${1:-$MODE}
    [[ $shown_mode == auto ]] && shown_mode="(auto)"
    echo
    printf '%s\n' "${C_YLW}${C_B}!! DHYAN !!${C_RST} -- neeche diya gaya poora disk ERASE ho jayega:"
    printf '   %-14s : %s\n' "Device"  "$DEV"
    printf '   %-14s : %s\n' "Model"   "$(lsblk -dn -o MODEL "$DEV" 2>/dev/null | xargs)"
    printf '   %-14s : %s\n' "Size"    "$(human "$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)")"
    printf '   %-14s : %s\n' "ISO"     "${ISO:-<none>}"
    printf '   %-14s : %s\n' "Mode"    "$shown_mode"
    printf '   %-14s : %s\n' "Scheme"  "$SCHEME"
    printf '   %-14s : %s\n' "Filesys" "$FS"
    if (( ${PERSIST_MB:-0} > 0 )); then
        printf '   %-14s : %s\n' "Persistence" "$(persistence_status_text)"
    fi
    echo
    printf '%s' "Aage badhne ke liye device name type karo [${DEV##*/}] : "
    local ans; read -r ans || true
    [[ $ans == "${DEV##*/}" ]] || die "Cancel kiya gaya."
}

# ------------------------------- ISO checks -----------------------------------
iso_size() { stat -c '%s' "$ISO"; }

is_hybrid_iso() {
    local sig
    sig=$(dd if="$ISO" bs=1 skip=510 count=2 status=none 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [[ $sig == "55aa" ]]
}

is_windows_iso() {
    local m=${ISOMNT:-}
    [[ -n $m && -d $m ]] || return 1
    [[ -d $m/sources && ( -f $m/sources/install.wim || -f $m/sources/install.esd ) ]]
}

max_iso_filesize() {
    local m=${ISOMNT:-}
    [[ -n $m && -d $m ]] || { echo 0; return; }
    find "$m" -type f -printf '%s\n' 2>/dev/null | sort -n | tail -1
}

# --------------------- Rufus jaisa AUTO-FILL ----------------------------------
# ISO khud batata hai volume label, aur machine batati hai UEFI hai ya BIOS.
# User sirf ISO chune -> scheme/FS/label/mode sab apne aap baith jayein.

# ISO9660 Primary Volume Descriptor (sector 16) se asli volume label.
# Non-root bhi chalta hai -- koi mount nahi chahiye.
iso_volume_label() {
    local f=${1:-${ISO:-}} sig lbl
    [[ -f $f ]] || return 1
    if have blkid; then
        lbl=$(blkid -p -o value -s LABEL "$f" 2>/dev/null | head -1)
        lbl=$(printf '%s' "$lbl" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -n $lbl ]] && { printf '%s\n' "$lbl"; return 0; }
    fi
    sig=$(dd if="$f" bs=1 skip=32769 count=5 status=none 2>/dev/null)
    [[ $sig == "CD001" ]] || return 1
    lbl=$(dd if="$f" bs=1 skip=32808 count=32 status=none 2>/dev/null \
            | tr -d '\0' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -n $lbl ]] || return 1
    printf '%s\n' "$lbl"
}

# ISO ke andar sabse badi file ka size -- bina mount kiye (7z/bsdtar se).
# FAT32 ki 4GB limit yahin se pakki ho jaati hai.
iso_max_filesize_noroot() {
    local f=${1:-${ISO:-}} t out
    [[ -f $f ]] || { echo 0; return 0; }
    for t in 7z bsdtar; do
        have "$t" || continue
        case $t in
            7z)     out=$(7z l -ba "$f" 2>/dev/null) ;;
            bsdtar) out=$(bsdtar -tvf "$f" 2>/dev/null) ;;
        esac
        [[ -n $out ]] || continue
        if [[ $t == 7z ]]; then
            # 7z -ba:  <date> <time> <attr> <size> <compressed> <name>
            #   (size = 4th column; dir rows me wahan naam hota hai -> chhoot jayega)
            out=$(printf '%s\n' "$out" \
                  | awk '$1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $4 ~ /^[0-9]+$/ {print $4}' \
                  | sort -n | tail -1)
        else
            # bsdtar -tv: -rw-r--r-- 0 user group SIZE date time name
            out=$(printf '%s\n' "$out" | awk '$1 ~ /^-/ && $5 ~ /^[0-9]+$/ {print $5}' \
                  | sort -n | tail -1)
        fi
        if [[ $out =~ ^[0-9]+$ ]]; then echo "$out"; return 0; fi
    done
    echo 0
}

# ISO bata rahi hai ki kaunsa file system safe hai.
#   $1 = ISO ke andar sabse badi file (bytes)
#   $2 = Windows ISO? (0/1)   -- caller decide karta hai (mounted ya non-root)
recommend_fs() {
    local maxf=${1:-0} win=${2:-0}
    if (( maxf > 4294967295 )); then
        # FAT32 ka 4GB limit toot rahi hai.
        #  Windows + wimsplit -> Rufus ki tarah FAT32 + install.swm split
        #  warna -> NTFS
        if (( win )) && have wimsplit; then
            echo fat32
        else
            echo ntfs
        fi
    else
        echo fat32
    fi
}

# ISO ke andar Windows installer hai? -- bina mount kiye (non-root safe)
iso_looks_windows_noroot() {
    local f=${1:-${ISO:-}} t out
    [[ -f $f ]] || return 1
    for t in bsdtar 7z; do
        have "$t" || continue
        case $t in
            bsdtar) out=$(bsdtar -tf "$f" 2>/dev/null) ;;
            7z)     out=$(7z l -ba "$f" 2>/dev/null) ;;
        esac
        [[ -n $out ]] || continue
        # name columns me path separator ya space dono ho sakta hai
        if printf '%s\n' "$out" | grep -qiE 'sources[/\\]+install\.(wim|esd)([[:space:]]|$)'; then
            return 0
        fi
        return 1
    done
    # listing tool nahi mila -> filename/label heuristic
    local hay
    hay="$(basename "$f") $(iso_volume_label "$f" 2>/dev/null)"
    printf '%s' "$hay" | grep -qiE 'windows|win1[01]|win11|x64fre|ccsa|cccoma' && return 0
    return 1
}

# FS=auto resolve karo.  Root ho to mounted ISO se (exact), warna non-root
# listing se (7z/bsdtar).  Dono hi same jawab dete hain.
resolve_fs_auto() {
    local f=${1:-${ISO:-}} maxf=0 win=0
    if [[ -n ${ISOMNT:-} && -d ${ISOMNT:-} ]] && mountpoint -q "$ISOMNT" 2>/dev/null; then
        maxf=$(max_iso_filesize)
        is_windows_iso && win=1
    fi
    if (( maxf <= 0 )); then maxf=$(iso_max_filesize_noroot "$f"); fi
    if (( ! win )); then iso_looks_windows_noroot "$f" && win=1; fi
    recommend_fs "$maxf" "$win"
}

# ISO chalte hi (ya CLI me -i dete hi) sab auto-fill kar do.
# *_SET flags user/CLI ke explicitly diye gaye values ko protect karte hain.
auto_defaults_from_iso() {
    # --- machine based (ISO abhi na bhi ho to chalega) ---
    if (( ! ${SCHEME_SET:-0} )); then
        # UEFI machine -> GPT (Rufus ka modern default), BIOS -> MBR
        if [[ -d /sys/firmware/efi ]]; then SCHEME=gpt; else SCHEME=mbr; fi
    fi
    (( ${MODE_SET:-0} )) || MODE=auto          # hybrid? do_start khud decide karega

    # --- ISO based ---
    [[ -f ${ISO:-} ]] || return 0
    if [[ -z ${VOLLBL:-} ]]; then
        VOLLBL=$(iso_volume_label "$ISO" 2>/dev/null || true)
    fi
    if (( ! ${FS_SET:-0} )); then
        FS=auto                                 # write time pe ISO dekh kar finalise
    fi
    return 0
}

# ------------------------------- progress -------------------------------------
draw_bar() {
    local done=$1 total=$2 label=$3
    (( total > 0 )) || return 0
    (( done > total )) && done=$total
    local pct=$(( done * 100 / total ))
    local width=40
    local filled=$(( pct * width / 100 ))
    local bar
    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((width - filled)) '' | tr ' ' '-')"
    printf '\r  %s%-14s%s [%s] %3d%%  %s / %s   ' \
        "$C_CYN" "$label" "$C_RST" "$bar" "$pct" "$(human "$done")" "$(human "$total")"
}

# ---- phase-aware progress ---------------------------------------------------
# Rufus ki tarah overall 0-100% bar ko steps me baanta jaata hai.  Agar har
# step seedha 0% se shuru ho to user ko lagta hai "kuch dikh nahi raha".
# gui_phase <start%> <span%>  ->  agla step overall bar me [base, base+span).
gui_phase() {
    GUI_PHASE_BASE=${1:-0}
    GUI_PHASE_SPAN=${2:-100}
}

# $1 = phase ke andar 0-100, $2 = dikhane wala text   (sirf GUI dialog)
progress_text() {
    (( ${GUI_PROGRESS:-0} )) || return 0
    local pct=${1:-0} text=${2:-}
    local base=${GUI_PHASE_BASE:-0} span=${GUI_PHASE_SPAN:-100}
    local gpct=$(( base + pct * span / 100 ))
    (( gpct > 100 )) && gpct=100
    if declare -F gui_progress_set >/dev/null 2>&1; then
        gui_progress_set "$gpct" "$text"
    fi
}

# $1 = bytes done, $2 = bytes total, $3 = label
# GUI dialog me % + CLI me ASCII bar -- dono jagah yehi function chalata hai.
progress_report() {
    local done=${1:-0} total=${2:-0} label=${3:-} pct=0
    (( total > 0 )) && pct=$(( done * 100 / total ))
    (( pct > 100 )) && pct=100
    if (( ${GUI_PROGRESS:-0} )); then
        local base=${GUI_PHASE_BASE:-0} span=${GUI_PHASE_SPAN:-100}
        local gpct=$(( base + pct * span / 100 ))
        (( gpct > 100 )) && gpct=100
        if declare -F gui_progress_set >/dev/null 2>&1; then
            gui_progress_set "$gpct" "$label  $(human "$done") / $(human "$total")"
        fi
    else
        draw_bar "$done" "$total" "$label"
    fi
}

# dd/cmp jaise background process ka PID dekar live % dikhata hai
# (/proc/pid/io se bytes padhkar).  $4 = kaunsa counter (wchar | rchar).
# GUI mode me wahi % zenity/yad window ko bhejta hai.
progress_watch() {
    local pid=$1 total=$2 label=$3 iof=${4:-wchar}
    local written=0 prev=0 pct=0 lastpct=-1
    while kill -0 "$pid" 2>/dev/null; do
        written=$(awk "/^$iof:/{print \$2}" "/proc/$pid/io" 2>/dev/null)
        [[ -z $written ]] && written=$prev
        prev=$written
        if (( total > 0 )); then
            pct=$(( written * 100 / total ))
            (( pct > 100 )) && pct=100
        fi
        if (( pct != lastpct )); then
            progress_report "$written" "$total" "$label"
            lastpct=$pct
        fi
        sleep 0.3
    done
    progress_report "$total" "$total" "$label"
    (( ${GUI_PROGRESS:-0} )) || printf '\n'
}

# rsync --info=progress2 ka output padh kar progress_report me badalta hai.
#   $1 = error/odd line yahan likhte jao (fail hone par print hoga)
# stdin = rsync output
rsync_progress_feed() {
    local errf=${1:-} line pct
    while IFS= read -r line; do
        if [[ $line =~ ([0-9][0-9]*)% ]]; then
            pct=${BASH_REMATCH[1]}
            (( pct > 100 )) && pct=100
            if (( ${GUI_PROGRESS:-0} )); then
                progress_text "$pct" "ISO files copy ho rahi hain...  ${pct}%"
            else
                local base=${GUI_PHASE_BASE:-0} span=${GUI_PHASE_SPAN:-100}
                local gpct=$(( base + pct * span / 100 ))
                (( gpct > 100 )) && gpct=100
                printf '\r  %-14s %3d%%   (ISO files: %3d%%)   ' \
                       "Copying" "$gpct" "$pct"
            fi
        elif [[ -n $errf && -n $line ]]; then
            printf '%s\n' "$line" >> "$errf"
        fi
    done
    if (( ${GUI_PROGRESS:-0} )); then
        progress_text 100 "ISO files copy ho gayi hain."
    else
        printf '\n'
    fi
}

# ------------------------------- dd mode --------------------------------------
do_dd_write() {
    local total
    total=$(iso_size)
    local devsize
    devsize=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
    (( total > devsize )) && die "ISO ($(human $total)) device ($(human $devsize)) se bada hai."

    echo
    info "ISO ko seedhe device par likh raha hoon (ISO-Hybrid / dd mode)..."
    local log="$TMPDIR_P/dd.log"
    : > "$log"

    sync
    progress_text 0 "ISO ko device par likh raha hoon (dd)..."
    dd if="$ISO" of="$DEV" bs=4M conv=fsync status=none 2>"$log" &
    local ddpid=$!
    progress_watch "$ddpid" "$total" "Writing"
    wait "$ddpid"
    local rc=$?
    sync

    if (( rc != 0 )); then
        echo
        err "dd fail hua (exit $rc):"
        cat "$log" >&2
        exit $rc
    fi
    partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
    info "Likha ja chuka hai."
}

verify_dd() {
    local total; total=$(iso_size)
    echo
    info "Verify kar raha hoon (device vs ISO)..."
    progress_text 0 "Verify ho raha hai..."
    # cmp dono file padhta hai -> rchar total ka lagbhag 2 guna hota hai
    cmp -n "$total" -s "$DEV" "$ISO" &
    local cmpid=$!
    progress_watch "$cmpid" "$(( total * 2 ))" "Verify" rchar
    wait "$cmpid"
    local rc=$?
    if (( rc == 0 )); then
        info "VERIFIED: device aur ISO bilkul same hain. ✔"
        progress_text 100 "Verify OK"
    else
        warn "VERIFY FAILED: data match nahi hua. Dobara likho."
        return 1
    fi
}

# ------------------------------- partition mode --------------------------------
make_partition() {
    local dev=$1 lbl=$2 fs=$3

    unmount_target "$dev"
    wipefs -af "$dev" >/dev/null 2>&1 || true

    if have parted; then
        if [[ $lbl == gpt ]]; then
            parted -s "$dev" mklabel gpt || die "parted mklabel gpt fail"
            parted -s "$dev" mkpart primary "$fs" 1MiB 100% || die "parted mkpart fail"
            parted -s "$dev" set 1 esp on || true
        else
            parted -s "$dev" mklabel msdos || die "parted mklabel msdos fail"
            parted -s "$dev" mkpart primary "$fs" 1MiB 100% || die "parted mkpart fail"
            parted -s "$dev" set 1 boot on || true
        fi
    elif have sfdisk; then
        if [[ $lbl == gpt ]]; then
            printf 'label: gpt\n' | sfdisk -q "$dev" || die "sfdisk fail"
            printf 'start=2048, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B\n' | sfdisk -q -a "$dev" || die "sfdisk part fail"
        else
            printf 'label: dos\n' | sfdisk -q "$dev" || die "sfdisk fail"
            local t=c; [[ $fs == ntfs ]] && t=7
            printf 'start=2048, type=%s, bootable\n' "$t" | sfdisk -q -a "$dev" || die "sfdisk part fail"
        fi
    else
        die "parted ya sfdisk chahiye (partition mode ke liye)."
    fi

    blockdev --rereadpt "$dev" 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 1

    local part
    if [[ ${dev##*/} =~ [0-9]$ ]]; then part="${dev}p1"; else part="${dev}1"; fi

    local i
    for i in $(seq 1 40); do
        [[ -b $part ]] && break
        sleep 0.25
    done
    [[ -b $part ]] || die "$part nahi mila (partitioning fail)."
    printf '%s\n' "$part"
}

format_part() {
    local part=$1 fs=$2 label=$3
    case $fs in
        fat32)
            have mkfs.vfat || die "mkfs.vfat chahiye (dosfstools package)."
            mkfs.vfat -F 32 -n "$label" "$part" >/dev/null || die "mkfs.vfat fail"
            ;;
        ntfs)
            have mkfs.ntfs || die "mkfs.ntfs chahiye (ntfs-3g package)."
            mkfs.ntfs -f -L "$label" "$part" >/dev/null || die "mkfs.ntfs fail"
            ;;
        ext4)
            have mkfs.ext4 || die "mkfs.ext4 chahiye (e2fsprogs)."
            mkfs.ext4 -F -L "$label" "$part" >/dev/null || die "mkfs.ext4 fail"
            ;;
    esac
}

mount_iso() {
    [[ -n $ISOMNT ]] && umount "$ISOMNT" 2>/dev/null
    mkdir -p "$ISOMNT"
    mount -o loop,ro "$ISO" "$ISOMNT" 2>/dev/null && return 0
    warn "loop-mount fail; bsdtar/xorriso/7z fallback use hoga."
    return 1
}

copy_iso_contents() {
    local dst=$1
    if [[ -n ${ISOMNT:-} && -d $ISOMNT ]] && mountpoint -q "$ISOMNT" 2>/dev/null; then
        # rsync ka progress2 output seedha progress bar me daal do
        # (warna user ko sirf 0% dikhta rehta hai aur lagta hai atak gaya)
        if have rsync && rsync --info=progress2 --version >/dev/null 2>&1; then
            ensure_tmpdir
            local errf="$TMPDIR_P/copy.err" rc=0
            : > "$errf"
            rsync -a --info=progress2 "$ISOMNT"/ "$dst"/ 2>&1 \
                | rsync_progress_feed "$errf"
            rc=${PIPESTATUS[0]}
            if (( rc != 0 )); then
                echo
                [[ -s $errf ]] && cat "$errf" >&2
            fi
            return $rc
        fi
        if have rsync; then
            rsync -a "$ISOMNT"/ "$dst"/
        else
            echo "  (files copy ho rahe hain -- thoda wait karo)"
            cp -a "$ISOMNT"/. "$dst"/
        fi
        return $?
    fi
    local t
    for t in bsdtar xorriso 7z; do
        have "$t" || continue
        case $t in
            bsdtar)  bsdtar -xf "$ISO" -C "$dst" 2>/dev/null && return 0 ;;
            xorriso) xorriso -osirrox on -indev "$ISO" -extract / "$dst" >/dev/null 2>&1 && return 0 ;;
            7z)      7z x -y "-o$dst" "$ISO" >/dev/null 2>&1 && return 0 ;;
        esac
    done
    die "ISO extract nahi ho payi. (loop-mount fail + bsdtar/xorriso/7z bhi fail).
        -> 'sudo apt install libarchive-tools' ya 'xorriso' install karo,
           aur check karo ki file sahi ISO hai."
}

find_sys_file() {
    local n=$1 d
    for d in /usr/lib/syslinux/modules/bios /usr/lib/syslinux/mbr /usr/lib/syslinux \
             /usr/lib/syslinux/bios /usr/share/syslinux /usr/share/syslinux/mbr /boot/syslinux; do
        [[ -f $d/$n ]] && { echo "$d/$n"; return 0; }
    done
    return 1
}

find_mbr_bin() {
    local kind=$1 f d
    local names
    if [[ $kind == gpt ]]; then names=(gptmbr.bin mbr.bin); else names=(mbr.bin gptmbr.bin); fi
    for f in "${names[@]}"; do
        for d in /usr/lib/syslinux/mbr /usr/share/syslinux/mbr /usr/lib/syslinux /usr/share/syslinux; do
            [[ -f $d/$f ]] && { echo "$d/$f"; return 0; }
        done
    done
    return 1
}

install_bios_boot() {
    local dev=$1 part=$2 mnt=$3 scheme=$4

    local mbrbin
    if ! mbrbin=$(find_mbr_bin "$scheme"); then
        warn "syslinux MBR boot code nahi mila -- BIOS boot kaam nahi karega."
        warn "  Fix: 'syslinux' package install karo (apt/dnf/pacman)."
        return 1
    fi
    dd if="$mbrbin" of="$dev" bs=440 count=1 conv=notrunc status=none || {
        warn "MBR boot code likhne me fail."
        return 1
    }

    # isolinux dir dhoondho (jahan isolinux.bin hai)
    local iso_dir rel
    iso_dir=$(find "$mnt" -maxdepth 2 -name isolinux.bin -printf '%h\n' 2>/dev/null | head -1)

    if [[ -n $iso_dir ]]; then
        # .c32 modules + configs ko root pe copy karo, taaki syslinux unhe utha sake
        cp -f "$iso_dir"/*.c32 "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/*.cfg "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/*.msg "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/vmlinuz "$mnt"/ 2>/dev/null || true
        cp -f "$iso_dir"/initrd.* "$mnt"/ 2>/dev/null || true
        # kernel/initrd agar sirf isolinux/ me hain to root pe bhi daal do
        rel=${iso_dir#"$mnt"/}
        [[ $rel == "$mnt" ]] && rel=""
        if [[ -f $mnt/isolinux.cfg ]]; then
            printf 'INCLUDE isolinux.cfg\n' > "$mnt/syslinux.cfg"
        elif [[ -n $rel && -f $mnt/$rel/isolinux.cfg ]]; then
            printf 'INCLUDE %s/isolinux.cfg\n' "$rel" > "$mnt/syslinux.cfg"
        fi
    fi

    # ldlinux.c32 zaroori hai (syslinux 6.x)
    if [[ ! -f $mnt/ldlinux.c32 ]]; then
        local ldc
        ldc=$(find_sys_file ldlinux.c32 || true)
        [[ -n $ldc ]] && cp -f "$ldc" "$mnt"/ || warn "ldlinux.c32 nahi mila (syslinux package install karo)."
    fi

    sync

    if [[ $scheme == gpt ]]; then
        warn "GPT = UEFI-only. Legacy BIOS boot ke liye MBR scheme use karo."
        return 0
    fi

    if [[ $FS == ext4 ]]; then
        if have extlinux; then
            extlinux --install "$mnt" >/dev/null 2>&1 || warn "extlinux install fail."
        else
            warn "extlinux nahi mila -- BIOS boot nahi banega."
        fi
    else
        if have syslinux; then
            syslinux --install "$part" >/dev/null 2>&1 || warn "syslinux install fail."
        else
            warn "syslinux nahi mila -- BIOS boot nahi banega (package: syslinux)."
        fi
    fi
    sync
}

ensure_uefi_bootfile() {
    local mnt=$1
    # zyada tar Linux ISOs me /EFI/BOOT/BOOTX64.EFI hota hi hai
    if [[ -f $mnt/EFI/BOOT/BOOTX64.EFI || -f $mnt/efi/boot/bootx64.efi ]]; then
        info "UEFI boot file mili: EFI/BOOT/BOOTX64.EFI"
        return 0
    fi
    warn "EFI/BOOT/BOOTX64.EFI nahi mili -- UEFI boot shayad na chale."
    return 1
}

handle_big_windows_files() {
    local mnt=$1
    local wim="$mnt/sources/install.wim"
    [[ -f $wim ]] || return 0
    local sz; sz=$(stat -c '%s' "$wim")
    (( sz <= 4294967295 )) && return 0     # FAT32 ka 4GB limit

    if [[ $FS == fat32 ]]; then
        if have wimsplit; then
            info "install.wim > 4GB hai -- FAT32 limit ke liye split kar raha hoon (Rufus bhi yahi karta hai)..."
            wimsplit "$wim" "$mnt/sources/install.swm" 3800 && rm -f "$wim"
        else
            warn "install.wim 4GB se bada hai aur FAT32 usse boot nahi kar payega."
            warn "  Fix: 'wimlib-imagex' install karo (wimsplit), ya NTFS use karo."
        fi
    fi
}

do_partition_write() {
    local dev=$1
    local isosz; isosz=$(iso_size)

    # ---- pre-checks (sab loop-mount karke) ----
    local mounted_iso=0
    gui_phase 0 8
    progress_text 0 "ISO check ho rahi hai..."
    if mount_iso; then mounted_iso=1; fi

    local maxf=0
    maxf=$(max_iso_filesize)
    # mount fail ho gaya to bhi size chahiye -- 7z/bsdtar se nikaalo
    if (( maxf <= 0 )); then
        maxf=$(iso_max_filesize_noroot "$ISO")
    fi

    # ---- FS=auto -> ISO ke andar dekh kar decide (Rufus jaisa) ----
    if [[ $FS == auto ]]; then
        FS=$(resolve_fs_auto "$ISO")
        info "Auto file system -> $FS   (sabse badi file: $(human "$maxf"))"
        progress_text 5 "Auto file system -> $FS"
        if (( maxf > 4294967295 )) && [[ $FS == ntfs && $SCHEME == gpt ]]; then
            warn "ISO me 4GB+ file hai -> NTFS. GPT+NTFS se UEFI boot nahi chalega."
            warn "  Do: (a) 'sudo apt install wimlib' karo (FAT32 + wimsplit chalega)"
            warn "      (b) ya -p mbr (legacy BIOS) use karo."
        fi
    fi

    if [[ $FS == fat32 && $maxf -gt 4294967295 ]]; then
        if is_windows_iso && have wimsplit; then
            warn "Windows ISO me 4GB+ file hai -- FAT32 limit ke liye split kiya jayega."
        elif is_windows_iso; then
            warn "install.wim 4GB+ hai aur 'wimsplit' nahi mila -> FAT32 me nahi aayega."
            warn "  Fix: sudo apt install wimlib   (phir FAT32 + split chalega)"
            (( mounted_iso )) && umount "$ISOMNT" 2>/dev/null
            die "FAT32 me 4GB+ file nahi aayegi. -f ntfs use karo ya wimlib install karo."
        else
            (( mounted_iso )) && umount "$ISOMNT" 2>/dev/null
            die "ISO ke andar 4GB se bada file hai; FAT32 me nahi aayega. NTFS choose karo."
        fi
    fi

    local lbl
    lbl=$(sanitize_label "${VOLLBL:-}")

    local devsz; devsz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)

    # ---- persistence layout (2 partition) ----
    local part="" persist_on=0
    if (( ${PERSIST_MB:-0} > 0 )); then
        if ! persistence_is_supported "${PERSIST_KIND:-}"; then
            PERSIST_KIND=$(persistence_kind "$ISOMNT")
        fi
        if ! persistence_is_supported "${PERSIST_KIND:-}"; then
            warn "ISO persistence support nahi karti -- single partition me write kar raha hoon."
            persistence_reset
        fi
    fi
    if (( ${PERSIST_MB:-0} > 0 )); then
        persist_on=1
        if [[ $SCHEME != mbr ]]; then
            warn "Persistence ke liye MBR scheme chahiye (BIOS+UEFI) -- GPT ignore ho raha hai."
            SCHEME=mbr
        fi
        if [[ $FS != fat32 ]]; then
            warn "Persistence ke liye boot partition FAT32 chahiye -- FS = fat32 kar diya."
            FS=fat32
        fi
    fi

    echo
    gui_phase 8 7
    if (( persist_on )); then
        progress_text 0 "Partition + persistence bana raha hoon..."
        info "Partition plan: MBR / FAT32 boot + ext4 persistence (${PERSIST_MB} MB)"
        part=$(make_partition_persist "$dev" "$lbl" fat32 "$PERSIST_MB" "$isosz" "$devsz") || exit 1
        info "Partition bani: $part  (+ persistence $PERSIST_PART)"
    else
        progress_text 0 "Partition table + format ($SCHEME / $FS)..."
        info "Partition table bana raha hoon ($SCHEME / $FS)..."
        part=$(make_partition "$dev" "$SCHEME" "$FS") || exit 1
        info "Partition bani: $part"
        format_part "$part" "$FS" "$lbl"
    fi
    progress_text 100 "Format complete."

    mkdir -p "$MNT"
    mount "$part" "$MNT" || die "partition mount fail."
    info "Files copy ho rahe hain..."
    gui_phase 15 77                     # copy = overall 15% se 92% tak
    progress_text 0 "ISO files copy ho rahi hain..."
    copy_iso_contents "$MNT" || die "file copy fail."
    sync
    progress_text 100 "ISO files copy ho gayi hain."

    handle_big_windows_files "$MNT"

    if (( persist_on )); then
        local p; p=$(persistence_param_for "${PERSIST_KIND:-}")
        add_boot_param "$MNT" "$p" || warn "Kernel cmdline me '$p' add nahi hua."
        persistence_finish "$PERSIST_PART"
    fi

    gui_phase 92 6
    progress_text 0 "Boot files install ho rahe hain..."
    if [[ $SCHEME == mbr ]]; then
        install_bios_boot "$dev" "$part" "$MNT" "$SCHEME"
    else
        info "GPT scheme: UEFI-only boot (BIOS legacy nahi chalega)."
    fi
    ensure_uefi_bootfile "$MNT" || true
    progress_text 100 "Boot files ready."

    gui_phase 98 2
    progress_text 50 "Sync ho raha hai (data safe karne ke liye)..."
    sync
    umount "$MNT" 2>/dev/null || true
    (( mounted_iso )) && umount "$ISOMNT" 2>/dev/null
    progress_text 100 "Sync complete."
    gui_phase 100 1

    blockdev --rereadpt "$dev" 2>/dev/null || true
    partprobe "$dev" 2>/dev/null || true
    if (( persist_on )); then
        info "Partition mode complete (with persistence: ${PERSIST_SIZE_MB} MB, label=$(persistence_label_for "${PERSIST_KIND:-}"))"
    else
        info "Partition mode complete."
    fi
}

sanitize_label() {
    local s=${1:-}
    [[ -z $s ]] && s=$(basename "$ISO" .iso)
    s=$(printf '%s' "$s" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_-' )
    s=${s:0:11}
    [[ -z $s ]] && s="BOOT_USB"
    printf '%s\n' "$s"
}

# ------------------------------- temp dirs ------------------------------------
ensure_tmpdir() {
    [[ -n ${TMPDIR_P:-} && -d ${TMPDIR_P:-} ]] && return 0
    TMPDIR_P=$(mktemp -d /tmp/rufus-linux.XXXXXX) || die "temp dir nahi bani"
    MNT="$TMPDIR_P/mnt"
    ISOMNT="$TMPDIR_P/iso"
    mkdir -p "$MNT" "$ISOMNT"
}

# ------------------------------- main flow -------------------------------------
do_start() {
    [[ -n $ISO  ]] || die "ISO select karo (pehla menu item)."
    [[ -f $ISO  ]] || die "ISO file nahi mili: $ISO"
    [[ -n $DEV  ]] || die "USB device select karo (doosra menu item)."

    ensure_tmpdir
    check_base_deps

    # Rufus jaisa auto-fill: jo user/CLI ne khud set nahi kiya wo yahan se
    # (UEFI machine -> GPT, ISO se volume label, FS -> auto).
    auto_defaults_from_iso
    gui_phase 0 3
    progress_text 0 "ISO check ho rahi hai..."

    # ---- mode finalise ----
    local eff="$MODE"
    if [[ $eff == auto ]]; then
        if is_hybrid_iso; then
            eff=dd
            info "Auto detect: ISO hybrid hai -> ISO-Hybrid (dd) mode."
        else
            eff=part
            info "Auto detect: ISO hybrid nahi hai -> Partition & Copy mode."
        fi
    else
        [[ $eff == dd ]] && ! is_hybrid_iso && \
            warn "Yeh ISO hybrid lag nahi rahi -- dd mode me boot na ho. Phir bhi likh raha hoon..."
    fi

    [[ $eff == dd && $SCHEME == gpt && $MODE == dd ]] && \
        warn "dd mode me MBR/GPT selection ignore hota hai (ISO ka apna layout use hota hai)."

    # ---- persistence (sirf Partition & Copy mode) ----
    if [[ $eff == part ]] && (( ${PERSIST_MB:-0} == 0 )); then
        local iso_mounted=0
        mount_iso && iso_mounted=1
        persistence_ask
        (( iso_mounted )) && umount "$ISOMNT" 2>/dev/null
    elif [[ $eff == dd ]] && (( ${PERSIST_MB:-0} > 0 )); then
        warn "Persistence sirf Partition & Copy mode me kaam karta hai -- dd mode me skip ho raha hai."
        persistence_reset
    fi

    assert_safe_device
    confirm_write "$eff"
    unmount_target "$DEV"

    echo
    gui_phase 3 3
    progress_text 0 "Settings final ho rahe hain..."
    printf '%s\n' "${C_B}------------------------------------------------------------------------${C_RST}"
    printf '%s\n' "${C_B}  START  ->  $eff mode${C_RST}"
    printf '%s\n' "${C_B}------------------------------------------------------------------------${C_RST}"

    local t0=$SECONDS
    if [[ $eff == dd ]]; then
        # dd = 6% se shuru; verify ho to wo 94-100% lega
        if (( DO_VERIFY )); then gui_phase 6 88; else gui_phase 6 94; fi
        do_dd_write
        (( DO_VERIFY )) && verify_dd
    else
        do_partition_write "$DEV"
    fi

    local el=$(( SECONDS - t0 ))
    sync
    (( FINALIZE_EJECT )) && eject "$DEV" 2>/dev/null

    echo
    printf '%s\n' "${C_GRN}${C_B}========================================================================${C_RST}"
    printf '%s\n' "${C_GRN}${C_B}  DONE -- Bootable USB tayyar hai!  ($(( el/60 ))m $(( el%60 ))s)${C_RST}"
    printf '%s\n' "${C_GRN}${C_B}========================================================================${C_RST}"
    printf '  Device : %s\n' "$DEV"
    printf '  Mode   : %s\n' "$eff"
    printf '  Scheme : %s\n' "$SCHEME"
    printf '  FS     : %s\n' "$FS"
    printf '\n  Ab USB laga kar reboot karo (BIOS boot menu: F12/ESC/F8).\n\n'
}

# ------------------------------- interactive UI --------------------------------
pick_device() {
    local items=() i=1 line name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        items+=("$name")
        printf '  %s[%d]%s  /dev/%-8s %-8s %-25s (%s)\n' "$C_B" "$i" "$C_RST" "$name" "$size" "$model" "${tran:-n/a}"
        i=$((i+1))
    done < <(list_removable_disks)

    if (( ${#items[@]} == 0 )); then
        warn "Koi USB/removable disk nahi mili. Pendrive laga kar dobara try karo."
        return 1
    fi

    local ans
    printf '  Device number chuno (1-%d, ENTER=cancel): ' "${#items[@]}"
    read -r ans || return 1
    [[ -z $ans ]] && return 1
    [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#items[@]} )) || { warn "Ghalat choice."; return 1; }
    DEV="/dev/${items[ans-1]}"
    info "Selected: $DEV"
}

pick_iso() {
    local p
    printf '  ISO file ka path paste karo (ENTER=cancel): '
    read -r p || return 1
    p=${p//\~/~}
    [[ -z $p ]] && return 1
    p=${p%\"}; p=${p#\"}
    if [[ ! -f $p ]]; then warn "File nahi mili: $p"; return 1; fi
    ISO=$p
    if is_hybrid_iso; then
        info "ISO: $(basename "$ISO")  [hybrid: YES]"
    else
        warn "ISO: $(basename "$ISO")  [hybrid: NO -> partition mode better rahega]"
    fi
    printf '  Volume label (ENTER = auto): '
    read -r VOLLBL || true
}

cycle_scheme() {
    if [[ $SCHEME == mbr ]]; then SCHEME=gpt; else SCHEME=mbr; fi
}

cycle_fs() {
    case $FS in fat32) FS=ntfs;; ntfs) FS=ext4;; *) FS=fat32;; esac
}

cycle_mode() {
    case $MODE in auto) MODE=dd;; dd) MODE=part;; *) MODE=auto;; esac
}

persistence_cycle() {            # menu [7]
    if (( ${PERSIST_MB:-0} > 0 )); then
        persistence_reset
        info "Persistence OFF."
        return 0
    fi
    [[ -z ${ISO:-} || ! -f ${ISO:-} ]] && { warn "Pehle ISO select karo."; return 1; }
    ensure_tmpdir
    local im=0
    mount_iso && im=1
    local kind
    kind=$(persistence_kind "$ISOMNT")
    (( im )) && umount "$ISOMNT" 2>/dev/null

    if ! persistence_is_supported "$kind"; then
        warn "Is ISO me persistence supported nahi (Ubuntu / Mint / Debian Live chahiye)."
        warn "  Detected layout: $kind"
        return 1
    fi
    printf '  Persistence size in MB (kam se kam 256, ENTER=cancel): '
    local a
    read -r a || return 1
    [[ -z $a ]] && return 1
    [[ $a =~ ^[0-9]+$ ]] || { warn "Ghalat number."; return 1; }
    (( a < 256 )) && { warn "Kam se kam 256 MB."; return 1; }
    PERSIST_MB=$a
    PERSIST_KIND=$kind
    info "Persistence ON: $a MB  (partition label: $(persistence_label_for "$kind"))"
    [[ $MODE == dd || $MODE == auto ]] && warn "Note: persistence ke liye 'Partition & Copy' mode use hoga (auto me khud switch ho jayega)."
}

verify_current_iso() {
    local f=${ISO:-}
    if [[ -z $f || ! -f $f ]]; then
        printf '  ISO file ka path: '
        read -r f
        f=${f//\~/~}; f=${f%\"}; f=${f#\"}
    fi
    [[ -f $f ]] || { warn "File nahi mili."; return 1; }
    ensure_tmpdir
    dl_verify_existing "$f"
}

interactive_menu() {
    local c
    while true; do
        [[ -t 1 ]] && printf '\033[H\033[2J'
        banner
        # menu item: key, label, value  (labels aligned at 21 chars)
        mi() { printf '  %s[%s]%s  %-24s: %s\n' "$C_B" "$1" "$C_RST" "$2" "$3"; }

        mi 1 "ISO image select" \
            "$([[ -n $ISO ]] && printf '%s' "$ISO" || printf '%s%s%s' "$C_DIM" "(none)" "$C_RST")"
        mi 2 "USB device select" \
            "$([[ -n $DEV ]] && printf '%s' "$DEV" || printf '%s%s%s' "$C_DIM" "(none)" "$C_RST")"
        mi 3 "Partition scheme" \
            "$( [[ $SCHEME == mbr ]] && echo 'MBR  (BIOS + UEFI)' || echo 'GPT  (UEFI only)' )"
        mi 4 "File system" \
            "$( case $FS in
                 fat32) echo 'FAT32  (BIOS + UEFI, recommended)' ;;
                 ntfs)  echo 'NTFS   (files >4GB, UEFI boot limited)' ;;
                 *)     echo 'ext4   (BIOS only)' ;; esac )"
        mi 5 "Write mode" \
            "$( case $MODE in
                 auto) echo 'Auto (hybrid? -> dd : partition+copy)' ;;
                 dd)   echo 'ISO-Hybrid / dd  (recommended for Linux)' ;;
                 *)    echo 'Partition & Copy' ;; esac )"
        mi 6 "Verify after write" \
            "$( ((DO_VERIFY)) && echo ON || echo OFF )"
        mi 7 "Persistence (live save)" \
            "$( (( ${PERSIST_MB:-0} > 0 )) && printf '%s' "$(persistence_status_text)" || printf '%s%s%s' "$C_DIM" "OFF" "$C_RST" )"
        printf '  %s[8]%s  %sSTART%s  <-- likhna shuru karo\n' "$C_B" "$C_RST" "$C_GRN$C_B" "$C_RST"
        printf '\n%s  ------- Tools -------%s\n' "$C_DIM" "$C_RST"
        printf '  %s[D]%s  ISO download + SHA256 verify\n' "$C_B" "$C_RST"
        printf '  %s[V]%s  Verify existing ISO checksum\n' "$C_B" "$C_RST"
        printf '  %s[M]%s  Multi-ISO USB  (Ventoy-style GRUB menu)\n' "$C_B" "$C_RST"
        printf '  %s[H]%s  Drive health + speed + boot test\n' "$C_B" "$C_RST"
        printf '  %s[G]%s  GUI wizard (graphical, yad/zenity)\n' "$C_B" "$C_RST"
        printf '  %s[Q]%s  Quit\n' "$C_B" "$C_RST"
        printf '\n%s------------------------------------------------------------------------%s\n' "$C_DIM" "$C_RST"
        printf '  Choice: '
        read -r c || exit 0
        case $c in
            1) pick_iso ;;
            2) pick_device ;;
            3) cycle_scheme ;;
            4) cycle_fs ;;
            5) cycle_mode ;;
            6) DO_VERIFY=$(( 1 - DO_VERIFY )) ;;
            7) persistence_cycle ;;
            8|s|S) do_start; exit 0 ;;
            d|D) dl_menu ;;
            v|V) verify_current_iso ;;
            m|M) ventoy_menu ;;
            h|H) health_menu ;;
            g|G) gui_wizard; printf '\n  Press ENTER...'; read -r _ ;;
            q|Q) echo "Bye!"; exit 0 ;;
            *) ;;
        esac
    done
}

usage() {
    cat <<EOF
rufus-linux.sh v$VERSION -- Bootable USB creator for Linux (Rufus-style)

Usage:
  sudo $0                          Interactive menu (recommended)
  sudo $0 --gui                    GUI wizard (yad/zenity)
  sudo $0 -i <iso> -d <device> [options]

Write options:
  -i, --iso <file>       ISO image
  -d, --device <dev>     Target disk (e.g. /dev/sdb)
  -m, --mode <m>         auto | dd | part        (default: auto)
  -p, --part <scheme>    mbr | gpt               (default: mbr)
  -f, --fs <fs>          auto | fat32 | ntfs | ext4   (default: auto -> ISO se decide)
  -L, --label <name>     Volume label
      --persist <MB>     Persistence partition size (Partition mode, Debian/Ubuntu live)
      --verify           Write ke baad data verify karo
      --no-eject         Write ke baad eject mat karo
  -y, --yes              Confirmation prompt skip karo  (DHYAN!)

Subcommands:
      --gui                    GUI wizard (graphical)
      --download [id]          ISO download + SHA256 verify (menu, ya seedha id)
      --list-downloads         Distro catalog dikhao (root nahi chahiye)
      --download-dir <dir>     Download folder (default: ~/Downloads)
      --verify-iso <file>      Pehle se download kiya ISO verify karo

      --ventoy                 Multi-ISO USB menu (Ventoy-style)
      --ventoy-prepare         Nayi multi-ISO USB banao  (-d, -p, --storage)
      --ventoy-add <iso>       ISO USB par add karo
      --ventoy-remove          ISO remove karo (menu)
      --ventoy-rescan          GRUB menu rebuild karo
      --ventoy-list            USB par maujood ISO list
      --storage <fs>           Multi-ISO storage fs: ext4 | ntfs  (default ext4)

      --health                 Drive health + speed + boot test menu
      --help                   Yeh help

Modes:
  auto  = ISO hybrid hai to dd, warna partition+copy
  dd    = ISO ko seedhe device par likhna (Linux ISOs ke liye best)
  part  = FAT32 partition banakar files copy (+ persistence / Windows support)

Examples:
  sudo $0                                            # menu
  sudo $0 -i ubuntu.iso -d /dev/sdb -y --verify
  sudo $0 -i ubuntu.iso -d /dev/sdb -m part --persist 4096 -y
  sudo $0 --download ubuntu26                        # Ubuntu 26.04 LTS download
  sudo $0 --ventoy-prepare -d /dev/sdb -p mbr -y
  sudo $0 --ventoy-add ~/Downloads/archlinux.iso
  sudo $0 --health -d /dev/sdb
EOF
}

print_catalog() {
    printf '%s\n' "ISO download catalog (id -> distro):"
    printf '%s\n' "--------------------------------------------------------------"
    printf '%s\n' "$ISO_CATALOG" | awk -F'|' '{ printf "  %-14s %s\n", $1, $2 }'
    printf '%s\n' "--------------------------------------------------------------"
    printf '  Use:  sudo %s --download <id>\n' "$0"
}

parse_args() {
    while (( $# )); do
        case $1 in
            -i|--iso)    ISO=${2:-}; shift 2 ;;
            -d|--device) DEV=${2:-}; shift 2 ;;
            -m|--mode)   MODE=${2:-}; MODE_SET=1; shift 2 ;;
            -p|--part)   SCHEME=${2:-}; SCHEME_SET=1; shift 2 ;;
            -f|--fs)     FS=${2:-}; FS_SET=1; shift 2 ;;
            -L|--label)  VOLLBL=${2:-}; VOLLBL_SET=1; shift 2 ;;
            --storage)     VENTOY_STORAGE_FS=${2:-}; shift 2 ;;
            --persist)     PERSIST_MB=${2:-}; shift 2 ;;
            --download-dir) DL_DEFAULT_DIR=${2:-}; shift 2 ;;
            --download)
                 ACTION=download
                 if [[ ${2:-} != -* && -n ${2:-} ]]; then DL_ID=$2; shift; fi
                 shift ;;
            --list-downloads) ACTION=list-catalog; shift ;;
            --verify-iso)   ACTION=verifyiso; VERIFY_FILE=${2:-}; shift 2 ;;
            --gui)          ACTION=gui; shift ;;
            --ventoy)         ACTION=ventoy; shift ;;
            --ventoy-prepare) ACTION=ventoy-prepare; shift ;;
            --ventoy-add)     ACTION=ventoy-add; ADD_ISO=${2:-}; shift 2 ;;
            --ventoy-remove)  ACTION=ventoy-remove; shift ;;
            --ventoy-rescan)  ACTION=ventoy-rescan; shift ;;
            --ventoy-list)    ACTION=ventoy-list; shift ;;
            --health)         ACTION=health; shift ;;
            --verify)    DO_VERIFY=1; shift ;;
            --no-eject)  FINALIZE_EJECT=0; shift ;;
            -y|--yes)    ASSUME_YES=1; shift ;;
            -h|--help)   usage; exit 0 ;;
            *) err "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
    [[ $MODE  =~ ^(auto|dd|part)$    ]] || die "--mode: auto|dd|part"
    [[ $SCHEME =~ ^(mbr|gpt)$        ]] || die "--part: mbr|gpt"
    [[ $FS    =~ ^(auto|fat32|ntfs|ext4)$ ]] || die "--fs: auto|fat32|ntfs|ext4"
    [[ $VENTOY_STORAGE_FS =~ ^(ext4|ntfs)$ ]] || die "--storage: ext4|ntfs"
    [[ -n $PERSIST_MB ]] && { [[ $PERSIST_MB =~ ^[0-9]+$ ]] || die "--persist: MB number chahiye"; }
    [[ -n $DEV && $DEV != /* ]] && DEV="/dev/$DEV"
}

main() {
    parse_args "$@"        # --help yahin exit kar deta hai (root ki zaroorat nahi)

    # root ki zaroorat nahi wale actions
    if [[ $ACTION == list-catalog ]]; then
        print_catalog
        exit 0
    fi

    # GUI wizard ko bina root ke chalaya ja sakta hai -- browsing (ISO/device/mode
    # pick) sab read-only hai.  Actual write pe wo khud pkexec se escalate karta
    # hai, ya fir "sudo ... --gui" dikhata hai.
    if [[ $ACTION != gui || ${RUFUS_ESCALATED:-0} == 1 ]]; then
        require_root "$@"
    fi
    check_base_deps

    case $ACTION in
        menu)
            interactive_menu ;;
        gui)
            gui_wizard ;;
        download)
            if [[ -n $DL_ID ]]; then dl_run_id "$DL_ID"; else dl_menu; fi ;;
        verifyiso)
            [[ -n $VERIFY_FILE ]] || die "--verify-iso <file> chahiye"
            ensure_tmpdir
            dl_verify_existing "$VERIFY_FILE" ;;
        ventoy)
            ventoy_menu ;;
        ventoy-prepare)
            [[ -n $DEV ]] || die "--ventoy-prepare ke liye -d <device> chahiye"
            assert_safe_device
            confirm_write "multi-ISO"
            ensure_tmpdir
            ventoy_prepare "$DEV" "$SCHEME" "$VENTOY_STORAGE_FS" ;;
        ventoy-add)
            [[ -n $ADD_ISO ]] || die "--ventoy-add <iso> chahiye"
            ventoy_add_iso "${DEV:-}" "$ADD_ISO" ;;
        ventoy-remove)  ventoy_remove_iso "${DEV:-}" ;;
        ventoy-rescan)  ventoy_rescan "${DEV:-}" ;;
        ventoy-list)    ventoy_list "${DEV:-}" ;;
        health)
            health_menu ;;
        *)
            die "Unknown action: $ACTION" ;;
    esac
}

