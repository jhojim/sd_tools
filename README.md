# 🗂️ sd_tools — SD Card Image Provisioning Tool

A single-file, interactive Bash utility for managing SD card images. Designed for embedded Linux developers working with **Armbian**, **Raspberry Pi OS**, and other ARM board distributions. Features a terminal UI via `whiptail`, smart image compression, and parallel multi-device flashing inside a `tmux` session.

---

## ✨ Features

| Feature | Description |
|---|---|
| **Smart Backup** | Copies a live SD card, zeros free space, shrinks the partition to minimum, and compresses to `.img.gz` |
| **Parallel Restore** | Flashes a `.img` or `.img.gz` to one or more SD cards simultaneously in split `tmux` panes |
| **Auto-Expand on First Boot** | Injects Armbian's native resizer or a one-shot `systemd` service for Raspberry Pi OS |
| **Format (FAT32)** | Wipes and formats a device with a clean MBR + FAT32 partition |
| **Optimize Existing Image** | Shrinks and compresses an existing raw `.img` file without re-reading a physical device |
| **Real-time Progress** | Live progress bars via `pv` and Python for copying, zeroing free space, compressing, and flashing |
| **Dependency Auto-install** | Checks and silently installs missing Debian/Ubuntu packages on first run |
| **Structured Logging** | Timestamped `[HH:MM:SS] [LEVEL] message` log written to `sd_manager.log` |

---

## 📋 Requirements

### OS
- Debian, Ubuntu, or any `apt`-based distribution (tested on Ubuntu 22.04 / 24.04).

### Packages (auto-installed if missing)
| Package | Purpose |
|---|---|
| `coreutils` | `truncate`, `dd`, basic shell tools |
| `parted` | Partition table manipulation |
| `e2fsprogs` | `e2fsck`, `resize2fs`, `tune2fs` |
| `mount` | Loop device mounting |
| `gzip` | Image compression |
| `whiptail` | Terminal UI dialogs |
| `dosfstools` | `mkfs.vfat` for FAT32 formatting |
| `python3` | Real-time progress display during flash |
| `tmux` | Split-pane parallel flashing sessions |
| `pv` | Real-time progress bar for card copying, zeroing, and compression |

---

## 🚀 Quick Start

```bash
# Clone the repository
git clone https://github.com/jhojim/sd_tools.git
cd sd_tools

# Make the script executable
chmod +x sd_tools.sh

# Run with sudo (required for raw device access)
sudo ./sd_tools.sh
```

The interactive main menu will appear:

```
┌────────────────── Image Provisioning Tool ───────────────────┐
│  Main Menu                                                     │
│                                                                │
│     1  Create Optimized Backup (Auto-size)                    │
│     2  Parallel Restore Image to SDs                          │
│     3  Format Target (FAT32)                                  │
│     4  Optimize & Compress Existing Image                     │
│     5  Exit                                                    │
└────────────────────────────────────────────────────────────────┘
```

---

## 📖 Usage Guide

### 1. Create Optimized Backup

**Menu option 1** — Backs up a physical SD card into a compressed, size-optimized image.

**Process:**
1. Select the source SD card from the device list (only removable devices are shown).
2. Enter an optional backup name (default: `sd_backup_YYYYMMDD_HHMM`).
3. The script automatically:
   - Copies the full device with `pv` (showing progress bar, speed, ETA, and final `sync`).
   - Mounts the image via a loop device.
   - Zeros free space with a progress bar to maximize `gzip` compression ratio.
   - Detects the OS and injects auto-expand triggers:
     - **Armbian**: removes `.no_automatic_fs_resize` to activate the native daemon.
     - **Raspberry Pi OS**: installs a one-shot `rpi-expandfs.service` systemd unit.
   - Shrinks the root ext4 partition to its minimum size.
   - Truncates the raw image and compresses to `.img.gz`.

**Output:** `images/<name>.img.gz`

---

### 2. Parallel Restore Image to SDs

**Menu option 2** — Flashes a stored image to one or more SD cards simultaneously.

**Process:**
1. Select an image file from the `images/` directory.
2. Select one or more target devices via checklist (SPACE to toggle, ENTER to confirm).
3. Confirm the destructive operation.
4. Each device gets its own `tmux` pane with a live progress bar.
5. After writing, each worker:
   - Re-reads the partition table with `partprobe`.
   - Expands the last partition to 100% of the device.
   - Runs `e2fsck` + `resize2fs` to fill the filesystem.

