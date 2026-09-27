<div align="center">
  <img src="https://raw.githubusercontent.com/friendix12/rufus-linux/main/assets/rufus-linux-banner.png" alt="Rufus-Linux Banner" width="100%" />

  # Rufus-Linux 🐧
  ### Native, High-Performance Bootable USB Creator for Linux

  [![Bash](https://img.shields.io/badge/Language-Bash%20%7C%20Python3%20GTK-blue.svg)](https://www.gnu.org/software/bash/)
  [![Platform](https://img.shields.io/badge/Platform-Linux-orange.svg)](https://kernel.org)
  [![Tests](https://img.shields.io/badge/Unit%20Tests-107%20Passed-brightgreen.svg)](test.sh)
  [![License](https://img.shields.io/badge/License-GPL%20v3-green.svg)](LICENSE)
</div>

> **A native, feature-complete bootable USB creator for Linux — inspired by Rufus on Windows.**
>
> Rufus is a Windows-only tool that frequently fails under Wine due to raw block-level disk access restrictions. **Rufus-Linux** solves this by providing a native, lightweight, standalone tool combining a modern **GTK3 GUI wizard** and an **interactive CLI menu**, packed with extra features like Multi-ISO (Ventoy style), Persistence partitions, ISO downloader with SHA256 checksum verification, and Drive Health testing.

---

## 📑 Table of Contents

- [Features](#-features)
- [Quick Start](#-quick-start)
- [Installation & Dependencies](#-installation--dependencies)
- [How to Run](#-how-to-run)
  - [1. GUI Wizard (Graphical)](#1-gui-wizard-graphical)
  - [2. Interactive Terminal Menu](#2-interactive-terminal-menu)
  - [3. Scripted CLI One-Liners](#3-scripted-cli-one-liners)
- [Write Modes Explained](#-write-modes-explained)
- [Windows 10 / 11 Bootable USB](#-windows-10--11-bootable-usb)
- [Multi-ISO USB (Ventoy-Style)](#-multi-iso-usb-ventoy-style)
- [Live USB with Persistence](#-live-usb-with-persistence)
- [ISO Downloader & Checksum Verifier](#-iso-downloader--checksum-verifier)
- [Drive Health, Speed & Boot Test](#-drive-health-speed--boot-test)
- [Safety & Data Protection](#-safety--data-protection)
- [Building from Source](#-building-from-source)
- [Troubleshooting & FAQ](#-troubleshooting--faq)

---

## ✨ Features

| | Feature | Description |
|---|---|---|
| 🖥️ | **Rufus-Style GUI Wizard** | Modern GTK3 window with file pickers, device dropdowns, and live progress bar. Fallback to Zenity/Yad if GTK is unavailable. |
| 📟 | **Interactive CLI Menu** | Beautiful colored interactive terminal interface for SSH or headless environments. |
| ⚡ | **Three Write Modes** | `dd` (ISO-Hybrid direct block write), `part` (Partition & Copy for UEFI/Windows), and `auto` detection. |
| 🪟 | **Windows 11 & 10 Support** | Full UEFI GPT/MBR partition formatting, handling >4GB `install.wim` files automatically. |
| 💾 | **Persistence Partition** | Keep your files and settings saved across reboots for Ubuntu, Mint, Kali, and Debian Live USBs. |
| 📀 | **Multi-ISO USB (Ventoy-Style)** | Put multiple Linux ISOs on a single USB drive with an automated GRUB bootloader menu. |
| 🌐 | **ISO Downloader + Checksum** | Download 10+ major Linux distros directly with automatic SHA256 verification and URL rot discovery. |
| 🩺 | **Drive Health & Boot Testing** | SMART diagnostics, read/write speed benchmarking, bad block scanning, and direct QEMU boot emulation. |
| 🛡️ | **Fail-Safe Protection** | Multi-layer safeguards refuse writes to root system disks, mounted partitions, loopback devices, and zram. |
| 📦 | **Zero-Dependency Core** | Single self-contained bash script deliverable (`rufus-linux.sh`). |

---

## ⚡ Quick Start

### Run the GUI (Recommended):
```bash
sudo -E ./rufus-linux.sh --gui
```
*(Or run `./rufus-linux.sh --gui` as a regular user — it will prompt for privilege escalation only when writing!)*

### Run the Interactive Terminal Menu:
```bash
sudo ./rufus-linux.sh
```

### Fast One-Liner (Scripted):
```bash
sudo ./rufus-linux.sh -i ubuntu-24.04-desktop-amd64.iso -d /dev/sdb -y
```

---

## 📦 Installation & Dependencies

### Core Base Packages

```bash
# Debian / Ubuntu / Linux Mint / Kali
sudo apt update && sudo apt install -y util-linux dosfstools parted rsync syslinux-extlinux p7zip-full

# Fedora / RHEL
sudo dnf install -y util-linux dosfstools parted rsync syslinux-utils p7zip

# Arch Linux / Manjaro
sudo pacman -S --needed util-linux dosfstools parted rsync syslinux p7zip
```

### Optional Packages (By Feature)

| Feature | Debian / Ubuntu / Mint | Fedora / RHEL | Arch Linux |
|---|---|---|---|
| **GTK GUI Wizard** | `python3-gi` `gir1.2-gtk-3.0` | `python3-gobject` `gtk3` | `python-gobject` `gtk3` |
| **Fallback Dialogs** | `zenity` or `yad` | `zenity` or `yad` | `zenity` or `yad` |
| **Multi-ISO Bootloader** | `grub-pc-bin` `grub-efi-amd64-bin` | `grub2-pc` `grub2-efi-x64` | `grub` |
| **Windows >4GB WIM Split**| `wimtools` | `wimlib-utils` | `wimlib` |
| **SMART Drive Diagnostics**| `smartmontools` | `smartmontools` | `smartmontools` |
| **QEMU Boot Emulator** | `qemu-system-x86` `ovmf` | `qemu-system-x86` `edk2-ovmf` | `qemu-system-x86` `edk2-ovmf` |

---

## 🚀 How to Run

### 1. GUI Wizard (Graphical)
Launch the graphical Rufus-style window:
```bash
sudo -E ./rufus-linux.sh --gui
```
- Select your target USB device from the dropdown.
- Click **SELECT** to pick any `.iso` or `.img` file.
- The Partition Scheme (MBR/GPT) and File System (FAT32/NTFS) auto-configure based on your ISO.
- Click **START** to write with live progress reporting!

### 2. Interactive Terminal Menu
For command-line lovers and remote SSH servers:
```bash
sudo ./rufus-linux.sh
```
```text
  [1]  ISO image select        : ubuntu-24.04-desktop-amd64.iso
  [2]  USB device select       : /dev/sdb  (32 GB  SanDisk Ultra)
  [3]  Partition scheme        : MBR  (BIOS + UEFI)
  [4]  File system             : FAT32  (BIOS + UEFI, recommended)
  [5]  Write mode              : Auto (hybrid? -> dd : partition+copy)
  [6]  Verify after write      : OFF
  [7]  Persistence (live save) : OFF
  [8]  START  <-- Begin write

  ------- Tools -------
  [D]  ISO download + SHA256 verify
  [V]  Verify existing ISO checksum
  [M]  Multi-ISO USB  (Ventoy-style GRUB menu)
  [H]  Drive health + speed + boot test
  [G]  GUI wizard (graphical, GTK/zenity)
  [Q]  Quit
```

### 3. Scripted CLI One-Liners
```bash
# Auto mode with verification
sudo ./rufus-linux.sh -i ubuntu.iso -d /dev/sdb --verify -y

# Custom volume label and partition scheme
sudo ./rufus-linux.sh -i debian.iso -d /dev/sdb -p gpt -f fat32 -L "MY_DEBIAN" -y

# Partition mode with 4GB Persistence partition
sudo ./rufus-linux.sh -i kali-linux.iso -d /dev/sdb -m part --persist 4096 -y
```

#### Command Line Options
```text
  -i, --iso <file>         Path to ISO image
  -d, --device <dev>       Target block device (e.g. /dev/sdb)
  -m, --mode <m>           Write mode: auto | dd | part (default: auto)
  -p, --part <scheme>      Partition scheme: mbr | gpt
  -f, --fs <fs>            File system: auto | fat32 | ntfs | ext4
  -L, --label <name>       USB volume label (up to 11 characters for FAT32)
      --persist <MB>       Persistence partition size in MB (part mode)
      --verify             Verify written data against ISO checksum
      --no-eject           Do not eject/unmount USB after completion
  -y, --yes                Skip safety confirmation prompts
  -h, --help               Display help reference
```

---

## 💽 Write Modes Explained

### 🔵 `dd` / ISO-Hybrid Mode *(Default for Linux)*
Direct raw block write to the device using `dd`. It copies the ISO's built-in MBR, GPT, and hybrid bootloader.
- **Best for:** 99% of modern Linux distributions (Ubuntu, Fedora, Arch, Debian, Kali, Mint).
- **Boot:** Supports both BIOS and UEFI out of the box.
- **Progress:** Real-time progress bar calculated from `/proc/[pid]/io`.
- **Verify:** Optional bit-by-bit comparison using `cmp`.

### 🟢 `part` / Partition & Copy Mode
Creates a clean partition table (MBR or GPT), formats the partition (FAT32, NTFS, or ext4), extracts the ISO files, and installs UEFI/BIOS bootloaders.
- **Best for:** Windows 10/11 ISOs, non-hybrid ISOs, custom volume labels, and Persistence partitions.
- **Windows Support:** Automatically detects `install.wim` > 4GB and splits it into `.swm` files when using FAT32 (via `wimlib`).

### 🟡 `auto` Mode
Automatically inspects the ISO header (at byte offset 510 for signature `0x55AA`). If the image is ISO-hybrid, it selects `dd`; otherwise, it uses `part`.

---

## 🪟 Windows 10 & 11 Bootable USB

Rufus-Linux provides seamless support for official Windows 10 and Windows 11 installation media:

```bash
# Standard UEFI GPT Windows USB:
sudo ./rufus-linux.sh -i Win11_x64.iso -d /dev/sdb -m part -p gpt -f ntfs -y
```

> **Note on >4GB `install.wim`:**
> Windows ISOs contain an `install.wim` file that often exceeds the FAT32 4GB limit.
> - **NTFS Option (Default):** Writes to NTFS partition. Compatible with all modern UEFI systems.
> - **FAT32 + WIM Split:** Install `wimtools` (`sudo apt install wimtools`). Rufus-Linux will automatically split `install.wim` into `<4GB` chunks for maximum legacy compatibility.

---

## 🧰 Multi-ISO USB (Ventoy-Style)

Store multiple Linux distributions on a single USB stick and choose which one to boot at startup!

```bash
# 1. Format and install GRUB bootloader on USB:
sudo ./rufus-linux.sh --ventoy-prepare -d /dev/sdb -p mbr -y

# 2. Add your favorite ISOs:
sudo ./rufus-linux.sh --ventoy-add ~/Downloads/ubuntu-24.04.iso
sudo ./rufus-linux.sh --ventoy-add ~/Downloads/archlinux.iso
sudo ./rufus-linux.sh --ventoy-add ~/Downloads/fedora.iso

# 3. Rescan and generate the GRUB boot menu:
sudo ./rufus-linux.sh --ventoy-rescan

# View all installed ISOs:
sudo ./rufus-linux.sh --ventoy-list
```

---

## 💾 Live USB with Persistence

Changes made during a Live session (installed software, files, settings) are usually lost on reboot. With **Persistence**, changes are saved to an isolated secondary partition.

```bash
sudo ./rufus-linux.sh -i ubuntu-24.04.iso -d /dev/sdb -m part --persist 4096 -y
```

| Distribution | Persistence Label | Configured Boot Parameter |
|---|---|---|
| **Ubuntu / Mint / Kali / Pop!_OS** | `casper-rw` | `persistent` |
| **Debian Live** | `persistence` | `persistence` + `persistence.conf` |

---

## 🌐 ISO Downloader & Checksum Verifier

Download official Linux distributions without opening a web browser:

```bash
# View list of available distributions
./rufus-linux.sh --list-downloads

# Download latest Ubuntu LTS and verify SHA256
./rufus-linux.sh --download ubuntu24

# Verify any existing ISO against official checksums
./rufus-linux.sh --verify-iso ~/Downloads/archlinux-x86_64.iso
```

Supported distributions: `ubuntu24`, `ubuntu22`, `debian`, `fedora`, `mint`, `arch`, `kali`, `tumbleweed`, and custom URLs.

---

## 🩺 Drive Health, Speed & Boot Test

Test and verify your USB drive before writing critical data:

```bash
sudo ./rufus-linux.sh --health -d /dev/sdb
```
- **Drive Info:** Serial number, model, transport protocol (USB/NVMe/SATA).
- **SMART Health:** Temperature, reallocated sector count, overall PASS/FAIL.
- **Speed Benchmark:** Measures real sustained read and write speed in MB/s.
- **Bad Blocks:** Runs non-destructive sector diagnostics.
- **QEMU Boot Emulator:** Tests booting the USB directly inside a virtual machine window without rebooting your computer!

---

## 🛡️ Safety & Data Protection

To prevent accidental data loss or overwriting system disks, Rufus-Linux enforces strict security rules:

1. **System Disk Protection:** Automatically detects and strictly **REFUSES** writing to the host OS root disk (`/`, `/boot`, `/home`, etc.).
2. **Block-Device Enforcement:** Rejects partitions (e.g. `/dev/sda1`) to prevent broken partition tables; accepts whole drives only (e.g. `/dev/sda`).
3. **Loop & Virtual Device Guard:** Blocks loopback, ramdisk, and zram devices unless explicitly running in test mode (`RUFUS_ALLOW_LOOP=1`).
4. **Explicit Confirmation:** Displays drive capacity, model name, and partitions, requiring an intentional confirmation before erasing.

---

## 🏗️ Building from Source

Rufus-Linux is architected in clean, modular shell scripts inside `src/`. The build script bundles them into the standalone `rufus-linux.sh` deliverable:

```bash
# Build the single-file executable:
./build.sh

# Run unit tests (107 automated checks):
./test.sh
```

---

## ❓ Troubleshooting & FAQ

#### Q: Why is my pendrive not showing up in the file manager after the write finishes?
**A:** When writing completes, Rufus-Linux safely unmounts and **ejects** the USB device (`eject /dev/sdX`) to prevent filesystem corruption and allow safe physical removal. Simply **unplug the USB drive and plug it back into the computer**, and it will appear immediately in your file manager!

#### Q: How do I test the USB in QEMU?
```bash
sudo ./rufus-linux.sh --health -d /dev/sdb
# Select option [7] (QEMU boot test)
```

#### Q: Can I run this in non-root mode?
Yes! You can run `./rufus-linux.sh --gui` as a regular user to browse ISOs and configure options. The tool will escalate privileges via `pkexec` or `sudo` only when writing to the physical block device.

---

## 📄 License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. Feel free to use, modify, and distribute.
