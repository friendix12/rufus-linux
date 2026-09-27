# ------------------------------------------------------------------------------
#  MODULE: ISO downloader + checksum (SHA256/SHA512/MD5) verify
#
#  Design: har distro ke liye ek ROOT directory + discovery regex rakha hai,
#  seedha version hardcode NAHI. Isse URL rot (naya release aana) khud fix ho
#  jata hai -- script listing scan karke latest file utha leti hai.
#
#  Catalog format (pipe separated):
#    ID|LABEL|ROOT_URL|DIR_RE|SUBPATH|ISO_REGEX|CSUM_FILES
#      DIR_RE   = agar non-empty, to ROOT me se is regex match wale subdirs me
#                 se sabse latest (version sort) chune
#      SUBPATH  = subdir ke baad ka path
#      CSUM_FILES = space separated candidates (glob allowed), tried in order
# ------------------------------------------------------------------------------

ISO_CATALOG=$(cat <<'CATALOG_EOF'
ubuntu26|Ubuntu 26.04 LTS Desktop (latest LTS)|https://releases.ubuntu.com/|^26\.04||^ubuntu-[0-9.]+-desktop-amd64\.iso$|SHA256SUMS
ubuntu24|Ubuntu 24.04 LTS Desktop|https://releases.ubuntu.com/|^24\.04||^ubuntu-[0-9.]+-desktop-amd64\.iso$|SHA256SUMS
ubuntu22|Ubuntu 22.04 LTS Desktop|https://releases.ubuntu.com/|^22\.04||^ubuntu-[0-9.]+-desktop-amd64\.iso$|SHA256SUMS
debian|Debian (netinst - chhoti, online install)|https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/|||^debian-[0-9.]+-amd64-netinst\.iso$|SHA256SUMS SHA512SUMS
debiandvd|Debian (full DVD-1 - offline install)|https://cdimage.debian.org/debian-cd/current/amd64/iso-dvd/|||^debian-[0-9.]+-amd64-DVD-1\.iso$|SHA256SUMS SHA512SUMS
fedora|Fedora Workstation Live (latest)|https://mirrors.kernel.org/fedora/releases/|^[0-9]+$|Workstation/x86_64/iso/|^Fedora-Workstation-Live-.*x86_64\.iso$|*CHECKSUM*
mint|Linux Mint Cinnamon 64-bit (latest)|https://mirrors.kernel.org/linuxmint/stable/|^[0-9]+\.[0-9]+$||^linuxmint-[0-9.]+-cinnamon-64bit\.iso$|sha256sum.txt SHA256SUMS
arch|Arch Linux (rolling, hamesha latest)|https://geo.mirror.pkgbuild.com/iso/latest/|||^archlinux-x86_64\.iso$|sha256sums.txt
kali|Kali Linux (latest)|https://cdimage.kali.org/|^kali-[0-9.]+$||^kali-linux-[0-9.]+-installer-amd64\.iso$|SHA256SUMS
tumbleweed|openSUSE Tumbleweed DVD|https://download.opensuse.org/tumbleweed/iso/|||^openSUSE-Tumbleweed-DVD-x86_64-.*\.iso$|SHA256SUMS
CATALOG_EOF
)

DL_DEFAULT_DIR="${DL_DEFAULT_DIR:-$HOME/Downloads}"

# --------------------------- HTTP helpers -------------------------------------
dl_fetch() {                     # URL -> stdout (text).  3 retries (mirror flakiness ke liye)
    local url=$1 out="" rc=1 i
    for i in 1 2 3; do
        if have curl; then
            out=$(curl -fsSL --max-time 90 --retry 2 "$url" 2>/dev/null); rc=$?
        elif have wget; then
            out=$(wget -qO- --timeout=90 --tries=2 "$url" 2>/dev/null); rc=$?
        else
            return 1
        fi
        if (( rc == 0 )) && [[ -n $out ]]; then
            printf '%s\n' "$out"
            return 0
        fi
        sleep 1
    done
    return 1
}