**Supported source formats:** `.img`, `.img.gz`

> **Note:** Flash progress uses size from the MBR partition table embedded in the image. For large gzipped images, it falls back to the GZIP trailer size field.

---

### 3. Format Target (FAT32)

**Menu option 3** — Wipes and formats a device with a fresh MBR and single FAT32 partition.

- Unmounts all partitions.
- Clears all filesystem signatures with `wipefs`.
- Creates a new MBR partition table.
- Creates a single primary partition spanning the full device.
- Formats it as FAT32 with `mkfs.vfat -F 32`.

---

### 4. Optimize & Compress Existing Image

**Menu option 4** — Shrinks and compresses a raw `.img` file you already have, without needing a physical device.

- Select an existing `.img` from `images/` (cleaned of absolute paths for UI readability).
- Select your platform (Orange Pi/Armbian (partition 1), Raspberry Pi OS (partition 2), or enter a custom partition number).
- Same shrink/compress pipeline as the backup: zeros free space → `resize2fs -M` → truncate → `gzip` (all with `pv` progress bars).
- The original `.img` is **preserved**; the compressed copy is saved as `<name>.img.gz`.

---

## 📁 Directory Structure

```
sd_tools/
├── sd_tools.sh        # Main script (single-file tool)
├── images/            # Auto-created; stores .img and .img.gz files
├── sd_manager.log     # Auto-created; timestamped operation log
└── LICENSE            # MIT License
```

> The `images/` directory is created automatically next to `sd_tools.sh` on first run. Ownership is set to the invoking user (not `root`), so images are accessible without `sudo`.

---

## 🔐 Permissions & Security

The script **requires `sudo`** because it accesses raw block devices (`/dev/sdX`, `/dev/mmcblkX`), creates loop devices, mounts filesystems, and runs `parted`/`e2fsck`. It will exit with an error if run without root privileges.

The `REAL_USER` variable is set to `$SUDO_USER` (the original user who invoked `sudo`) so that created files and directories are owned by that user, not by `root`.

---

## 📝 Logging

All major operations are logged to `sd_manager.log` in the script's directory:

```
[14:32:01] [INFO] Formatting /dev/sdb...
[14:32:08] [PROCESS] Step 1: Copying full SD card /dev/sda -> sd_backup_20260619_1432.img...
[14:35:47] [PROCESS] Optimizing ext4 partition filesystem to minimum boundary...
```

Log levels used: `INFO`, `PROCESS`.

---

## 🧩 Compatibility

| Distribution | Auto-Expand Support |
|---|---|
| **Armbian** | ✅ Native `armbian-resize-firstboot` daemon activated |
| **Raspberry Pi OS** | ✅ One-shot `rpi-expandfs.service` injected |
| **Other Linux (ext4)** | ✅ Filesystem expanded on host at flash time |
| **FAT32-only images** | ⚠️ No filesystem expansion (format tool only) |

---

## ⌨️ UI Navigation & Keyboard Shortcuts

The script forces an English locale (`LC_ALL=C.UTF-8`) for standard button consistency and supports standard console TUI shortcuts:
* **`Tab`**: Move focus between the menu list and the bottom buttons (`<Ok>` / `<Back>`).
* **Left / Right Arrow Keys**: Move between bottom buttons when they are focused.
* **Up / Down Arrow Keys**: Navigate choices inside lists.
* **`Spacebar`**: Toggle checklist checkboxes (for target devices selection).
* **`Enter`**: Accept the current choice. Pressing `Enter` on a menu item automatically acts as `<Ok>` for that item (no need to Tab down to the button).
* **`Esc`**: Returns to the previous step/menu.

If your terminal or tmux session captures the `Tab` key, you can use the **`BACK`** menu option added at the bottom of lists (separated by `---`) and press `Enter` to go back.

---

## ⚠️ Important Notes

- **All data on target devices will be permanently erased** during Format and Restore operations. Double-check your device selection.
- The parallel flash `tmux` session is attached interactively. Do not close the terminal until all panes report `SUCCESS!`.
- For Raspberry Pi OS images, the root filesystem is on partition **2** (boot on 1). Use partition number `2` when prompted in the "Optimize Existing Image" menu.
- The `gzip` progress estimate for large images may show slightly inaccurate total sizes; actual written bytes are always correct.

---

## 📄 License

[MIT](LICENSE) © 2026 jhojim