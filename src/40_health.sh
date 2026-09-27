# ------------------------------------------------------------------------------
#  MODULE: Drive health, speed test, aur QEMU boot test
#
#  1) Info        -- model, serial, transport, size, removable kya hai
#  2) SMART       -- smartctl se health (PASSED/FAILED), reallocated sectors,
#                    temperature, power-on hours
#  3) Read speed  -- 256MB padh kar MB/s (SAFE, kuch bigadta nahi)
#  4) Write speed -- 128MB likh kar MB/s (DESTRUCTIVE -- confirm maangta hai)
#  5) Bad blocks  -- badblocks read-only scan (slow but SAFE)
#  6) Boot test   -- QEMU me USB ko boot karke dekhna (BIOS / UEFI)
# ------------------------------------------------------------------------------

health_find_ovmf() {
    local c
    for c in \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd \
        /usr/share/edk2-ovmf/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE_4M.fd \
        /usr/share/qemu/ovmf-x86_64-code.bin \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd
    do
        [[ -f $c ]] && { echo "$c"; return 0; }
    done
    return 1
}

# --------------------------- info ---------------------------------------------
health_info() {                  # $1=dev
    local dev=$1
    echo
    printf '%s\n' "${C_B}  -------- Drive info --------${C_RST}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINT,MODEL,SERIAL,TRAN,RM,HOTPLUG "$dev" 2>/dev/null | sed 's/^/  /'
    echo
    printf '  %-16s %s\n' "Block size"  "$(blockdev --getbsz "$dev" 2>/dev/null || echo '?') bytes"
    printf '  %-16s %s\n' "Total bytes" "$(blockdev --getsize64 "$dev" 2>/dev/null || echo '?')"
    printf '  %-16s %s\n' "Removable"   "$(cat "/sys/block/${dev##*/}/removable" 2>/dev/null || echo '?')"
    printf '  %-16s %s\n' "USB?"        "$(is_usb_like "${dev##*/}" && echo yes || echo no)"
    local ro=$(cat "/sys/block/${dev##*/}/ro" 2>/dev/null || echo '?')
    printf '  %-16s %s\n' "Read-only"   "$ro"
    local st
    st=$(smartctl -i -d sat "$dev" 2>/dev/null | grep -iE 'Serial Number|Device Model|Model Number|Firmware Version' | sed 's/^/    /')
    [[ -n $st ]] && { echo; printf '  %sIdentify:%s\n' "$C_DIM" "$C_RST"; echo "$st"; }
    echo
}

# --------------------------- SMART --------------------------------------------
health_smart() {                 # $1=dev
    local dev=$1
    if ! have smartctl; then
        warn "smartctl nahi mila. Install:  sudo apt install smartmontools  (ya dnf/pacman)"
        return 1
    fi
    echo
    printf '%s\n' "${C_B}  -------- SMART health --------${C_RST}"

    local out="" rc=0
    # USB drives ke liye aksar '-d sat' chahiye; fail ho to plain try karo
    out=$(smartctl -a -d sat "$dev" 2>&1); rc=$?
    if (( rc & 1 )) || grep -qiE 'Permission denied|Unknown USB|try without' <<<"$out"; then
        out=$(smartctl -a "$dev" 2>&1); rc=$?
    fi

    if (( rc & 1 )) && ! grep -qiE 'SMART support is available|SMART overall-health' <<<"$out"; then
        warn "SMART data nahi mila (kai USB pen drives SMART support nahi karti)."
        grep -iE 'error|denied|unknown|available' <<<"$out" | sed 's/^/    /' | head -4
        return 1
    fi

    local result
    result=$(grep -iE 'SMART overall-health self-assessment test result' <<<"$out" | head -1 | sed 's/.*: *//')
    if [[ -n $result ]]; then
        case ${result^^} in
            PASSED|OK) printf '  Health      : %s%s%s\n' "$C_GRN" "$result" "$C_RST" ;;
            *)         printf '  Health      : %s%s%s\n' "$C_RED" "$result" "$C_RST" ;;
        esac
    else
        printf '  Health      : %s(pata nahi chala)%s\n' "$C_YLW" "$C_RST"
    fi

    local kv
    for kv in "Reallocated_Sector_Ct" "Current_Pending_Sector" "Offline_Uncorrectable" \
              "Reallocated_Event_Ct" "Percentage Used" "Wear_Leveling_Count" \
              "Power_On_Hours" "Temperature_Celsius" "Temperature:" "Media_Wearout_Indicator"; do
        local line
        line=$(grep -E "^[[:space:]]*${kv}[[:space:]]" <<<"$out" | head -1)
        [[ -z $line ]] && line=$(grep -iE "^[[:space:]]*${kv//:/}[[:space:]]*:" <<<"$out" | head -1)
        [[ -z $line ]] && continue
        printf '  %s\n' "$(echo "$line" | sed -E 's/[[:space:]]+/ /g; s/^ //')"
    done

    # khaas warnings
    local realloc pending
    realloc=$(grep -E 'Reallocated_Sector_Ct' <<<"$out" | head -1 | awk '{print $(NF-1)}')
    pending=$(grep -E 'Current_Pending_Sector' <<<"$out" | head -1 | awk '{print $(NF-1)}')
    [[ $realloc =~ ^[0-9]+$ && $realloc -gt 0 ]] && \
        warn "Reallocated sectors = $realloc  ->  drive murjhha rahi hai. Data mat rakho isme."
    [[ $pending =~ ^[0-9]+$ && $pending -gt 0 ]] && \
        warn "Pending sectors = $pending  ->  bad blocks hain. Drive badal do."
    echo
}