dl_content_length() {            # URL -> bytes (0 agar pata na chale)
    local url=$1 len
    if have curl;   then len=$(curl -fsSLI --max-time 30 "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
    elif have wget; then len=$(wget --spider --server-response -S "$url" 2>&1 | awk '/[Cc]ontent-[Ll]ength:/{v=$2} END{print v}')
    else len=0
    fi
    [[ $len =~ ^[0-9]+$ ]] && echo "$len" || echo 0
}

dl_hrefs() {                     # autoindex page ke hrefs -> lines
    local url=$1
    dl_fetch "$url" 2>/dev/null \
      | grep -oE 'href="[^"]+"' \
      | sed -e 's/^href="//' -e 's/"$//' \
      | sed -e 's|^\./||' \
      | grep -vE '^(\.\.|/|[a-zA-Z][a-zA-Z0-9+.-]*:|#|\?|mailto:|[[:space:]]*$)' \
      | sed 's/%20/ /g' \
      | sort -u || true
}

# --------------------------- discovery ----------------------------------------
# $1=root $2=dir_re $3=subpath $4=iso_re  ->  full ISO URL (rc!=1 agar nahi mila)
dl_resolve_iso_url() {
    local root=$1 dre=$2 sub=$3 isore=$4
    local -a cands=()

    if [[ -n $dre ]]; then
        local names
        names=$(dl_hrefs "$root" 2>/dev/null \
                | while IFS= read -r h; do
                      [[ $h == */ ]] || continue
                      local n=${h%/}
                      if [[ $n =~ $dre ]]; then echo "$n"; fi
                  done \
                | sort -rV)
        [[ -z $names ]] && return 1
        while IFS= read -r n; do
            [[ -z $n ]] && continue
            cands+=("${root}${n}/${sub}")
        done <<<"$names"
    else
        cands=("${root}${sub}")
    fi

    local c hit
    for c in "${cands[@]}"; do
        # version-sort: sabse latest (e.g. 24.04.5.1 > 24.04.4 > 24.04.3)
        hit=$(dl_hrefs "$c" 2>/dev/null | grep -E "$isore" | sort -Vr | head -1)
        [[ -z $hit ]] && continue
        # multiple match? sabse chhota (DVD1 jaise numbering me best) — already head -1
        printf '%s%s\n' "$c" "$hit"
        return 0
    done
    return 1
}

dl_url_exists() {                # $1=url -> rc 0 agar available
    local url=$1
    if have curl; then curl -fsIL --max-time 25 -o /dev/null "$url" 2>/dev/null
    else [[ -n $(dl_fetch "$url" 2>/dev/null | head -1) ]]
    fi
}

# $1=iso_url  $2=space separated specs -> checksum URL
# spec tokens:
#   <name>     = exact filename in the same directory
#   *glob*     = glob match against directory listing
# Agar spec se na mile to per-file convention try hota hai:
#   <iso>.sha256 / <iso>.sha512 / <iso>.md5
dl_pick_checksum_url() {
    local isourl=$1 spec=$2
    local dir=${isourl%/*}; dir=${dir%/}    # '.../dir' (bina slash)
    local hrefs
    hrefs=$(dl_hrefs "$dir/" 2>/dev/null)   # fetch ke liye trailing slash
    local s pat hit
    for s in $spec; do
        [[ $s == PERFILE ]] && continue
        if [[ $s == *[\*\?]* ]]; then
            pat=$(printf '%s' "$s" | sed -e 's/\./\\./g' -e 's/\*/.*/g' -e 's/\?/.*/g')
            hit=$(printf '%s\n' "$hrefs" | grep -E "^${pat}$" | head -1)
        else
            hit=$(printf '%s\n' "$hrefs" | grep -Fx -- "$s" | head -1)
        fi
        [[ -n $hit ]] && { printf '%s/%s\n' "$dir" "$hit"; return 0; }
    done

    # per-file convention (openSUSE, openSUSE-like mirrors, aur etc.)
    local c
    for c in .sha256 .sha512 .md5; do
        if dl_url_exists "${isourl}${c}"; then
            printf '%s%s\n' "$isourl" "$c"
            return 0
        fi
    done
    return 1
}

# --------------------------- download -----------------------------------------
dl_skip_if_same() {              # $1=url $2=out  -> 0 agar already complete
    local url=$1 out=$2 remote local_sz
    [[ -f $out ]] || return 1
    remote=$(dl_content_length "$url")
    [[ $remote == 0 ]] && return 1
    local_sz=$(stat -c '%s' "$out")
    [[ $remote == "$local_sz" ]]
}

dl_download() {                  # $1=url $2=out
    local url=$1 out=$2 rc=0
    local sz; sz=$(dl_content_length "$url")

    if dl_skip_if_same "$url" "$out"; then
        info "Already complete: $(basename "$out")"
        return 0
    fi

    info "Downloading: $(basename "$out")   $(human "$sz")"

    # GUI available ho to pulsate dialog kholo (terminal na hone par bhi pata chale)
    local opened=0
    if [[ -n ${GUI_TOOL:-} && ${GUI_PROGRESS:-0} -eq 0 ]]; then
        gui_progress_open "Download" "$(basename "$out")" 1 && opened=1
    fi
    local use_gui=${GUI_PROGRESS:-0}

    if have curl; then
        if (( use_gui )); then
            curl -fL --retry 3 --retry-delay 2 -C - -sS -o "$out" "$url"; rc=$?
        else
            curl -fL --retry 3 --retry-delay 2 -C - --progress-bar -o "$out" "$url"; rc=$?
            echo
        fi
    elif have wget; then
        wget -c -O "$out" "$url"; rc=$?
    else
        (( opened )) && gui_progress_close
        die "curl ya wget chahiye (download ke liye)."
    fi
    (( opened )) && gui_progress_close

    (( rc != 0 )) && { err "Download fail (curl/wget rc=$rc). URL check karo / proxy dekho."; return $rc; }

    local got; got=$(stat -c '%s' "$out")
    if (( sz > 0 && got != sz )); then
        err "Size mismatch: expected $(human "$sz"), got $(human "$got")"
        return 1
    fi
    return 0
}

# --------------------------- checksum verify ----------------------------------
# $1=csumfile  $2=target filename -> hash (ya empty)
# Agar target na mile aur file me exactly 1 hash line ho to wohi chalta hai
# (openSUSE ke per-file .sha256 me filename snapshot ka hota hai, -Current nahi).
dl_extract_hash() {
    awk -v target="$2" '
    {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[0-9a-fA-F]+[ \t]+/) {
            n = split(line, a, /[ \t]+/)
            h = a[1]
            if (length(h) >= 32 && length(h) <= 128 && h ~ /^[0-9a-fA-F]+$/) {
                name = a[2]
                sub(/^\*/, "", name)
                sub(/^\.\//, "", name)
                cnt++; H[cnt] = h; N[cnt] = name
            }
        } else if (index(line, "(") > 0 && index(line, ")") > 0 && index(line, "=") > 0) {
            s = line
            sub(/^[^(]*\(/, "", s)
            nm = s
            sub(/\).*/, "", nm)
            hh = line
            sub(/.*=[ \t]*/, "", hh)
            sub(/[ \t]+$/, "", hh)
            if (nm != "" && length(hh) >= 32 && hh ~ /^[0-9a-fA-F]+$/) {
                cnt++; H[cnt] = hh; N[cnt] = nm
            }
        }
    }
    END {
        for (i = 1; i <= cnt; i++) if (N[i] == target) { print tolower(H[i]); exit }
        if (cnt == 1) print tolower(H[1])
    }' "$1"
}

dl_algo_for() {                  # hash length -> command
    case ${#1} in
        32)  echo md5sum ;;
        40)  echo sha1sum ;;
        64)  echo sha256sum ;;
        128) echo sha512sum ;;
        *)   echo "" ;;
    esac
}

