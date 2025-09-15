# Windows 11 USB Installer Creator (macOS)

Create a bootable Windows 11 USB installer from macOS safely and reliably. The included script prepares a GPT/FAT32 USB, copies Windows setup files, and automatically handles large `install.wim` files by splitting them for FAT32 compatibility.

## Features
- Simple interactive flow (drag‑and‑drop ISO path supported)
- Works with a single GPT + FAT32 data partition (plus ESP)
- Automatically splits `install.wim` > 4 GiB using `wimlib-imagex`
- Uses only native macOS tools (`diskutil`, `hdiutil`, `rsync`) plus `wimlib` when needed
- Defensive checks to avoid selecting your system disk

## Requirements
- macOS with Terminal access
- A USB flash drive (16 GB+ recommended). The target disk WILL BE ERASED.
- Windows 11 ISO (download from Microsoft)
- Tools used by the script:
  - `diskutil`, `hdiutil`, `rsync` (preinstalled on macOS)
  - `wimlib-imagex` (only required if `install.wim` > 4 GiB)
    - Recommended install: `brew install wimlib`
    - If Homebrew is not installed, the script will try to use it if present; otherwise it will ask you to install `wimlib` manually.

Optional but helpful:
- Free space on your internal disk at least the size of `install.wim` for faster splitting (script falls back to splitting directly on the USB if space is low).

## Safety Notice
- This process erases the selected disk. Double‑check the disk identifier (e.g., `disk3`).
- The script refuses to operate on the macOS system disk, but you are still responsible for choosing the correct target.

## Usage

Interactive (recommended):
1. Download a Windows 11 ISO from Microsoft.
2. Connect your USB drive.
3. Run the script from Terminal:
   - `bash create_win11_usb.sh`
4. When prompted:
   - Drag and drop the ISO file path and press Enter.
   - Review available disks (`diskutil list`) shown by the script and enter your USB disk (e.g., `disk3` or `/dev/disk3`).
   - Optionally set a volume label (defaults to `WINUSB`).
   - Confirm the erase and creation.
5. Wait for copying and potential `install.wim` splitting to finish.

Non‑interactive examples (pre‑set environment variables):
- `ISO_PATH="~/Downloads/Win11_24H2_English_x64.iso" DISK=disk3 ./create_win11_usb.sh`
- `ISO_PATH="/path/with spaces/Win11.iso" DISK=/dev/disk4 USB_LABEL=WIN11 ./create_win11_usb.sh`

Environment variables respected by the script:
- `ISO_PATH`: Path to the Windows ISO.
- `DISK`: Target disk identifier (e.g., `disk3` or `/dev/disk3`).
- `USB_LABEL`: Volume label for the FAT32 partition (default: `WINUSB`).

## What the Script Does
1. Validates and mounts the ISO read‑only via `hdiutil`.
2. Shows available disks and confirms the target; verifies it’s not your system disk.
3. Erases the target as GPT with a FAT32 partition labeled as requested.
4. Copies all files from the ISO to the USB, excluding `sources/install.wim`.
5. If `install.wim` is present and larger than 4 GiB, splits it into `install.swm` parts using `wimlib-imagex` (3800 MiB chunks) and places them in `sources/`.
6. Detaches the ISO and leaves the USB mounted.

Boot note:
- On many PCs, you may see multiple USB boot entries. Choose the UEFI entry corresponding to the data partition (often labeled with your chosen USB label, sometimes shown as "Partition 2").

## Troubleshooting
- "Failed to recognize or mount the image": Ensure the file is a valid Windows ISO.
- "Disk not found" / "Refusing to operate on the system disk": Recheck the disk identifier from `diskutil list` and select the USB device.
- `wimlib-imagex not found`: Install via Homebrew (`brew install wimlib`). If you don’t use Homebrew, install `wimlib` by another method before re‑running.
- Not enough free space for staging: The script automatically falls back to splitting directly on the USB (slower but fine).
- USB volume not mounted after erase: Unplug/replug the USB and run again, or manually `diskutil mount` the FAT32 partition.
- ISOs using `install.esd`: The script only excludes `install.wim`; if the ISO contains `install.esd` instead, it will be copied as‑is (no split required).

## File Reference
- `create_win11_usb.sh`: Main script that prepares the USB and copies/splits Windows setup files.

## Disclaimer
Use at your own risk. This script erases disks and operates on low‑level volumes. Review and understand the steps before proceeding.

