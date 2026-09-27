# ------------------------------------------------------------------------------
#  MODULE: GUI wizard  (yad ya zenity -- mouse se chalne wala Rufus jaisa)
#
#  Auto-detect: DISPLAY/WAYLAND_DISPLAY + (yad ya zenity) available ho to
#  menu me "GUI wizard" option aata hai. `--gui` flag se seedha khulta hai.
#
#  Progress bar: FIFO ke through zenity/yad ko percentage bhejta hai, to
#  dd write ka live % GUI window me dikhega.
# ------------------------------------------------------------------------------

gui_detect() {
    [[ -n ${GUI_TOOL:-} ]] && return 0
    [[ -n ${DISPLAY:-} || -n ${WAYLAND_DISPLAY:-} ]] || return 1
    if have yad;       then GUI_TOOL=yad
    elif have zenity;  then GUI_TOOL=zenity
    else GUI_TOOL=""; return 1
    fi
    return 0
}

gui_hint_install() {
    err "GUI ke liye 'yad' ya 'zenity' chahiye + graphical session."
    err "  Debian/Ubuntu: sudo apt install yad        (ya: zenity)"
    err "  Fedora       : sudo dnf install yad        (ya: zenity)"
    err "  Arch         : sudo pacman -S yad          (ya: zenity)"
}

# --------------------------- simple dialogs -----------------------------------
gui_msg() {                      # $1=text
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then yad --info --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    else zenity --info --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    fi
}

gui_warn() {
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then yad --warning --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    else zenity --warning --title="rufus-linux" --text="$1" --width=460 >/dev/null 2>&1
    fi
}

gui_error() {
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then yad --error --title="rufus-linux" --text="$1" --width=520 >/dev/null 2>&1
    else zenity --error --title="rufus-linux" --text="$1" --width=520 >/dev/null 2>&1
    fi
}

gui_confirm() {                  # $1=text -> 0 agar YES
    gui_detect || return 1
    if [[ $GUI_TOOL == yad ]]; then
        yad --question --title="Confirm" --text="$1" --width=520 \
            --ok-label="Haan, continue" --cancel-label="Cancel" >/dev/null 2>&1
    else
        zenity --question --title="Confirm" --text="$1" --width=520 \
            --ok-label="Haan, continue" --cancel-label="Cancel" >/dev/null 2>&1
    fi
}

# --------------------------- pickers ------------------------------------------
gui_pick_iso() {                 # -> stdout path (rc!=0 agar cancel)
    gui_detect || return 1
    local out
    local dflt; dflt=$(gui_start_dir)      # sudo ke baad bhi sahi jagah khule
    if [[ $GUI_TOOL == yad ]]; then
        out=$(yad --file --title="ISO image select karo" --filename="$dflt" \
                  --file-filter='ISO images | *.iso *.ISO *.img *.IMG' \
                  --file-filter='All files | *' 2>/dev/null)
    else
        out=$(zenity --file-selection --title="ISO image select karo" \
                     --filename="$dflt" \
                     --file-filter='ISO images | *.iso *.ISO *.img' \
                     --file-filter='All files | *' 2>/dev/null)
    fi
    [[ -n $out && -f $out ]] || return 1
    printf '%s\n' "$out"
}

