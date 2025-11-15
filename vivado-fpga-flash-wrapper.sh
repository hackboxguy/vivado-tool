#!/bin/sh
#
# vivado-fpga-flash-wrapper.sh - Wrapper for vivado-fpga-tool.sh with USB stick priority
# Provides USB stick priority for flash and dump operations
# Based on USB detection logic from fpga-jtag-flasher.sh

set -e  # Exit on any error

# Default paths (can be overridden by environment or arguments)
DEFAULT_VIVADO_PATH="/home/pi/Xilinx/2025.1/Vivado_Lab"
DEFAULT_BOARD="xc7s50-is25lp128f"
DEFAULT_BITBIN_DIR="/home/pi/micropanel/usr/bitbin"
DEFAULT_BACKUP_DIR="/home/pi/micropanel/vivado-tool/backups"
DEFAULT_VIVADO_TOOL="$(dirname "$0")/vivado-fpga-tool.sh"

# USB stick configuration
USB_MOUNT_POINT="/tmp/micropanel-usb"
USB_MOUNTED_BY_SCRIPT=0

VERBOSE=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1" >&2
}

log_success() {
    printf "${GREEN}[SUCCESS]${NC} %s\n" "$1" >&2
}

log_warning() {
    printf "${YELLOW}[WARNING]${NC} %s\n" "$1" >&2
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

# Detect USB stick device
detect_usb_stick() {
    if [ $VERBOSE -eq 1 ]; then
        log_info "Checking for USB stick..."
    fi

    local usb_device=""

    # Check all /dev/sd* block devices
    for block_dev in /sys/block/sd*; do
        if [ ! -e "$block_dev" ]; then
            continue
        fi

        local dev_name=$(basename "$block_dev")
        local removable=$(cat "$block_dev/removable" 2>/dev/null || echo "0")

        # Check if it's removable (USB sticks have removable=1)
        if [ "$removable" = "1" ]; then
            # Found a removable device, now find its first partition
            if [ -e "/dev/${dev_name}1" ]; then
                usb_device="/dev/${dev_name}1"
            elif [ -e "/dev/${dev_name}" ]; then
                usb_device="/dev/${dev_name}"
            fi

            if [ -n "$usb_device" ]; then
                if [ $VERBOSE -eq 1 ]; then
                    log_info "Found USB stick: $usb_device"
                fi
                echo "$usb_device"
                return 0
            fi
        fi
    done

    return 1
}

# Detect filesystem type
detect_filesystem() {
    local device="$1"

    # Try to detect filesystem using blkid
    if command -v blkid >/dev/null 2>&1; then
        local fstype=$(sudo blkid -o value -s TYPE "$device" 2>/dev/null)
        if [ -n "$fstype" ]; then
            echo "$fstype"
            return 0
        fi
    fi

    # Default: assume vfat (most common for USB sticks)
    echo "vfat"
    return 0
}

# Mount USB stick if not already mounted
mount_usb_stick() {
    local device="$1"

    # Check if already mounted
    if mount | grep -q "$device"; then
        local existing_mount=$(mount | grep "$device" | awk '{print $3}' | head -1)
        if [ $VERBOSE -eq 1 ]; then
            log_info "USB stick already mounted at: $existing_mount"
        fi
        echo "$existing_mount"
        USB_MOUNTED_BY_SCRIPT=0
        return 0
    fi

    # Create mount point if it doesn't exist
    if [ ! -d "$USB_MOUNT_POINT" ]; then
        if ! sudo mkdir -p "$USB_MOUNT_POINT"; then
            log_error "Failed to create mount point: $USB_MOUNT_POINT"
            return 1
        fi
    fi

    # Detect filesystem type
    local fstype=$(detect_filesystem "$device")
    if [ $VERBOSE -eq 1 ]; then
        log_info "Detected filesystem type: $fstype"
    fi

    # Mount the USB stick
    if [ $VERBOSE -eq 1 ]; then
        log_info "Mounting USB stick to: $USB_MOUNT_POINT"
    fi

    if sudo mount -t "$fstype" "$device" "$USB_MOUNT_POINT" 2>/dev/null; then
        if [ $VERBOSE -eq 1 ]; then
            log_success "USB stick mounted successfully"
        fi
        USB_MOUNTED_BY_SCRIPT=1
        echo "$USB_MOUNT_POINT"
        return 0
    else
        # Try auto-detection
        if sudo mount "$device" "$USB_MOUNT_POINT" 2>/dev/null; then
            if [ $VERBOSE -eq 1 ]; then
                log_success "USB stick mounted successfully (auto-detected)"
            fi
            USB_MOUNTED_BY_SCRIPT=1
            echo "$USB_MOUNT_POINT"
            return 0
        else
            log_error "Failed to mount USB stick"
            return 1
        fi
    fi
}

# Unmount USB stick
unmount_usb_stick() {
    if [ -d "$USB_MOUNT_POINT" ] && mount | grep -q "$USB_MOUNT_POINT"; then
        # Sync filesystem to ensure all writes are flushed to disk
        if [ $VERBOSE -eq 1 ]; then
            log_info "Syncing filesystem before unmount..."
        fi
        sync
        sleep 1  # Give the filesystem a moment to complete sync

        if [ $VERBOSE -eq 1 ]; then
            log_info "Unmounting USB stick from: $USB_MOUNT_POINT"
        fi
        if sudo umount "$USB_MOUNT_POINT" 2>/dev/null; then
            if [ $VERBOSE -eq 1 ]; then
                log_success "USB stick unmounted successfully"
            fi
            USB_MOUNTED_BY_SCRIPT=0
            return 0
        else
            if [ $VERBOSE -eq 1 ]; then
                log_warning "Failed to unmount USB stick"
            fi
            return 1
        fi
    fi
    return 0
}

# Search for file on USB stick
find_file_on_usb() {
    local filename="$1"
    local mount_point="$2"

    if [ $VERBOSE -eq 1 ]; then
        log_info "Searching for file '$filename' on USB stick..."
    fi

    # Search in root directory first
    if [ -f "$mount_point/$filename" ]; then
        if [ $VERBOSE -eq 1 ]; then
            log_success "Found file on USB stick: $mount_point/$filename"
        fi
        echo "$mount_point/$filename"
        return 0
    fi

    # Use find to search recursively
    local found_file=$(find "$mount_point" -type f -name "$filename" 2>/dev/null | head -1)

    if [ -n "$found_file" ] && [ -f "$found_file" ]; then
        if [ $VERBOSE -eq 1 ]; then
            log_success "Found file on USB stick: $found_file"
        fi
        echo "$found_file"
        return 0
    fi

    return 1
}

# Resolve input file path with USB stick priority
resolve_input_file() {
    local filename="$1"
    local default_path="$2"
    local final_file="$default_path"

    if [ $VERBOSE -eq 1 ]; then
        log_info "Resolving input file: $filename"
        log_info "Default path: $default_path"
    fi

    # Try to detect and mount USB stick
    local usb_device
    if usb_device=$(detect_usb_stick); then
        if [ $VERBOSE -eq 1 ]; then
            log_info "USB stick detected: $usb_device"
        fi

        # Try to mount the USB stick
        local mount_point
        if mount_point=$(mount_usb_stick "$usb_device"); then
            # Search for the file on USB stick
            local usb_file
            if usb_file=$(find_file_on_usb "$filename" "$mount_point"); then
                log_success "Using file from USB stick: $usb_file"
                final_file="$usb_file"
            else
                if [ $VERBOSE -eq 1 ]; then
                    log_warning "File not found on USB stick, using default path"
                fi
                log_info "Using internal file: $default_path"
            fi
        else
            if [ $VERBOSE -eq 1 ]; then
                log_warning "Failed to mount USB stick, using default path"
            fi
            log_info "Using internal file: $default_path"
        fi
    else
        if [ $VERBOSE -eq 1 ]; then
            log_info "No USB stick detected, using default path"
        fi
        log_info "Using internal file: $default_path"
    fi

    # Validate final file exists
    if [ ! -f "$final_file" ]; then
        log_error "Input file not found: $final_file"
        unmount_usb_stick
        return 1
    fi

    echo "$final_file"
    return 0
}

# Resolve output file path with USB stick priority
resolve_output_file() {
    local filename="$1"
    local default_path="$2"
    local final_file="$default_path"

    if [ $VERBOSE -eq 1 ]; then
        log_info "Resolving output file: $filename"
        log_info "Default path: $default_path"
    fi

    # Try to detect and mount USB stick
    local usb_device
    if usb_device=$(detect_usb_stick); then
        if [ $VERBOSE -eq 1 ]; then
            log_info "USB stick detected: $usb_device"
        fi

        # Try to mount the USB stick
        local mount_point
        if mount_point=$(mount_usb_stick "$usb_device"); then
            # Use USB stick for output
            final_file="$mount_point/$filename"
            log_success "Will write to USB stick: $final_file"
        else
            if [ $VERBOSE -eq 1 ]; then
                log_warning "Failed to mount USB stick, using default path"
            fi
            log_info "Will write to internal path: $default_path"
        fi
    else
        if [ $VERBOSE -eq 1 ]; then
            log_info "No USB stick detected, using default path"
        fi
        log_info "Will write to internal path: $default_path"
    fi

    # Create parent directory if it doesn't exist (for default path)
    if [ "$final_file" = "$default_path" ]; then
        local output_dir=$(dirname "$final_file")
        if [ ! -d "$output_dir" ]; then
            mkdir -p "$output_dir" 2>/dev/null || true
        fi
    fi

    echo "$final_file"
    return 0
}

# Show usage
show_usage() {
    cat << EOF
Usage: $(basename "$0") --operation=OPERATION --file=FILENAME [OPTIONS]

Wrapper for vivado-fpga-tool.sh with USB stick priority support

Operations:
  flash       Flash FPGA from bitbin directory (USB priority for input)
  dump        Dump FPGA flash to backup file (USB priority for output)
  revert      Flash FPGA from backup file (USB priority for input)

Required Options:
  --operation=OP     Operation to perform (flash|dump|revert)
  --file=NAME        Base filename without extension (e.g., 14-6-fhd)

Optional Options:
  --vivado=PATH      Vivado installation path (default: $DEFAULT_VIVADO_PATH)
  --board=NAME       Board configuration name (default: $DEFAULT_BOARD)
  --bitbin=DIR       Bitbin directory (default: $DEFAULT_BITBIN_DIR)
  --backup=DIR       Backup directory (default: $DEFAULT_BACKUP_DIR)
  --verbose          Enable verbose output

Examples:
  $(basename "$0") --operation=flash --file=14-6-fhd
  $(basename "$0") --operation=dump --file=14-6-fhd --verbose
  $(basename "$0") --operation=revert --file=14-6-fhd

USB Priority Behavior:
  flash:   Checks USB for <filename>.bin, falls back to bitbin directory
  dump:    Writes to USB as <filename>.bin.bkup if available, else backup directory
  revert:  Checks USB for <filename>.bin.bkup, falls back to backup directory

EOF
}

# Main function
main() {
    local operation=""
    local filename=""
    local vivado_path="$DEFAULT_VIVADO_PATH"
    local board="$DEFAULT_BOARD"
    local bitbin_dir="$DEFAULT_BITBIN_DIR"
    local backup_dir="$DEFAULT_BACKUP_DIR"
    local vivado_tool="$DEFAULT_VIVADO_TOOL"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --operation=*)
                operation="${1#*=}"
                shift
                ;;
            --file=*)
                filename="${1#*=}"
                shift
                ;;
            --vivado=*)
                vivado_path="${1#*=}"
                shift
                ;;
            --board=*)
                board="${1#*=}"
                shift
                ;;
            --bitbin=*)
                bitbin_dir="${1#*=}"
                shift
                ;;
            --backup=*)
                backup_dir="${1#*=}"
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$operation" ]; then
        log_error "Operation not specified (--operation required)"
        show_usage
        exit 1
    fi

    if [ -z "$filename" ]; then
        log_error "Filename not specified (--file required)"
        show_usage
        exit 1
    fi

    # Check if vivado-fpga-tool.sh exists
    if [ ! -x "$vivado_tool" ]; then
        log_error "vivado-fpga-tool.sh not found or not executable: $vivado_tool"
        exit 1
    fi

    # Execute operation
    case "$operation" in
        flash)
            # Flash from bitbin directory with USB priority
            log_info "Operation: Flash FPGA from bitbin"
            local input_file
            if ! input_file=$(resolve_input_file "${filename}.bin" "${bitbin_dir}/${filename}.bin"); then
                unmount_usb_stick
                exit 1
            fi

            log_info "Flashing from: $input_file"
            if ! "$vivado_tool" flash --vivado="$vivado_path" --board="$board" --file="$input_file"; then
                log_error "Flash operation failed"
                unmount_usb_stick
                exit 1
            fi

            log_success "Flash operation completed successfully"
            unmount_usb_stick
            ;;

        dump)
            # Dump to temporary location first, then copy to USB or local backup
            log_info "Operation: Dump FPGA flash to backup"

            # Create temporary dump file
            local temp_dump="/tmp/vivado-dump-$$.bin"
            log_info "Dumping to temporary file: $temp_dump"

            if ! "$vivado_tool" dump --vivado="$vivado_path" --board="$board" --file="$temp_dump"; then
                log_error "Dump operation failed"
                rm -f "$temp_dump"
                unmount_usb_stick
                exit 1
            fi

            # Verify temp file was created
            if [ ! -f "$temp_dump" ]; then
                log_error "Dump file was not created: $temp_dump"
                unmount_usb_stick
                exit 1
            fi

            local file_size=$(stat -c%s "$temp_dump" 2>/dev/null || echo "0")
            log_info "Dump completed successfully (size: $file_size bytes)"

            # Generate timestamp for archive copy
            local timestamp=$(date +%Y%m%d-%H%M%S)
            local base_filename="${filename}.bin.bkup"
            local archive_filename="${filename}-${timestamp}.bin.bkup"

            # Try to detect and mount USB stick for output
            local usb_device
            local final_destination="local backup"

            if usb_device=$(detect_usb_stick); then
                log_info "USB stick detected for backup storage"
                local mount_point
                if mount_point=$(mount_usb_stick "$usb_device"); then
                    log_info "Copying dump to USB stick..."

                    # Copy as base filename (for easy restore) - use sudo for USB write
                    if sudo cp "$temp_dump" "$mount_point/$base_filename"; then
                        log_success "Created restore point: $mount_point/$base_filename"
                    else
                        log_error "Failed to copy base file to USB"
                    fi

                    # Copy as timestamped archive - use sudo for USB write
                    if sudo cp "$temp_dump" "$mount_point/$archive_filename"; then
                        log_success "Created archive: $mount_point/$archive_filename"
                        final_destination="USB stick"
                    else
                        log_error "Failed to copy archive to USB"
                    fi

                    # Sync and unmount
                    sync
                    sleep 2  # Give more time for large file sync
                    unmount_usb_stick
                else
                    log_warning "Failed to mount USB stick, using local backup"
                fi
            else
                log_info "No USB stick detected, using local backup"
            fi

            # If USB failed or not available, save to local backup
            if [ "$final_destination" = "local backup" ]; then
                # Ensure backup directory exists
                mkdir -p "$backup_dir"

                log_info "Copying dump to local backup directory..."

                # Copy as base filename (for easy restore)
                if cp "$temp_dump" "${backup_dir}/$base_filename"; then
                    log_success "Created restore point: ${backup_dir}/$base_filename"
                else
                    log_error "Failed to copy base file to local backup"
                fi

                # Copy as timestamped archive
                if cp "$temp_dump" "${backup_dir}/$archive_filename"; then
                    log_success "Created archive: ${backup_dir}/$archive_filename"
                else
                    log_error "Failed to copy archive to local backup"
                fi
            fi

            # Clean up temporary file
            rm -f "$temp_dump"
            log_info "Temporary dump file cleaned up"

            log_success "Dump operation completed successfully"
            log_info "Backup location: $final_destination"
            ;;

        revert)
            # Flash from backup with USB priority
            log_info "Operation: Revert FPGA from backup"
            local input_file
            if ! input_file=$(resolve_input_file "${filename}.bin.bkup" "${backup_dir}/${filename}.bin.bkup"); then
                unmount_usb_stick
                exit 1
            fi

            log_info "Reverting from: $input_file"
            if ! "$vivado_tool" flash --vivado="$vivado_path" --board="$board" --file="$input_file"; then
                log_error "Revert operation failed"
                unmount_usb_stick
                exit 1
            fi

            log_success "Revert operation completed successfully"
            unmount_usb_stick
            ;;

        *)
            log_error "Unknown operation: $operation"
            show_usage
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
