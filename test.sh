#!/usr/bin/env bash
# rufus-linux.sh ke function-level tests (root ki zaroorat nahi)
set -u
export RUFUS_LINUX_LIB=1
# shellcheck source=../rufus-linux.sh
source "$(dirname "$0")/rufus-linux.sh"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
chk()  { [[ "$2" == "$3" ]] && ok "$1  -> '$2'" || bad "$1  got='$2' want='$3'"; }

echo "== human() =="
chk "0 B"        "$(human 0)"          "0 B"
chk "1023 B"     "$(human 1023)"       "1023 B"
chk "1 KiB"      "$(human 1024)"       "1 KiB"
chk "1 MiB"      "$(human 1048576)"    "1.00 MiB"
chk "1 GiB"      "$(human 1073741824)" "1.00 GiB"
chk "3.50 GiB"   "$(human 3758096384)" "3.50 GiB"

echo "== sanitize_label() =="
# FAT32 label rules: sirf A-Z 0-9 _ -, max 11 chars
ISO="/tmp/Ubuntu 22.04 LTS.iso"
chk "label auto"   "$(sanitize_label "")"        "UBUNTU2204L"
chk "label custom" "$(sanitize_label "my usb!")" "MYUSB"
chk "label 11lim"  "$(sanitize_label "ABCDEFGHIJKLMNOP")" "ABCDEFGHIJK"
VOLLBL=""; ISO="/tmp/x.iso"
chk "fallback"     "$(sanitize_label "")"        "X"

echo "== is_hybrid_iso() =="
hyb=$(mktemp); non=$(mktemp)
dd if=/dev/urandom of="$hyb" bs=512 count=1 status=none
printf '\x55\xaa' | dd of="$hyb" bs=1 seek=510 conv=notrunc status=none
dd if=/dev/urandom of="$non" bs=512 count=1 status=none
ISO="$hyb"; is_hybrid_iso && ok "55aa signature -> hybrid" || bad "55aa signature -> hybrid"
ISO="$non"; is_hybrid_iso && bad "random -> NOT hybrid" || ok "random -> NOT hybrid"
rm -f "$hyb" "$non"