gui_pick_device() {              # -> stdout /dev/xxx
    gui_detect || return 1
    local -a names=() sizes=() models=() trans=()
    local line name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        names+=("/dev/$name"); sizes+=("$size"); models+=("$model"); trans+=("${tran:-n/a}")
    done < <(list_removable_disks)

    if (( ${#names[@]} == 0 )); then
        gui_error "Koi USB/removable disk nahi mili.\nPendrive laga kar dobara try karo."
        return 1
    fi

    local -a args=()
    local i
    for i in "${!names[@]}"; do
        args+=(TRUE "${names[$i]}" "${sizes[$i]}" "${models[$i]}" "${trans[$i]}")
    done

    local out
    if [[ $GUI_TOOL == yad ]]; then
        out=$(yad --list --radiolist --title="USB device select karo" \
                  --text="Apni pendrive chuno (ye ERASE hogi):" \
                  --column="" --column="Device" --column="Size" --column="Model" --column="Bus" \
                  --print-column=2 --separator="" --width=640 --height=360 \
                  --button="gtk-cancel:1" --button="gtk-ok:0" \
                  "${args[@]}" 2>/dev/null)
    else
        out=$(zenity --list --radiolist --title="USB device select karo" \
                     --text="Apni pendrive chuno (ye ERASE hogi):" \
                     --column=" " --column="Device" --column="Size" --column="Model" --column="Bus" \
                     --print-column=2 --width=640 --height=360 \
                     "${args[@]}" 2>/dev/null)
    fi
    [[ -n $out ]] || return 1
    out=${out%|*}
    printf '%s\n' "$out"
}

gui_pick_mode() {               # -> stdout auto|dd|part  (rc!=0 cancel)
    gui_detect || return 1
    local out
    if [[ $GUI_TOOL == yad ]]; then
        out=$(yad --list --radiolist --title="Write mode" \
                  --column="" --column="Mode" --column="Kya karta hai" \
                  --print-column=2 --separator="" --width=620 --height=300 \
                  --button="gtk-cancel:1" --button="gtk-ok:0" \
                  TRUE  auto      "Auto (recommended: hybrid? dd : partition)" \
                  FALSE dd        "ISO-Hybrid / dd (Linux ISOs ke liye best)" \
                  FALSE part      "Partition & Copy (+ persistence, Windows)" \
                  2>/dev/null)
    else
        out=$(zenity --list --radiolist --title="Write mode" \
                     --column=" " --column="Mode" --column="Kya karta hai" \
                     --print-column=2 --width=620 --height=300 \
                     TRUE  auto "Auto (recommended)" \
                     FALSE dd   "ISO-Hybrid / dd" \
                     FALSE part "Partition & Copy" \
                     2>/dev/null)
    fi
    [[ -n $out ]] || return 1
    printf '%s\n' "$out"
}

# --------------------------- progress bar -------------------------------------
gui_progress_open() {            # $1=title  $2=text  $3=pulsate(0|1)
    local title=$1 text=$2 pulsate=${3:-0}
    gui_detect || return 1
    ensure_tmpdir
    GUI_FIFO="$TMPDIR_P/gui.fifo"
    rm -f "$GUI_FIFO"
    mkfifo "$GUI_FIFO" || { warn "fifo nahi bani"; return 1; }

    local -a flags=()
    [[ $pulsate == 1 ]] && flags+=(--pulsate)

    if [[ $GUI_TOOL == yad ]]; then
        yad --progress --title="$title" --text="$text" --percentage=0 \
            --auto-close --auto-kill "${flags[@]}" \
            < "$GUI_FIFO" >/dev/null 2>&1 &
    else
        zenity --progress --title="$title" --text="$text" --percentage=0 \
            --auto-close --auto-kill "${flags[@]}" \
            < "$GUI_FIFO" >/dev/null 2>&1 &
    fi
    GUI_PID=$!

    if ! exec 3>"$GUI_FIFO"; then
        warn "GUI progress open fail"
        GUI_PID=""
        return 1
    fi
    GUI_PROGRESS=1
    return 0
}

gui_progress_set() {             # $1=pct(0-100)  $2=text
    (( ${GUI_PROGRESS:-0} )) || return 0
    { printf '%s\n' "$1"; printf '# %s\n' "${2:-}"; } >&3 2>/dev/null || true
}

gui_progress_pulse() {           # $1=text (pulsate dialog ke liye)
    (( ${GUI_PROGRESS:-0} )) || return 0
    printf '# %s\n' "${1:-}" >&3 2>/dev/null || true
}

gui_progress_close() {
    (( ${GUI_PROGRESS:-0} )) || return 0
    { printf '100\n'; } >&3 2>/dev/null || true
    exec 3>&- 2>/dev/null || true
    if [[ -n ${GUI_PID:-} ]]; then
        wait "$GUI_PID" 2>/dev/null
        GUI_PID=""
    fi
    GUI_PROGRESS=0
    return 0
}

# Non-root hone par write step ROOT chahiye -> pkexec se dobara chalate hain.
# pkexec ko ek polkit AUTH AGENT chahiye (gnome/KDE me hota hai). Agar agent na
# ho / user cancel kare to seedha "sudo ... --gui" wala hint dikhate hain.
gui_escalate_write() {
    local -a args=(--gui -i "$ISO" -d "$DEV" -m "$MODE" -y -p "$SCHEME" -f "$FS")
    [[ -n ${VOLLBL:-} ]] && args+=(-L "$VOLLBL")
    (( ${DO_VERIFY:-0} )) && args+=(--verify)
    (( ${PERSIST_MB:-0} )) && args+=(--persist "$PERSIST_MB")

    if have pkexec; then
        gui_msg "Root access chahiye.

Agle step me polkit password dialog aayega --
wahan apna USER password daalo."
        local rc=0
        timeout 180 pkexec env \
            DISPLAY="${DISPLAY:-}" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
            XAUTHORITY="${XAUTHORITY:-}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
            RUFUS_ESCALATED=1 \
            "$SELF" "${args[@]}"
        rc=$?
        (( rc == 0 )) && return 0
        (( rc == 124 )) && gui_warn "Polkit dialog ka jawab nahi aaya (timeout)."
    fi

    gui_error "Write ke liye ROOT chahiye.

Koi polkit auth agent nahi mila (ya aapne cancel kiya).

Terminal me chalao:
  sudo -E ${SELF} --gui"
    return 1
}

# File-chooser kahan se start ho?  `sudo` ke baad HOME=/root ho jata hai, jisse
# picker /root me khulta hai -- aur /root me sab kuch DOTFILE folders hain
# (.config/.cache/...) jo GTK file chooser by default chhupata hai, isliye screen
# khali dikhti hai.  Isliye asli user ka ghar nikaal kar wahan se start karte hain.
gui_start_dir() {
    local d="${HOME:-${PWD:-/}}"
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        local u=${SUDO_USER:-} uh
        if [[ -n $u && $u != root ]]; then
            uh=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
            [[ -n $uh && -d $uh ]] && d=$uh
        fi
    fi
    if   [[ -d $d/Downloads ]]; then d="$d/Downloads"
    elif [[ ! -d $d ]];        then d="${PWD:-/}"
    fi
    printf '%s\n' "$d"
}

# ------------------- Asli GTK window  (Rufus-style + SELECT) ------------------
#  zenity ke --forms me file-browse field hota hi nahi (342.1 me bhi nahi).
#  Isliye Python+GTK3 se asli window banate hain -- usme SELECT button hai.
#  Python script yahin embedded hai, isliye deliverable phir bhi SINGLE file hai.
#
#  rc: 0 = START dabaya (sab settings set), 1 = cancel,
#      2 = GTK available nahi -> fallback (zenity forms / step-by-step chain)
gui_gtk_available() {
    have python3 || return 1
    python3 -c 'import gi; gi.require_version("Gtk","3.0"); from gi.repository import Gtk' \
        >/dev/null 2>&1
}

gui_gtk_window() {
    gui_gtk_available || return 2
    gui_detect || return 2
    ensure_tmpdir

    local py="$TMPDIR_P/rufus-wizard.py"
    cat > "$py" <<'PYEOF'
#!/usr/bin/env python3
# rufus-linux : GTK3 main window (Rufus-style)
#  ISO select ke liye SELECT button, device/scheme/fs/mode dropdowns, START.
#  stdout:  ISO=.. DEV=.. SCHEME=.. FS=.. MODE=.. LABEL=..     (har ek alag line)
#  rc: 0 = START,  1 = cancel/close
import os
import re
import sys

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk


def env(key, default=''):
    val = os.environ.get(key)
    return default if val is None or val == '' else val


def _idx(values, val):
    """combo index -> value list me nahi mila to 0 (pehla = auto)."""
    try:
        return values.index(val)
    except ValueError:
        return 0


VERSION = env('RF_VERSION', '2.0')

SCHEMES = ['MBR (BIOS + UEFI)', 'GPT (UEFI only)']
FILESYSTEMS = ['Auto (recommended)', 'FAT32', 'NTFS', 'ext4']
MODES = ['Auto (recommended)', 'ISO-Hybrid (dd)', 'Partition & Copy']
# combo index -> asli value
FS_VALUES = ['auto', 'fat32', 'ntfs', 'ext4']
MODE_VALUES = ['auto', 'dd', 'part']


def iso_volume_label(path):
    """ISO9660 Primary Volume Descriptor (sector 16) se asli volume label.
    Mount kiye bina chalta hai -- isliye non-root GUI me bhi kaam karega."""
    try:
        with open(path, 'rb') as f:
            f.seek(32769)
            if f.read(5) != b'CD001':
                return ''
            f.seek(32808)
            raw = f.read(32)
        return raw.replace(b'\x00', b' ').decode('ascii', 'ignore').strip()
    except OSError:
        return ''


def is_hybrid(path):
    """ISO ka apna MBR hai (0x55AA @510) -> dd mode se boot hoga."""
    try:
        with open(path, 'rb') as f:
            f.seek(510)
            return f.read(2) == b'\x55\xaa'
    except OSError:
        return False


def looks_windows(path):
    """Windows ISO? -- filename + PVD label se (koi mount/7z nahi chahiye)."""
    hay = (os.path.basename(path) + ' ' + iso_volume_label(path)).lower()
    return bool(re.search(
        r'windows|win1[01]|win11|win_|server|x64fre|en-us_dv|_dv[0-9]|ccsa|cccoma',
        hay))


def recommend_scheme():
    """Rufus ki tarah: jis machine par chal rahe ho wahi target maano.
    UEFI -> GPT, purana BIOS -> MBR."""
    return 'gpt' if os.path.isdir('/sys/firmware/efi') else 'mbr'


def _visible(path):
    """Folder me koi CHHUPA hua (non-dot) entry hai?  Agar sirf .config/.cache
    jaise dotfiles hon to woh folder file-chooser me KHAAALI dikhega -- aise
    folder ko skip kar dete hain (yahi /root ke saath ho raha tha)."""
    try:
        return any(not n.startswith('.') for n in os.listdir(path))
    except OSError:
        return False


def start_dir():
    """Sabse achhi starting folder chuno (order me pehli jo usable ho)."""
    user = os.environ.get('USER') or os.environ.get('LOGNAME') or ''
    cands = []
    v = os.environ.get('RF_START_DIR')
    if v:
        cands.append(v)
    cands.append(os.path.expanduser('~/Downloads'))
    cands.append(os.path.expanduser('~'))
    if user:
        cands.append('/media/' + user)
        cands.append('/run/media/' + user)
    cands.append('/mnt')
    cands.append(os.getcwd())

    fallback = None
    for c in cands:
        if not c or not os.path.isdir(c):
            continue
        if not os.access(c, os.R_OK | os.X_OK):
            continue
        if fallback is None:
            fallback = c
        if _visible(c):
            return c
    return fallback or '/'

DEVICES = []            # [(path, label)]
for _line in env('RF_DEVICES').splitlines():
    _f = _line.split('|')
    if len(_f) >= 4 and _f[0]:
        _path = '/dev/' + _f[0]
        DEVICES.append((_path, '%s   %s   %s   [%s]'
                        % (_path, _f[1], _f[2], _f[3] or '?')))


class Main(Gtk.Window):
    def __init__(self):
        super().__init__(title='Rufus-Linux  ::  Bootable USB Creator  v' + VERSION)
        self.set_border_width(14)
        self.set_default_size(620, -1)
        self.result = 1

        grid = Gtk.Grid(column_spacing=10, row_spacing=9)
        self.add(grid)

        # user ne khud chhuna ya nahi -- sirf tab tak auto-fill chalta rahega
        # (Rufus bhi yahi karta hai: ISO select = sab auto, manual change = respect)
        self._touched_scheme = False
        self._touched_fs = False
        self._touched_label = False
        self._auto_label = ''
        self._setting_auto = False

        head = Gtk.Label()
        head.set_markup('<span size="x-large"><b>\U0001F427 Rufus-Linux</b></span>')
        head.set_halign(Gtk.Align.START)
        grid.attach(head, 0, 0, 3, 1)

        sub = Gtk.Label(
            label='Bootable USB creator for Linux  --  ISO ke liye SELECT dabao.')
        sub.set_halign(Gtk.Align.START)
        sub.set_opacity(0.70)
        grid.attach(sub, 0, 1, 3, 1)

        # --- Device -------------------------------------------------------
        grid.attach(self._label('Device'), 0, 2, 1, 1)
        self.dev_combo = Gtk.ComboBoxText()
        for path, label in DEVICES:
            self.dev_combo.append(path, label)
        self.dev_combo.set_hexpand(True)
        want = env('RF_DEV')
        idx = 0
        for i, (p, _l) in enumerate(DEVICES):
            if p == want:
                idx = i
                break
        if DEVICES:
            self.dev_combo.set_active(idx)
        grid.attach(self.dev_combo, 1, 2, 2, 1)

        # --- ISO image (SELECT button) ------------------------------------
        grid.attach(self._label('ISO image'), 0, 3, 1, 1)
        self.iso_entry = Gtk.Entry()
        self.iso_entry.set_placeholder_text('ISO file ka path likho, ya SELECT dabao...')
        self.iso_entry.set_hexpand(True)
        cur = env('RF_ISO')
        if cur:
            self.iso_entry.set_text(cur)
        self.iso_entry.connect('changed', self._on_iso_changed)
        grid.attach(self.iso_entry, 1, 3, 1, 1)

        sel = Gtk.Button(label='SELECT')
        sel.connect('clicked', self._on_select)
        grid.attach(sel, 2, 3, 1, 1)

        grid.attach(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL),
                    0, 4, 3, 1)

        # --- Partition scheme ---------------------------------------------
        grid.attach(self._label('Partition scheme'), 0, 5, 1, 1)
        self.sch_combo = Gtk.ComboBoxText()
        for v in SCHEMES:
            self.sch_combo.append_text(v)
        self.sch_combo.set_active(1 if env('RF_SCHEME', 'mbr') == 'gpt' else 0)
        # scheme badalne par Rufus ki tarah file system bhi apne aap theek ho
        self.sch_combo.connect('changed', self._on_scheme_changed)
        grid.attach(self.sch_combo, 1, 5, 2, 1)

        # --- File system ---------------------------------------------------
        grid.attach(self._label('File system'), 0, 6, 1, 1)
        self.fs_combo = Gtk.ComboBoxText()
        for v in FILESYSTEMS:
            self.fs_combo.append_text(v)
        self.fs_combo.set_active(_idx(FS_VALUES, env('RF_FS', 'auto')))
        self.fs_combo.connect('changed', self._on_fs_changed)
        grid.attach(self.fs_combo, 1, 6, 2, 1)

        # --- Write mode ----------------------------------------------------
        grid.attach(self._label('Write mode'), 0, 7, 1, 1)
        self.mode_combo = Gtk.ComboBoxText()
        for v in MODES:
            self.mode_combo.append_text(v)
        self.mode_combo.set_active(_idx(MODE_VALUES, env('RF_MODE', 'auto')))
        grid.attach(self.mode_combo, 1, 7, 2, 1)

        # --- Volume label ---------------------------------------------------
        grid.attach(self._label('Volume label'), 0, 8, 1, 1)
        self.vol_entry = Gtk.Entry()
        self.vol_entry.set_placeholder_text('khaali = auto (ISO ka label)')
        self.vol_entry.set_text(env('RF_LABEL'))
        self.vol_entry.set_hexpand(True)
        self.vol_entry.connect('changed', self._on_label_changed)
        grid.attach(self.vol_entry, 1, 8, 2, 1)

        # --- status + buttons -----------------------------------------------
        self.status = Gtk.Label(halign=Gtk.Align.START)
        self.status.set_line_wrap(True)
        self.status.set_xalign(0.0)
        grid.attach(self.status, 0, 9, 3, 1)

        box = Gtk.Box(spacing=8)
        box.set_halign(Gtk.Align.END)
        cancel = Gtk.Button(label='Cancel')
        cancel.connect('clicked', self._on_cancel)
        start = Gtk.Button(label='START')
        start.get_style_context().add_class('suggested-action')
        start.connect('clicked', self._on_start)
        box.pack_start(cancel, False, False, 0)
        box.pack_start(start, False, False, 0)
        grid.attach(box, 0, 10, 3, 1)

        if not DEVICES:
            self.set_status('Koi USB nahi mili -- pendrive lagao aur dobara kholo.')

    # ---------------- helpers -------------------------------------------
    def _label(self, text):
        lbl = Gtk.Label(label=text, halign=Gtk.Align.START)
        lbl.set_xalign(0.0)
        lbl.set_size_request(140, -1)
        return lbl

    def set_status(self, text):
        self.status.set_text(text)

    # ---------------- AUTO-FILL (Rufus jaisa) ------------------------------
    def predict_fs(self, path, scheme):
        """Write-time pe asli decision bash karega (mount karke) -- yahan sirf
        prediction dikhane ke liye, taaki user ko pata chale kya hone wala hai."""
        if looks_windows(path):
            return 'NTFS' if scheme == 'mbr' else 'FAT32 (install.wim split)'
        return 'FAT32'

    def _autofill(self, path):
        """ISO select hote hi SAB auto -- jaise Rufus me hota hai."""
        label = iso_volume_label(path)
        hybrid = is_hybrid(path)
        win = looks_windows(path)

        # programmatically badal rahe hain -> 'changed' ko user-action mat mano
        self._setting_auto = True
        try:
            # 1) volume label -- ISO ka asli label
            if label and not self._touched_label:
                self.vol_entry.set_text(label)
                self._auto_label = label

            # 2) partition scheme -- machine se (UEFI -> GPT, BIOS -> MBR)
            if not self._touched_scheme:
                self.sch_combo.set_active(1 if recommend_scheme() == 'gpt' else 0)

            # 3) file system -- user ne chhua nahi to wapas AUTO par
            if not self._touched_fs:
                self.fs_combo.set_active(_idx(FS_VALUES, 'auto'))
        finally:
            self._setting_auto = False

        scheme = 'gpt' if self.sch_combo.get_active() == 1 else 'mbr'
        try:
            size = '%.0f MB' % (os.path.getsize(path) / 1048576.0)
        except OSError:
            size = '?'
        info = []
        info.append('hybrid=YES -> dd' if hybrid else 'hybrid=NO -> partition')
        if win:
            info.append('Windows ISO')
        info.append('FS: auto -> %s' % self.predict_fs(path, scheme))
        self.set_status('%s   (%s)   %s'
                        % (os.path.basename(path), size, ' | '.join(info)))

    def _on_scheme_changed(self, _combo):
        if getattr(self, '_setting_auto', False):
            return
        self._touched_scheme = True
        # Rufus: scheme badalo -> target system/file system bhi badal jaate hain
        p = self.iso_entry.get_text().strip()
        if p and os.path.isfile(p) and not self._touched_fs:
            scheme = 'gpt' if self.sch_combo.get_active() == 1 else 'mbr'
            self.set_status('%s   |  Scheme %s  ->  FS (auto) = %s'
                            % (os.path.basename(p), scheme.upper(),
                               self.predict_fs(p, scheme)))

    def _on_fs_changed(self, _combo):
        if getattr(self, '_setting_auto', False):
            return
        self._touched_fs = True

    def _on_label_changed(self, _entry):
        if getattr(self, '_setting_auto', False):
            return
        self._touched_label = True

    def _on_iso_changed(self, _entry):
        p = self.iso_entry.get_text().strip()
        if p and os.path.isfile(p):
            self._autofill(p)

    def err(self, msg):
        d = Gtk.MessageDialog(transient_for=self, modal=True,
                              message_type=Gtk.MessageType.ERROR,
                              buttons=Gtk.ButtonsType.OK, text=msg)
        d.run()
        d.destroy()

    def pick_iso(self):
        d = Gtk.FileChooserDialog(title='ISO image select karo', parent=self,
                                  action=Gtk.FileChooserAction.OPEN)
        d.add_button('_Cancel', Gtk.ResponseType.CANCEL)
        d.add_button('_Open', Gtk.ResponseType.OK)
        f = Gtk.FileFilter()
        f.set_name('ISO images (*.iso / *.img)')
        for pat in ('*.iso', '*.ISO', '*.img', '*.IMG'):
            f.add_pattern(pat)
        d.add_filter(f)
        f2 = Gtk.FileFilter()
        f2.set_name('All files')
        f2.add_pattern('*')
        d.add_filter(f2)
        # folder dikhne layak ho (sirf-dotfiles wala folder KHAALI dikhta hai)
        d.set_current_folder(start_dir())
        path = None
        if d.run() == Gtk.ResponseType.OK:
            path = d.get_filename()
        d.destroy()
        return path

    # ---------------- actions --------------------------------------------
    def _on_select(self, _b):
        path = self.pick_iso()
        if not path:
            return
        # 'changed' signal -> _autofill() sab kuch auto set kar dega
        self.iso_entry.set_text(path)

    def _on_cancel(self, _b):
        self.result = 1
        Gtk.main_quit()

    def on_delete(self, *_args):
        self.result = 1
        Gtk.main_quit()
        return False

    def _on_start(self, _b):
        iso = self.iso_entry.get_text().strip()
        if not iso:
            iso = self.pick_iso()
            if not iso:
                self.set_status('ISO select cancel kiya gaya.')
                return
            self.iso_entry.set_text(iso)
        iso = os.path.abspath(os.path.expanduser(iso))
        if not os.path.isfile(iso):
            self.err('ISO file nahi mili:\n\n' + iso)
            self.set_status('ISO file nahi mili.')
            return
        dev = self.dev_combo.get_active_id()
        if not dev:
            self.err('Koi USB device select nahi hui.\n\n'
                     'Pendrive lagao aur dobara kholo.')
            self.set_status('USB device chahiye.')
            return
        scheme = 'gpt' if self.sch_combo.get_active() == 1 else 'mbr'
        fs = FS_VALUES[self.fs_combo.get_active()]
        mode = MODE_VALUES[self.mode_combo.get_active()]
        label = self.vol_entry.get_text().strip()
        sys.stdout.write('ISO=%s\nDEV=%s\nSCHEME=%s\nFS=%s\nMODE=%s\nLABEL=%s\n'
                         % (iso, dev, scheme, fs, mode, label))
        sys.stdout.flush()
        self.result = 0
        Gtk.main_quit()


win = Main()
win.connect('delete-event', win.on_delete)
win.show_all()
Gtk.main()
sys.exit(win.result)
PYEOF
    [[ -s $py ]] || return 2

    # device list bash se -> env (taaki lsblk logic dobara na likhna pade)
    local devlines="" name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        devlines+="$name|$size|$model|$tran"$'\n'
    done < <(list_removable_disks)

    local out rc=0
    out=$(RF_VERSION="$VERSION" \
            RF_START_DIR="$(gui_start_dir)" \
            RF_DEVICES="$devlines" \
            RF_ISO="${ISO:-}" RF_DEV="${DEV:-}" \
            RF_SCHEME="${SCHEME:-mbr}" RF_FS="${FS:-auto}" \
            RF_MODE="${MODE:-auto}" RF_LABEL="${VOLLBL:-}" \
            python3 "$py" 2>"$TMPDIR_P/wizard.err") || rc=$?

    if (( rc != 0 )); then
        (( rc == 1 )) && return 1          # user ne cancel/close kiya
        warn "GTK wizard nahi chala -- fallback use hoga."
        sed 's/^/      /' "$TMPDIR_P/wizard.err" 2>/dev/null | tail -5 >&2
        return 2
    fi

    local k v
    while IFS='=' read -r k v; do
        case $k in
            ISO)    ISO=$v ;;
            DEV)    DEV=$v ;;
            SCHEME) SCHEME=$v ;;
            FS)     FS=$v ;;
            MODE)   MODE=$v ;;
            LABEL)  VOLLBL=$v ;;
        esac
    done <<< "$out"

    [[ -n ${ISO:-} && -n ${DEV:-} ]] || return 2
    return 0
}