# --------------------------- speed --------------------------------------------
_health_speed_dd() {             # $1=dev $2=read|write $3=count_mb
    local dev=$1 dir=$2 mb=$3
    local bytes=$(( mb * 1048576 ))
    local t0 t1 ns bps

    sync
    t0=$(date +%s%N)
    if [[ $dir == read ]]; then
        dd if="$dev" of=/dev/null bs=1M count="$mb" iflag=direct status=none 2>/dev/null \
        || dd if="$dev" of=/dev/null bs=1M count="$mb" status=none 2>/dev/null
    else
        dd if=/dev/zero of="$dev" bs=1M count="$mb" conv=fsync status=none 2>/dev/null
    fi
    local rc=$?
    t1=$(date +%s%N)
    (( rc != 0 )) && return $rc

    ns=$(( t1 - t0 ))
    (( ns <= 0 )) && ns=1
    bps=$(( bytes * 1000000000 / ns ))
    local kbs=$(( bps / 1024 ))
    printf '  %-6s %s MB in %.2fs  ->  %s\n' "$dir" "$mb" "$(awk -v n="$ns" 'BEGIN{printf "%.2f", n/1e9}')" \
        "$(human "$bps")/s  (${kbs} KB/s)"
}

health_read_speed() {            # $1=dev
    echo
    printf '%s\n' "${C_B}  -------- Read speed (safe) --------${C_RST}"
    _health_speed_dd "$1" read 256 || warn "Read test fail."
}

health_write_speed() {           # $1=dev  -- DESTRUCTIVE
    local dev=$1
    echo
    printf '%s\n' "${C_YLW}${C_B}  -------- Write speed (DESTRUCTIVE!) --------${C_RST}"
    warn "Is test me device ke shuru ke 128 MB PAR likha jayega."
    warn "Agar USB pe bootable data hai to WO KHRAB ho jayega."
    if (( ! ASSUME_YES )); then
        printf '%s' "  Phir bhi chalana hai? type karo 'yes': "
        local a; read -r a || return 1
        [[ $a == yes ]] || { warn "Skip."; return 1; }
    fi
    _health_speed_dd "$dev" write 128 || warn "Write test fail."
}

health_badblocks() {             # $1=dev  -- read-only, SLOW
    local dev=$1
    echo
    printf '%s\n' "${C_B}  -------- Bad blocks (read-only scan) --------${C_RST}"
    if ! have badblocks; then
        warn "badblocks nahi mila: sudo apt install e2fsprogs"
        return 1
    fi
    local szmb=$(( $(blockdev --getsize64 "$dev" 2>/dev/null || echo 0) / 1048576 ))
    warn "Ye scan SLOW ho sakta hai (device size: ${szmb} MB)."
    warn "Read-only hai -- kuch delete nahi hoga, lekin pura device padhna padega."
    if (( ! ASSUME_YES )); then
        printf '%s' "  Chalana hai? [y/N]: "
        local a; read -r a || return 1
        [[ $a == y || $a == Y ]] || { warn "Skip."; return 1; }
    fi
    echo
    if badblocks -sv "$dev"; then
        info "Scan complete -- koi bad block nahi mila (ya upar list hai)."
    else
        local rc=$?
        err "badblocks ne problems dikhayin (rc=$rc). Neeche 'x' wale blocks = kharab."
        return $rc
    fi
}

