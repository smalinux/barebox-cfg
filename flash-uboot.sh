#!/bin/bash
#
# barebox_standalone.sh - Flash barebox bootloader to SD card for BeagleBone Black
#
# This script prepares an SD card with barebox bootloader for standalone booting
# on BeagleBone Black. It creates a bootable FAT32 partition and copies the
# necessary barebox components (MLO and barebox.bin).
#
# Prerequisites:
#   - barebox must be built in ./build/images/ directory
#   - Cross-compilation tools (arm-linux-gnueabihf-)
#   - Root privileges for SD card operations
#   - Target SD card device (e.g., /dev/sdb)
#
# Files copied to SD card:
#   - MLO: barebox-am33xx-beaglebone-mlo.mmc.img -> MLO
#   - barebox.bin: barebox-am33xx-beaglebone.img -> barebox.bin
#
# Author: [Your Name]
# Version: 1.0
# Date: $(date +%Y-%m-%d)
#

set -e  # Exit on any error
set -u  # Exit on undefined variables

# === Configuration ===
BASE="am335x_evm"
DEFCONFIG="${BASE}_defconfig"
UENV_FILE="${BASE}.env"
PARTITION_SIZE="+64M"
CROSS_COMPILE="arm-linux-gnueabihf-"

# === Functions ===

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <SD_CARD_DEVICE>

Flash barebox bootloader to SD card for BeagleBone Black standalone booting.

ARGUMENTS:
    SD_CARD_DEVICE    Target SD card device (e.g., /dev/sdb, /dev/mmcblk0)

OPTIONS:
    -h, --help        Show this help message and exit
    -v, --verbose     Enable verbose output (set -x)
    -s, --size SIZE   Partition size (default: +64M)

EXAMPLES:
    $0 /dev/sdb                    # Flash to /dev/sdb
    $0 --verbose /dev/mmcblk0      # Flash with verbose output
    $0 --size +128M /dev/sdc       # Flash with 128M partition

SAFETY:
    This script will DESTROY all data on the target device!
    Make sure you specify the correct SD card device.

PREREQUISITES:
    - Built barebox images in ./build/images/
    - Root privileges (sudo)
    - arm-linux-gnueabihf- toolchain

EOF
}

log_info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

log_warning() {
    echo -e "\e[33m[WARNING]\e[0m $1"
}

validate_environment() {
    log_info "Validating build environment..."

    # Check for required barebox images
    if [[ ! -f "./build/images/barebox-am33xx-beaglebone.img" ]]; then
        log_error "barebox-am33xx-beaglebone.img not found in ./build/images/"
        log_error "Please build barebox first"
        exit 1
    fi

    if [[ ! -f "./build/images/barebox-am33xx-beaglebone-mlo.mmc.img" ]]; then
        log_error "barebox-am33xx-beaglebone-mlo.mmc.img not found in ./build/images/"
        log_error "Please build barebox first"
        exit 1
    fi

    # Check for required tools
    local required_tools=("sudo" "fdisk" "parted" "mkfs.vfat" "fatlabel" "wipefs")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "Required tool '$tool' not found"
            exit 1
        fi
    done

    log_info "Environment validation passed"
}

validate_device() {
    local device="$1"

    log_info "Validating SD card device: $device"

    # Check if device exists
    if [[ ! -b "$device" ]]; then
        log_error "Device $device does not exist or is not a block device"
        exit 1
    fi

    # Check if device is mounted
    if mount | grep -q "$device"; then
        log_warning "Device $device has mounted partitions"
        log_info "Will attempt to unmount them"
    fi

    # Safety check - warn about common system devices
    case "$device" in
        /dev/sda|/dev/nvme0n1|/dev/hda)
            log_warning "WARNING: $device might be your system drive!"
            read -p "Are you sure you want to continue? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                log_info "Operation cancelled by user"
                exit 0
            fi
            ;;
    esac

    log_info "Device validation passed"
}

prepare_sdcard() {
    local device="$1"
    local mount_dir
    mount_dir="$(mktemp -d /tmp/sdcard.XXXXXX)"

    log_info "Preparing SD card: $device"

    # Unmount any mounted partitions
    log_info "Unmounting existing partitions on $device..."
    sudo umount "${device}"* 2>/dev/null || true

    # Check for existing signatures and wipe them
    log_info "Wiping existing filesystem signatures..."
    sudo wipefs -a "$device" 2>/dev/null || true

    # Create new partition table and partition
    log_info "Creating new partition table and partition..."
    cat << EOF | sudo fdisk "$device"
o
n
p
1


$PARTITION_SIZE
t
e
a
1
w
EOF

    # Wait for partition to be recognized
    sleep 2
    sudo partprobe "$device" 2>/dev/null || true
    sleep 1

    # Mark partition as bootable
    log_info "Marking partition as bootable..."
    sudo parted "$device" set 1 boot on

    # Format partition as FAT32
    log_info "Formatting partition as FAT32..."
    sudo mkfs.vfat -F 32 "${device}1"

    # Label the partition
    log_info "Labeling partition as 'boot'..."
    sudo fatlabel "${device}1" boot

    # Mount the partition
    log_info "Mounting SD card partition..."
    sudo mkdir -p "$mount_dir"
    sudo mount "${device}1" "$mount_dir"

    # Copy barebox files
    log_info "Copying barebox components to SD card..."
    sudo cp "./build/images/barebox-am33xx-beaglebone-mlo.mmc.img" "$mount_dir/MLO"
    sudo cp "./build/images/barebox-am33xx-beaglebone.img" "$mount_dir/barebox.bin"

    # Sync and unmount
    log_info "Syncing and unmounting..."
    sudo sync
    sudo umount "$mount_dir"
    sudo rmdir "$mount_dir"

    log_info "SD card preparation complete!"
}

# === Main Script ===

main() {
    local device=""
    local verbose=false

    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                set -x
                shift
                ;;
            -s|--size)
                PARTITION_SIZE="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$device" ]]; then
                    device="$1"
                else
                    log_error "Multiple devices specified"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Check if device was provided
    if [[ -z "$device" ]]; then
        log_error "SD card device not specified"
        show_help
        exit 1
    fi

    # Validate environment and device
    validate_environment
    validate_device "$device"

    # Confirm operation
    log_warning "This will DESTROY all data on $device!"
    read -p "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Operation cancelled by user"
        exit 0
    fi

    # Prepare SD card
    prepare_sdcard "$device"

    log_info "Success! Insert the SD card into BeagleBone Black and boot."
    log_info "The board should boot with barebox bootloader."
}

# Run main function with all arguments
main "$@"