# $1=file  $2=local checksum file  -> 0 ok, 1 mismatch, 2 no csum
dl_verify_file() {
    local f=$1 csum=$2
    local base; base=$(basename "$f")

    [[ -f $csum ]] || { warn "Checksum file nahi mili: $csum"; return 2; }

    local want; want=$(dl_extract_hash "$csum" "$base")
    if [[ -z $want ]]; then
        warn "Checksum file me '$base' entry nahi mili ($csum)"
        return 2
    fi

    local algo; algo=$(dl_algo_for "$want")
    if [[ -z $algo ]]; then
        warn "Unknown hash length (${#want}) -- verify skip."
        return 2
    fi

    info "Verifying ($algo) ... yeh 5-60 sec le sakta hai"
    local got
    got=$($algo "$f" | awk '{print tolower($1)}')

    if [[ $got == "$want" ]]; then
        info "CHECKSUM OK  ($(human "$(stat -c '%s' "$f")"))  $algo=$got"
        return 0
    fi
    err "CHECKSUM MISMATCH!"
    err "  expected: $want"
    err "  got     : $got"
    return 1
}

# $1=file  $2=csum_url  -> 0 ok, 1 mismatch, 2 no csum
dl_verify() {
    local f=$1 url=$2
    ensure_tmpdir
    local tmp="$TMPDIR_P/dl-csum.$$"

    if ! dl_fetch "$url" > "$tmp" 2>/dev/null || [[ ! -s $tmp ]]; then
        rm -f "$tmp"
        warn "Checksum file download nahi hua: $url"
        return 2
    fi

    local rc=0
    dl_verify_file "$f" "$tmp"
    rc=$?
    rm -f "$tmp"
    return $rc
}