# --------------------------- QEMU boot test -----------------------------------
health_boot_test() {             # $1=dev
    local dev=$1
    echo
    printf '%s\n' "${C_B}  -------- QEMU boot test --------${C_RST}"

    if ! have qemu-system-x86_64; then
        warn "qemu-system-x86_64 nahi mila."
        err "  Debian/Ubuntu: sudo apt install qemu-system-x86 qemu-utils"
        err "  Fedora       : sudo dnf install qemu-system-x86"
        err "  Arch         : sudo pacman -S qemu-system-x86"
        return 1
    fi
    if [[ -z ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
        warn "Display nahi mila ($DISPLAY/$WAYLAND_DISPLAY) -- graphical boot test nahi chal sakta."
        warn "Graphical session me chalao, ya seedhe real machine par test karo."
        return 1
    fi

    local kopt=""
    if [[ -r /dev/kvm ]]; then kopt="-enable-kvm"; info "KVM: haan (fast)"; else info "KVM: nahi (software emulation -- dheere chalega)"; fi

    local mode
    printf '  Mode [1=BIOS/SeaBIOS, 2=UEFI/OVMF] (ENTER=1): '
    read -r mode; mode=${mode:-1}

    local biosopt=()
    if [[ $mode == 2 ]]; then
        local ovmf; ovmf=$(health_find_ovmf) || {
            warn "OVMF (UEFI firmware) nahi mila."
            err "  Debian/Ubuntu: sudo apt install ovmf     (Fedora: edk2-ovmf, Arch: edk2-ovmf)"
            return 1
        }
        info "UEFI firmware: $ovmf"
        biosopt=(-bios "$ovmf")
    fi

    info "QEMU window khul raha hai... USB boot karke dekho. Band karne ke liye window band karo."
    printf '  Command: qemu-system-x86_64 ...\n\n'

    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -m 2048 \
        $kopt \
        "${biosopt[@]}" \
        -drive "file=$dev,format=raw,if=ide,index=0,media=disk" \
        -boot order=c,menu=on \
        -rtc base=localtime \
        -name "rufus-linux boot test" \
        &
    local qpid=$!
    printf '  QEMU PID %s -- window band karne par test khatam.\n' "$qpid"
    wait "$qpid" 2>/dev/null
    info "Boot test khatam."
}

# --------------------------- menu ---------------------------------------------
health_menu() {
    local c
    while true; do
        [[ -t 1 ]] && printf '\033[H\033[2J'
        banner
        printf '%s\n' "  DRIVE HEALTH + BOOT TEST"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  Target device : %s\n' "${DEV:-<none -- pehle device chuno>}"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  %s[1]%s  Device select karo\n' "$C_B" "$C_RST"
        printf '  %s[2]%s  Drive info\n' "$C_B" "$C_RST"
        printf '  %s[3]%s  SMART health check\n' "$C_B" "$C_RST"
        printf '  %s[4]%s  Read speed test   (safe)\n' "$C_B" "$C_RST"
        printf '  %s[5]%s  Write speed test  (%sDESTRUCTIVE%s)\n' "$C_B" "$C_RST" "$C_RED" "$C_RST"
        printf '  %s[6]%s  Bad blocks scan   (read-only, slow)\n' "$C_B" "$C_RST"
        printf '  %s[7]%s  QEMU boot test    (USB ko emulator me boot karo)\n' "$C_B" "$C_RST"
        printf '  %s[8]%s  Sab kuch chalao   (info + SMART + read speed)\n' "$C_B" "$C_RST"
        printf '  %s[9]%s  Wapas main menu\n' "$C_B" "$C_RST"
        printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
        printf '  Choice: '
        read -r c || return 0
        case $c in
            1) pick_device || true; printf '  ENTER...'; read -r _ ;;
            2) [[ -n ${DEV:-} ]] && health_info "$DEV"   || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            3) [[ -n ${DEV:-} ]] && health_smart "$DEV"  || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            4) [[ -n ${DEV:-} ]] && health_read_speed "$DEV"  || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            5) [[ -n ${DEV:-} ]] && health_write_speed "$DEV" || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            6) [[ -n ${DEV:-} ]] && health_badblocks "$DEV"   || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            7) [[ -n ${DEV:-} ]] && health_boot_test "$DEV"   || warn "pehle device chuno"; printf '  ENTER...'; read -r _ ;;
            8)
                [[ -z ${DEV:-} ]] && { warn "pehle device chuno"; printf '  ENTER...'; read -r _; continue; }
                health_info "$DEV"; health_smart "$DEV"; health_read_speed "$DEV"
                printf '  ENTER...'; read -r _
                ;;
            9|q|Q) return 0 ;;
        esac
    done
}