# ------------------- Rufus jaisa EK hi main window ----------------------------
#  rc:  0 = START dabaya (ISO/DEV/SCHEME/FS/MODE/VOLLBL set)
#       1 = cancel / koi device nahi
#       2 = is tool ke liye forms supported nahi (fallback: per-step chain)
gui_main_window() {
    gui_detect || return 2

    # ---- device list ----
    local -a dev_labels=()
    local name size model tran
    while IFS='|' read -r name size model tran; do
        [[ -z $name ]] && continue
        dev_labels+=("/dev/$name   $size   ${model:-n/a}   [${tran:-?}]")
    done < <(list_removable_disks)

    if (( ${#dev_labels[@]} == 0 )); then
        # Window tab bhi dikhao -- placeholder rakhenge.  START dabane par
        # neeche "pendrive lagao" wala error aayega.
        dev_labels=("(koi USB nahi -- pendrive lagao)")
    fi

    local dev_values
    dev_values=$(IFS='|'; printf '%s' "${dev_labels[*]}")

    # ---- combo values: current selection ko pehle rakho = default ----
    local sch_vals="MBR (BIOS + UEFI)|GPT (UEFI only)"
    [[ ${SCHEME:-mbr} == gpt ]] && sch_vals="GPT (UEFI only)|MBR (BIOS + UEFI)"

    local fs_vals="Auto (recommended)|FAT32|NTFS|ext4"
    case ${FS:-auto} in
        fat32) fs_vals="FAT32|Auto (recommended)|NTFS|ext4" ;;
        ntfs)  fs_vals="NTFS|Auto (recommended)|FAT32|ext4" ;;
        ext4)  fs_vals="ext4|Auto (recommended)|FAT32|NTFS" ;;
    esac

    local mode_vals="Auto (recommended)|ISO-Hybrid (dd)|Partition & Copy"
    case ${MODE:-auto} in
        dd)   mode_vals="ISO-Hybrid (dd)|Auto (recommended)|Partition & Copy" ;;
        part) mode_vals="Partition & Copy|Auto (recommended)|ISO-Hybrid (dd)" ;;
    esac

    local title="Rufus-Linux  ::  Bootable USB Creator  v${VERSION}"
    local head="ISO chuno, device chuno, options set karo -- phir START dabao."
    local out rc=0

    if [[ $GUI_TOOL == yad ]]; then
        local dsv=$dev_values sv=${sch_vals//|/!} fv=${fs_vals//|/!} mv=${mode_vals//|/!}
        out=$(yad --form --title="$title" --text="$head" --width=600 \
                  --field="ISO image:DIR"            "${ISO:-}" \
                  --field="USB device:CB"            "$dsv" \
                  --field="Partition scheme:CB"      "$sv" \
                  --field="File system:CB"           "$fv" \
                  --field="Write mode:CB"            "$mv" \
                  --field="New volume label"         "${VOLLBL:-}" \
                  --separator=$'\x1f' \
                  --button="gtk-cancel:1" --button="gtk-ok:0" 2>/dev/null) || rc=$?
    elif [[ $GUI_TOOL == zenity ]]; then
        zenity --forms --help >/dev/null 2>&1 || return 2
        out=$(zenity --forms \
                  --title="$title" --text="$head" --width=600 \
                  --add-entry="ISO image path  (khaali = file picker khulega)" \
                  --add-combo="USB device"       --combo-values="$dev_values" \
                  --add-combo="Partition scheme" --combo-values="$sch_vals" \
                  --add-combo="File system"      --combo-values="$fs_vals" \
                  --add-combo="Write mode"       --combo-values="$mode_vals" \
                  --add-entry="New volume label  (khaali = auto)" \
                  --separator=$'\x1f' \
                  --ok-label="START" --cancel-label="Cancel" 2>/dev/null) || rc=$?
    else
        return 2
    fi
    (( rc == 0 )) || return 1

    local f_iso f_dev f_sch f_fs f_mode f_lbl
    IFS=$'\x1f' read -r f_iso f_dev f_sch f_fs f_mode f_lbl <<< "$out"

    # trim (sed taaki path ka content safe rahe)
    f_iso=$(printf '%s' "$f_iso" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    f_lbl=$(printf '%s' "$f_lbl" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

    if [[ -n $f_iso ]]; then
        [[ $f_iso == /* ]] || f_iso="$PWD/$f_iso"
        if [[ -f $f_iso ]]; then ISO=$f_iso
        else
            gui_error "ISO file nahi mili:

$f_iso"
            return 1
        fi
    fi

    if [[ $f_dev == /dev/* ]]; then
        DEV=${f_dev%% *}
    else
        gui_error "Koi USB device select nahi hui.

Pendrive lagao aur dobara kholo."
        return 1
    fi

    case $f_sch in
        GPT*) SCHEME=gpt ;;
        *)    SCHEME=mbr ;;
    esac
    case $f_fs in
        Auto*|auto*) FS=auto ;;
        NTFS*)       FS=ntfs ;;
        ext4*)       FS=ext4 ;;
        *)           FS=fat32 ;;
    esac
    case $f_mode in
        *dd*)        MODE=dd ;;
        *Partition*) MODE=part ;;
        *)           MODE=auto ;;
    esac
    VOLLBL=$f_lbl
    return 0
}

# --------------------------- full wizard --------------------------------------
gui_wizard() {
    gui_detect || { gui_hint_install; return 1; }

    local interactive=0 p rc

    # Rufus jaisa auto-fill: user/CLI ne jo khud set nahi kiya wo yahan se.
    # -- UEFI machine -> GPT, mode -> auto, (ISO milte hi label + FS auto).
    # Window kholne se PEHLE, taaki dropdowns me sahi default dikhe.
    auto_defaults_from_iso

    # ---- 1) pehle KOSHISH karo: asli GTK window (SELECT button ke saath) ----
    #     (sirf tab jab ISO/DEV CLI se na diya ho -- pkexec re-exec me skip)
    if [[ -z ${ISO:-} || -z ${DEV:-} ]]; then
        gui_gtk_window
        rc=$?
        if (( rc == 2 )); then            # GTK nahi -> zenity forms window
            gui_main_window
            rc=$?
        fi
        case $rc in
            0)
                info "Main window se sab set ho gaya."
                # window/user ki values ab authoritative hain -- auto-fill
                # inhe dobara overwrite na kare
                SCHEME_SET=1; FS_SET=1; MODE_SET=1
                [[ -n ${VOLLBL:-} ]] && VOLLBL_SET=1
                ;;
            1) info "User ne cancel kiya (main window)."; return 0 ;;
            *) interactive=1 ;;   # dono unsupported -> step-by-step chain
        esac
    fi

    # ---- 2) fallback: jo reh gaya uske liye per-step pickers ----
    if [[ -z ${ISO:-} ]]; then
        interactive=1
        if ! p=$(gui_pick_iso); then info "Cancel (ISO select)."; return 0; fi
        ISO=$p
    fi
    # ISO mil gayi -> ab label (PVD se) aur FS=auto set ho jayega
    auto_defaults_from_iso
    if is_hybrid_iso; then
        info "ISO: $(basename "$ISO")  [hybrid: YES]"
    else
        info "ISO: $(basename "$ISO")  [hybrid: NO -> partition mode better]"
    fi

    if [[ -z ${DEV:-} ]]; then
        interactive=1
        if ! p=$(gui_pick_device); then info "Cancel (device select)."; return 0; fi
        DEV=$p
    fi

    if (( interactive )); then
        if p=$(gui_pick_mode); then MODE=$p; fi
    fi

    # FS = auto hai to yahin resolve karke confirm dialog me ASLI value dikhao
    # (taaki user ko pata chale kya banne wala hai).  Write bhi yahi lega --
    # root child dobara mount karke exact calculate karega.
    local fs_show=$FS
    if [[ $FS == auto ]]; then
        fs_show=$(resolve_fs_auto "$ISO")
        info "Auto file system -> $fs_show"
    fi

    local mode_show=$MODE
    [[ $MODE == auto ]] && { is_hybrid_iso && mode_show="dd (hybrid)" || mode_show="part"; }

    info "Device: $DEV   Mode: $mode_show   Scheme: $SCHEME   FS: $fs_show"

    # ---- 3) ERASE confirmation (hamesha, jab tak -y na ho) ----
    if (( ASSUME_YES == 0 )); then
        if ! gui_confirm "ISO    : $(basename "$ISO")
Device : $DEV   ($(lsblk -dn -o SIZE "$DEV" 2>/dev/null | xargs)  $(lsblk -dn -o MODEL "$DEV" 2>/dev/null | xargs))
Scheme : $SCHEME    FS: $fs_show    Mode: $mode_show
Label  : $(sanitize_label "${VOLLBL:-}")   (auto)
Size   : $(human "$(stat -c '%s' "$ISO" 2>/dev/null || echo 0)")  ->  $(lsblk -dn -o SIZE "$DEV" 2>/dev/null | xargs)

${DEV##*/} ka SAARA DATA ERASE ho jayega.

Aage badhein?"; then
            info "User ne cancel kiya."
            return 0
        fi
    fi
    ASSUME_YES=1

    # ---- 4) yahan tak sab read-only tha; ab likhna hai -> root chahiye ----
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        gui_escalate_write || return 1
        return 0          # escalated child khud progress + DONE dialog dikhayega
    fi

    ensure_tmpdir
    gui_progress_open "rufus-linux" "Writing $(basename "$ISO") ..." 0 || true

    local rc=0
    do_start || rc=$?

    gui_progress_close

    if (( rc == 0 )); then
        gui_msg "DONE

Bootable USB tayyar hai!
Device : $DEV
Mode   : $MODE

Ab USB laga kar reboot karo."
    else
        gui_error "Write fail ho gaya (code $rc).
Terminal/log me details dekho."
    fi
    return $rc
}