# Local folder me checksum file dhoondta hai (pehle se download kiya ISO)
dl_find_local_csum() {           # $1=iso file -> path
    local f=$1
    local dir=${f%/*} base=${f##*/}
    [[ $dir == "$f" ]] && dir=.
    local s
    for s in SHA256SUMS SHA256SUM sha256sum.txt sha256sums.txt SHA512SUMS sha512sum.txt; do
        [[ -f $dir/$s ]] && { printf '%s\n' "$dir/$s"; return 0; }
    done
    [[ -f $f.sha256 ]] && { printf '%s\n' "$f.sha256"; return 0; }
    [[ -f $f.sha512 ]] && { printf '%s\n' "$f.sha512"; return 0; }
    local g
    for g in "$dir"/*CHECKSUM* "$dir"/*-SHA256SUMS; do
        [[ -f $g ]] && { printf '%s\n' "$g"; return 0; }
    done
    return 1
}

# --------------------------- CLI / menu ---------------------------------------
dl_catalog_count() { printf '%s\n' "$ISO_CATALOG" | grep -c . ; }

dl_entry() {                     # $1=id -> line (empty if not found)
    printf '%s\n' "$ISO_CATALOG" | awk -F'|' -v id="$1" '$1==id {print; exit}'
}

dl_menu() {
    local items=() i=1 line id label
    echo
    printf '%s\n' "${C_B}  ISO Download + SHA verify${C_RST}"
    printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"
    while IFS='|' read -r id label _rest; do
        [[ -z $id ]] && continue
        items+=("$id")
        printf '  %s[%2d]%s  %s\n' "$C_B" "$i" "$C_RST" "$label"
        i=$((i+1))
    done <<< "$ISO_CATALOG"
    printf '  %s[%2d]%s  Custom URL (khud paste karo)\n' "$C_B" "$i" "$C_RST"
    local custom_idx=$i
    printf '%s\n' "${C_DIM}  ------------------------------------------------------------------------${C_RST}"

    local ans
    printf '  Choice (ENTER=cancel): '
    read -r ans || return 1
    [[ -z $ans ]] && return 1
    [[ $ans =~ ^[0-9]+$ ]] || { warn "Ghalat choice."; return 1; }

    local idp="" url="" outdir="$DL_DEFAULT_DIR"
    if (( ans == custom_idx )); then
        printf '  ISO URL paste karo: '
        read -r url || return 1
        [[ -z $url ]] && return 1
    else
        (( ans < 1 || ans > ${#items[@]} )) && { warn "Ghalat choice."; return 1; }
        idp=${items[ans-1]}
    fi

    printf '  Download folder [%s]: ' "$DL_DEFAULT_DIR"
    read -r outdir; outdir=${outdir:-$DL_DEFAULT_DIR}
    mkdir -p "$outdir" || die "Folder nahi bana: $outdir"

    ensure_tmpdir

    if [[ -z $url ]]; then
        local line; line=$(dl_entry "$idp")
        [[ -z $line ]] && die "catalog entry nahi mili: $idp"
        local IFS='|' root dre sub isore cspec
        read -r _id _label root dre sub isore cspec <<<"$line"
        unset IFS
        info "Resolving latest ISO for: $_label"
        url=$(dl_resolve_iso_url "$root" "$dre" "$sub" "$isore") \
            || die "ISO resolve nahi hua (network ya URL change ho gaya).
        -> Custom URL option use karo, ya catalog src/10_downloader.sh me update karo."
        info "URL: $url"
        dl_do_download "$url" "$outdir" "$cspec"
    else
        dl_do_download "$url" "$outdir" "SHA256SUMS SHA256SUM sha256sum.txt SHA512SUMS"
    fi
}

dl_do_download() {               # $1=url $2=outdir $3=csum specs
    local url=$1 outdir=$2 cspec=${3:-}
    local name=${url%%\?*}; name=${name##*/}
    local out="$outdir/$name"

    [[ -f $out ]] && warn "File pehle se hai (resume/skip): $out"

    if ! dl_download "$url" "$out"; then
        return 1
    fi

    # checksum
    local curl_, rc=2
    if [[ -n $cspec ]]; then
        if curl_=$(dl_pick_checksum_url "$url" "$cspec"); then
            dl_verify "$out" "$curl_"
            rc=$?
        else
            warn "Checksum file nahi mili (directory listing me nahi tha)."
            rc=2
        fi
    fi
    unset curl_

    echo
    printf '  %-10s %s\n' "File" "$out"
    printf '  %-10s %s\n' "Size" "$(human "$(stat -c '%s' "$out")")"
    case $rc in
        0) printf '  %-10s %s\n' "Verify" "${C_GRN}PASS${C_RST}" ;;
        1) printf '  %-10s %s\n' "Verify" "${C_RED}FAIL -- file delete karke dobara download karo${C_RST}"; return 1 ;;
        *) printf '  %-10s %s\n' "Verify" "${C_YLW}SKIPPED (checksum nahi mila)${C_RST}" ;;
    esac
    echo
    info "Ab yeh ISO rufus-linux.sh me use kar sakte ho:"
    printf '    sudo %s -i "%s" -d /dev/sdX\n' "$0" "$out"
    ISO="$out"
    return 0
}