echo "== partition naming =="
# make_partition ka naming logic (device name -> partition name)
nm() { local d=$1; if [[ ${d##*/} =~ [0-9]$ ]]; then echo "${d}p1"; else echo "${d}1"; fi; }
chk "/dev/sdb"   "$(nm /dev/sdb)"   "/dev/sdb1"
chk "/dev/sdc"   "$(nm /dev/sdc)"   "/dev/sdc1"
chk "nvme0n1"    "$(nm /dev/nvme0n1)" "/dev/nvme0n1p1"
chk "mmcblk0"    "$(nm /dev/mmcblk0)" "/dev/mmcblk0p1"

echo "== top_disk_name() =="
src=$(findmnt -n -o SOURCE / 2>/dev/null)
echo "  info: root SOURCE=$src  -> top disk = $(root_disk_name)"
[[ -n $(root_disk_name) ]] && ok "root_disk_name return karta hai" || bad "root_disk_name khaali"

echo "== progress bar rendering =="
out=$(draw_bar 50 100 "Writing")
printf '%s\n' "$out" | grep -q '50%' && ok "bar 50% render" || bad "bar 50% render"

echo "== assert_safe_device() safety guards =="
# NOTE: yeh checks root ke bina chalti hain (sirf read-only lsblk/findmnt)
safety_must_refuse() {
    local dev=$1 desc=$2
    DEV=$dev
    local out rc
    out=$(assert_safe_device 2>&1 </dev/null); rc=$?
    if (( rc != 0 )); then ok "refuses $desc ($dev)"; else bad "refuses $desc ($dev) -- ACCEPTED!"; fi
}
rootd=$(root_disk_name)
safety_must_refuse "/dev/$rootd"     "root disk"
safety_must_refuse "/dev/loop0"      "loop device"
safety_must_refuse "/dev/notexist"   "non-existent path"
safety_must_refuse "/dev/zram0"      "zram device"
DEV=""

echo "== downloader: dl_extract_hash() =="
H64a=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
H64b=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
cf=$(mktemp)
printf '%s  %s\n%s *%s\n' "$H64a" "ubuntu-26.04.1-desktop-amd64.iso" "$H64b" "other.iso" > "$cf"
chk "standard 'hash  name'"   "$(dl_extract_hash "$cf" "ubuntu-26.04.1-desktop-amd64.iso")" "$H64a"
chk "star  'hash *name'"      "$(dl_extract_hash "$cf" "other.iso")"                        "$H64b"
chk "unknown name -> empty"   "$(dl_extract_hash "$cf" "nope.iso")"                          ""

cat > "$cf" <<E
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

# Fedora-Workstation-Live-44-1.7.x86_64.iso: 2851612672 bytes
SHA256 (Fedora-Workstation-Live-44-1.7.x86_64.iso) = $H64a
-----BEGIN PGP SIGNATURE-----
E
chk "Fedora 'SHA256 (name) = h'" "$(dl_extract_hash "$cf" "Fedora-Workstation-Live-44-1.7.x86_64.iso")" "$H64a"

# single-line fallback (openSUSE: file me naam snapshot ka hota hai)
printf '%s  %s\n' "$H64b" "openSUSE-Tumbleweed-DVD-x86_64-Snapshot20260923-Media.iso" > "$cf"
chk "single-line fallback"    "$(dl_extract_hash "$cf" "openSUSE-Tumbleweed-DVD-x86_64-Current.iso")" "$H64b"
rm -f "$cf"

echo "== downloader: dl_algo_for() =="
chk "64 -> sha256sum"  "$(dl_algo_for "$H64a")"          "sha256sum"
chk "128 -> sha512sum" "$(dl_algo_for "$(printf 'a%.0s' {1..128})")" "sha512sum"
chk "32 -> md5sum"     "$(dl_algo_for "$(printf 'a%.0s' {1..32})")"  "md5sum"
chk "bad len -> empty" "$(dl_algo_for "abc")"            ""

echo "== downloader: catalog integrity =="
badf=$(printf '%s\n' "$ISO_CATALOG" | awk -F'|' 'NF!=7 || $1=="" || $2=="" || $7=="" {print $1}')
[[ -z $badf ]] && ok "har entry 7 fields (id|label|root|dirre|sub|isore|csum)" || bad "field problem: $badf"
dups=$(printf '%s\n' "$ISO_CATALOG" | awk -F'|' '{print $1}' | sort | uniq -d)
[[ -z $dups ]] && ok "ids unique" || bad "duplicate ids: $dups"
[[ -n $(dl_entry ubuntu26) ]] && ok "dl_entry ubuntu26" || bad "dl_entry ubuntu26"
[[ -z $(dl_entry zzz-nope) ]] && ok "dl_entry unknown -> empty" || bad "dl_entry unknown"

echo "== downloader: offline listing discovery (fake mirror) =="
__orig_dl_fetch=$(declare -f dl_fetch)     # original definition save (restore ke liye)
dl_fetch() {
    case $1 in
        https://fake.test/rel/)
            printf '%s\n' '<a href="../">Parent</a>' '<a href="./">.</a>' \
                          '<a href="22.04/">22.04/</a>' '<a href="24.04.5/">24.04.5/</a>' \
                          '<a href="24.04.5.1/">24.04.5.1/</a>' '<a href="26.04.1/">26.04.1/</a>' ;;
        https://fake.test/rel/24.04.5.1/)
            printf '%s\n' '<a href="./ubuntu-24.04.3-desktop-amd64.iso">a</a>' \
                          '<a href="./ubuntu-24.04.5.1-desktop-amd64.iso">b</a>' \
                          '<a href="./ubuntu-24.04.4-desktop-amd64.iso">c</a>' \
                          '<a href="./ubuntu-24.04.5.1-desktop-amd64.iso.torrent">d</a>' \
                          '<a href="SHA256SUMS">s</a>' ;;
        *) return 1 ;;
    esac
}
hs=$(dl_hrefs https://fake.test/rel/)
printf '%s\n' "$hs" | grep -qFx '24.04.5.1/' && ok "'./' prefix strip" || bad "'./' prefix strip"
printf '%s\n' "$hs" | grep -qFx '../' && bad "'../' skip" || ok "'../' skip"
u=$(dl_resolve_iso_url https://fake.test/rel/ '^24\.04' '' '^ubuntu-[0-9.]+-desktop-amd64\.iso$')
chk "latest dir + latest iso" "$u" \
    "https://fake.test/rel/24.04.5.1/ubuntu-24.04.5.1-desktop-amd64.iso"
chk "checksum from same dir" "$(dl_pick_checksum_url "$u" 'SHA256SUMS')" \
    "https://fake.test/rel/24.04.5.1/SHA256SUMS"
u2=$(dl_resolve_iso_url https://fake.test/rel/ '^99\.99' '' '\.iso$')
chk "no such dir -> empty" "$u2" ""
eval "$__orig_dl_fetch"; unset __orig_dl_fetch

echo "== persistence: ISO layout detection =="
pm=$(mktemp -d); mkdir -p "$pm/casper"
chk "casper layout"  "$(persistence_kind "$pm")" "casper"
pm2=$(mktemp -d); mkdir -p "$pm2/live"; touch "$pm2/live/vmlinuz"
chk "live layout"    "$(persistence_kind "$pm2")" "live"
pm3=$(mktemp -d); mkdir -p "$pm3/images/pxeboot"
chk "fedora layout -> unsupported" "$(persistence_kind "$pm3")" "none"
chk "empty dir -> none"            "$(persistence_kind "$(mktemp -d)")" "none"
rm -rf "$pm" "$pm2" "$pm3"

chk "label casper"      "$(persistence_label_for casper)" "casper-rw"
chk "label live"        "$(persistence_label_for live)"   "persistence"
chk "label none"        "$(persistence_label_for none)"   ""
chk "param casper"      "$(persistence_param_for casper)" "persistent"
chk "param none"        "$(persistence_param_for none)"   ""
persistence_is_supported casper && ok "casper supported"  || bad "casper supported"
persistence_is_supported live   && ok "live supported"    || bad "live supported"
persistence_is_supported none   && bad "none unsupported" || ok "none unsupported"

echo "== persistence: add_boot_param() =="
bm=$(mktemp -d); mkdir -p "$bm/boot/grub" "$bm/isolinux"
cat > "$bm/isolinux/txt.cfg" <<'CFG'
DEFAULT live
LABEL live
  MENU LABEL ^Install
  kernel /casper/vmlinuz
  append initrd=/casper/initrd boot=casper quiet splash ---
CFG
cat > "$bm/boot/grub/grub.cfg" <<'CFG'
menuentry "Live" {
    linux /casper/vmlinuz boot=casper quiet splash
    initrd /casper/initrd
}
CFG
add_boot_param "$bm" persistent >/dev/null 2>&1
grep -qE 'append .*persistent ---' "$bm/isolinux/txt.cfg" \
    && ok "syslinux append me param (--- se pehle)" || bad "syslinux append param"
grep -qE '^[[:space:]]*kernel[[:space:]].*persistent' "$bm/isolinux/txt.cfg" \
    && bad "kernel line untouched" || ok "kernel line untouched (append convention)"
grep -qE '^[[:space:]]*linux[[:space:]].*persistent' "$bm/boot/grub/grub.cfg" \
    && ok "GRUB linux line me param" || bad "GRUB linux line me param"
grep -qE '^[[:space:]]*initrd[[:space:]].*persistent' "$bm/boot/grub/grub.cfg" \
    && bad "initrd untouched" || ok "initrd untouched"
add_boot_param "$bm" persistent >/dev/null 2>&1
n=$(grep -c persistent "$bm/isolinux/txt.cfg")
chk "idempotent (1 hi baar)" "$n" "1"
rm -rf "$bm"

echo "== persistence: boot partition size math =="
mb=1048576
v=$(persistence_boot_end_mb $((3*1024*mb)) $((16*1024*mb)))
(( v >= 3000 && v <= 4500 )) && ok "3GiB ISO -> ~$v MB boot" || bad "3GiB ISO -> $v MB"
v=$(persistence_boot_end_mb $((15900*mb)) $((16*1024*mb)))
(( v <= 16320 && v > 16000 )) && ok "bada ISO clamp -> $v MB" || bad "clamp -> $v MB"

echo "== ventoy: partition naming =="
chk "/dev/sdb 1"    "$(ventoy_part_name /dev/sdb 1)"     "/dev/sdb1"
chk "/dev/sdc 2"    "$(ventoy_part_name /dev/sdc 2)"     "/dev/sdc2"
chk "nvme0n1 3"     "$(ventoy_part_name /dev/nvme0n1 3)" "/dev/nvme0n1p3"
chk "mmcblk0 2"     "$(ventoy_part_name /dev/mmcblk0 2)" "/dev/mmcblk0p2"

echo "== ventoy: detect_iso_family (graceful on non-ISO) =="
ni=$(mktemp); head -c 4096 /dev/urandom > "$ni"
fam=$(detect_iso_family "$ni" 2>/dev/null); rc=$?
chk "non-ISO -> unknown" "$fam" "unknown|||"
(( rc != 0 )) && ok "rc != 0 on failure" || bad "rc != 0 on failure"
rm -f "$ni"

echo "== gui: gui_detect() =="
if ( unset DISPLAY WAYLAND_DISPLAY; GUI_TOOL=""; gui_detect ) 2>/dev/null; then
    bad "gui_detect (no display) -> should fail"
else
    ok "gui_detect (no display) -> fail"
fi
( unset DISPLAY WAYLAND_DISPLAY; GUI_TOOL=""; gui_progress_set 50 "x" ) \
    && ok "gui_progress_set safe when GUI off" || bad "gui_progress_set safe when GUI off"

echo "== health: health_find_ovmf() =="
of=$(health_find_ovmf 2>/dev/null); rc=$?
(( rc <= 1 )) && ok "callable (found: ${of:-none})" || bad "rc=$rc"

echo "== CLI: arg validation (no root needed) =="
# NOTE: test.sh ne RUFUS_LINUX_LIB=1 export kiya hai -> child process me main()
# skip ho jaata. Isliye child ko explicitly 0 bhejna padta hai.
rufus="$(dirname "$0")/rufus-linux.sh"
RUFUS_LINUX_LIB=0 "$rufus" -h >/dev/null 2>&1
chk "-h exit code" "$?" "0"
RUFUS_LINUX_LIB=0 "$rufus" --list-downloads >/dev/null 2>&1
chk "--list-downloads exit" "$?" "0"
out=$(RUFUS_LINUX_LIB=0 "$rufus" -m nope 2>&1 </dev/null); rc=$?
(( rc != 0 )) && ok "bad --mode rejected (rc=$rc)" || bad "bad --mode accepted (rc=$rc)"
out=$(RUFUS_LINUX_LIB=0 "$rufus" --storage zfs 2>&1 </dev/null); rc=$?
(( rc != 0 )) && ok "bad --storage rejected (rc=$rc)" || bad "bad --storage accepted (rc=$rc)"
out=$(RUFUS_LINUX_LIB=0 "$rufus" --bogus-flag 2>&1 </dev/null); rc=$?
(( rc != 0 )) && ok "unknown flag rejected (rc=$rc)" || bad "unknown flag accepted (rc=$rc)"

echo "== downloader: end-to-end (local HTTP server) =="
if command -v python3 >/dev/null 2>&1; then
    srv=$(mktemp -d); port=8931
    printf 'rufus-linux e2e payload\n' > "$srv/test-image.iso"
    ( cd "$srv" && sha256sum test-image.iso > SHA256SUMS )
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$srv" >/dev/null 2>&1 &
    httpd=$!
    sleep 1.5

    ensure_tmpdir
    dl_download "http://127.0.0.1:$port/test-image.iso" "$srv/out.iso" >/dev/null 2>&1
    chk "download rc" "$?" "0"
    [[ -f "$srv/out.iso" ]] && ok "file downloaded" || bad "file downloaded"

    cs=$(dl_pick_checksum_url "http://127.0.0.1:$port/test-image.iso" "SHA256SUMS")
    chk "checksum URL discovered" "$cs" "http://127.0.0.1:$port/SHA256SUMS"

    dl_verify "$srv/out.iso" "$cs" >/dev/null 2>&1
    chk "verify PASS on good file" "$?" "0"

    printf 'CORRUPT' >> "$srv/out.iso"
    dl_verify "$srv/out.iso" "$cs" >/dev/null 2>&1
    rc=$?
    (( rc == 1 )) && ok "corrupt -> MISMATCH rc=1" || bad "corrupt -> rc=$rc (want 1)"

    # resume/skip: file already complete ho to dobara download nahi hona chahiye
    dl_download "http://127.0.0.1:$port/test-image.iso" "$srv/out2.iso" >/dev/null 2>&1
    msg=$(dl_download "http://127.0.0.1:$port/test-image.iso" "$srv/out2.iso" 2>/dev/null)
    printf '%s' "$msg" | grep -q "Already complete" \
        && ok "already-complete skip detected" || bad "skip not detected: $msg"

    kill "$httpd" 2>/dev/null
    rm -rf "$srv"
else
    echo "  (python3 nahi -- skip)"
fi

# =====================================================================
#  v2.1: Rufus-jaisa AUTO-FILL  +  phase-wise progress
# =====================================================================
tmpd=$(mktemp -d /tmp/rufus-test.XXXXXX)

echo "== auto-fill: iso_volume_label() (ISO9660 PVD) =="
# PVD ko haath se banate hain: sector 16 = offset 32768
#   +0 type | +1..5 'CD001' | +6 version | +7 unused
#   +8..39 system id (32)   | +40..71 volume id (32)
fake_iso="$tmpd/fake.iso"
{
    head -c 32768 /dev/zero
    printf '\x01'                 # volume descriptor type = PVD
    printf 'CD001'                # +1..5
    printf '\x01'                 # +6 version
    printf '\x00'                 # +7 unused
    printf '%-32s' 'LINUXRUFUSTESTSYSTEMID_____'   # +8..39
    printf '%-32s' 'MY_UBLABEL_2026'                # +40..71 volume id
    head -c 4096 /dev/zero
} > "$fake_iso"
lbl=$(iso_volume_label "$fake_iso" 2>/dev/null)
chk "PVD se label nikla" "$lbl" "MY_UBLABEL_2026"

if iso_volume_label /etc/hostname >/dev/null 2>&1; then
    bad "non-ISO file -> fail hona chahiye"
else
    ok "non-ISO file -> fail (sahi)"
fi

echo "== auto-fill: recommend_fs() (FAT32 4GB limit) =="
chk "chhoti file"              "$(recommend_fs 1048576 0)"    "fat32"
chk "badi file, non-Windows"   "$(recommend_fs 5000000000 0)" "ntfs"
if have wimsplit; then
    chk "badi file, Windows + wimsplit" "$(recommend_fs 5000000000 1)" "fat32"
else
    chk "badi file, Windows, wimsplit NAHI" "$(recommend_fs 5000000000 1)" "ntfs"
fi

echo "== auto-fill: resolve_fs_auto() (bina mount) =="
tiny="$tmpd/tiny.iso"; head -c 4096 /dev/zero > "$tiny"
chk "chhoti ISO -> fat32" "$(resolve_fs_auto "$tiny")" "fat32"

echo "== auto-fill: auto_defaults_from_iso() ke _SET guards =="
ISO="" VOLLBL="" SCHEME_SET=0 FS_SET=0 MODE_SET=0 VOLLBL_SET=0
SCHEME=mbr FS=fat32 MODE=dd
auto_defaults_from_iso >/dev/null 2>&1
chk "mode -> auto (unset tha)"      "$MODE" "auto"
[[ $SCHEME == gpt || $SCHEME == mbr ]] \
    && ok "scheme auto -> $SCHEME" || bad "scheme auto -> '$SCHEME'"
chk "bina ISO ke FS haath ka safe"  "$FS" "fat32"

SCHEME=mbr SCHEME_SET=1 FS=ntfs FS_SET=1 MODE=dd MODE_SET=1
auto_defaults_from_iso >/dev/null 2>&1
chk "user ka SCHEME safe" "$SCHEME" "mbr"
chk "user ka FS safe"     "$FS" "ntfs"
chk "user ka MODE safe"   "$MODE" "dd"

SCHEME_SET=0 FS_SET=0 MODE_SET=0 VOLLBL_SET=0
VOLLBL="" ISO="$fake_iso"
auto_defaults_from_iso >/dev/null 2>&1
chk "ISO ka label auto" "$VOLLBL" "MY_UBLABEL_2026"
chk "FS -> auto set"    "$FS" "auto"

VOLLBL="MYUSB" VOLLBL_SET=1
auto_defaults_from_iso >/dev/null 2>&1
chk "user ka LABEL safe" "$VOLLBL" "MYUSB"

# restore (baaki tests par asar na pade)
ISO="" VOLLBL="" SCHEME=mbr SCHEME_SET=0 FS=fat32 FS_SET=0
MODE=auto MODE_SET=0 VOLLBL_SET=0

echo "== auto-fill: iso_looks_windows_noroot() =="
wiso="$tmpd/Win11_25H2_English_x64.iso";  head -c 4096 /dev/zero > "$wiso"
liso="$tmpd/ubuntu-26.04-desktop.iso";    head -c 4096 /dev/zero > "$liso"
iso_looks_windows_noroot "$wiso" && ok "Windows naam -> pehchana" \
                                 || bad "Windows naam -> pehchana"
iso_looks_windows_noroot "$liso" && bad "Linux naam -> nahi pehchana" \
                                 || ok "Linux naam -> nahi pehchana (sahi)"

echo "== auto-fill: --fs auto CLI validation =="
o=$(bash -c "export RUFUS_LINUX_LIB=1; source '$PWD/rufus-linux.sh'; parse_args -f auto 2>&1; echo DONE")
printf '%s' "$o" | grep -q DONE && ok "--fs auto accepted" || bad "--fs auto rejected: $o"
o=$(bash -c "export RUFUS_LINUX_LIB=1; source '$PWD/rufus-linux.sh'; parse_args -f bogus 2>&1; echo DONE")
printf '%s' "$o" | grep -q DONE && bad "--fs bogus accepted" || ok "--fs bogus rejected"

echo "== progress: gui_phase / progress_report / progress_text =="
GUI_PROGRESS=0
gui_phase 20 50
chk "phase base set" "$GUI_PHASE_BASE" "20"
chk "phase span set" "$GUI_PHASE_SPAN" "50"

# GUI band ho to koi crash/fatal nahi
progress_text 50 "hello" && ok "progress_text (GUI off) rc=0" || bad "progress_text rc!=0"
out=$(progress_report 50 100 "Copying" 2>&1); rc=$?
printf '%s' "$out" | grep -q '50%' && ok "progress_report CLI bar" \
                                  || bad "progress_report CLI bar got='$out'"
rc=0; progress_report 0 0 "X" >/dev/null 2>&1 || rc=$?
chk "progress_report total=0 -> divide-by-zero nahi" "$rc" "0"
GUI_PROGRESS=1
exec 3>/dev/null          # fake khula fd -- gui_progress_set ka asli path chale
progress_text 50 "gui on" && ok "progress_text (GUI on) fatal nahi" \
                          || bad "progress_text (GUI on) rc!=0"
exec 3>&-
GUI_PROGRESS=0
gui_phase 0 100

echo "== progress: rsync_progress_feed() parsing =="
out=$(printf '1,048,576  50%%  10.00MB/s  0:00:01 (xfr#1)\n' | rsync_progress_feed "" 2>&1)
printf '%s' "$out" | grep -q '50%' && ok "rsync ka % parse hua" \
                                   || bad "rsync % parse: '$out'"
errf="$tmpd/copy.err"; : > "$errf"
printf 'rsync: link failed\n1,048,576  10%%  1.00MB/s  0:00:01\n' \
    | rsync_progress_feed "$errf" >/dev/null 2>&1
grep -q 'link failed' "$errf" && ok "error line errf me capture" \
                              || bad "error line capture"
[[ $(wc -l < "$errf") -eq 1 ]] && ok "sirf error line gayi (progress nahi)" \
                               || bad "errf me extra lines: $(cat "$errf")"

rm -rf "$tmpd"

echo
echo "----------------------------------------"
echo "  TOTAL: $pass passed, $fail failed"
echo "----------------------------------------"
(( fail == 0 ))