# sirf verify (pehle se download kiya hua)
dl_verify_existing() {           # $1=iso file (local)
    local f=$1
    [[ -f $f ]] || die "File nahi mili: $f"
    ensure_tmpdir
    local csum
    if csum=$(dl_find_local_csum "$f"); then
        info "Checksum file: $csum"
        dl_verify_file "$f" "$csum"
        return $?
    fi
    # local me nahi mila -> remote try karo (folder ka listing nahi hota, isliye URL guess)
    warn "Usi folder me checksum file nahi mili."
    warn "  Agar internet hai to '*.sha256' / SHA256SUMS khud download karke"
    warn "  rufus-linux.sh ke saath rakh do, phir dobara chalao."
    return 2
}

# seedha catalog id se download:  sudo ./rufus-linux.sh --download ubuntu26
dl_run_id() {                    # $1=id
    local id=$1
    local line; line=$(dl_entry "$id")
    if [[ -z $line ]]; then
        err "Unknown id: '$id'"
        print_catalog
        exit 1
    fi
    local IFS='|'
    local _id _label root dre sub isore cspec
    read -r _id _label root dre sub isore cspec <<<"$line"
    unset IFS

    ensure_tmpdir
    info "Distro : $_label"
    info "Resolving latest ISO ..."
    local url
    if ! url=$(dl_resolve_iso_url "$root" "$dre" "$sub" "$isore"); then
        die "ISO resolve nahi hua (network problem, ya mirror/layout badal gaya).
     -> 'sudo $0 --download' (menu) try karo, ya khud URL se download karke
        '--verify-iso' se check kar lo."
    fi
    info "URL    : $url"
    mkdir -p "$DL_DEFAULT_DIR" || die "Folder nahi bani: $DL_DEFAULT_DIR"
    dl_do_download "$url" "$DL_DEFAULT_DIR" "$cspec"
}
