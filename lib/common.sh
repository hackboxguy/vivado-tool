#!/bin/bash
# lib/common.sh - Common utilities, logging, and error handling
# Part of vivado-fpga-tool

# Exit codes (matches design spec in VIVADO-TOOL-PROGRESS.md)
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_FPGA_CONNECT_FAILED=2
readonly EXIT_FLASH_NOT_DETECTED=3
readonly EXIT_FLASH_ERASE_FAILED=4
readonly EXIT_FLASH_WRITE_FAILED=5
readonly EXIT_FLASH_VERIFY_FAILED=6
readonly EXIT_VIVADO_ERROR=7
readonly EXIT_FILE_IO_ERROR=8
readonly EXIT_PLATFORM_ERROR=9
readonly EXIT_TIMEOUT=10
readonly EXIT_LOCK_EXISTS=11

# Global configuration (set by main script)
VERBOSE=${VERBOSE:-0}
QUIET=${QUIET:-0}
OUTPUT_FORMAT=${OUTPUT_FORMAT:-human}  # human|machine
LOG_FILE=""

# Color codes for human-readable output
if [[ -t 1 ]] && [[ "$OUTPUT_FORMAT" == "human" ]]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_YELLOW='\033[1;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_RESET='\033[0m'
else
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_RESET=''
fi

# Logging functions
log_info() {
    local message="$1"
    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "INFO:$message"
    else
        echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET}    : $message"
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $message" >> "$LOG_FILE"
}

log_error() {
    local message="$1"
    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "ERROR:$message"
    else
        echo -e "${COLOR_RED}[ERROR]${COLOR_RESET}   : $message" >&2
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $message" >> "$LOG_FILE"
}

log_warn() {
    local message="$1"
    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "WARN:$message"
    else
        echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET}    : $message" >&2
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $message" >> "$LOG_FILE"
}

log_debug() {
    local message="$1"
    [[ $VERBOSE -eq 0 ]] && return

    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "DEBUG:$message" >&2
    else
        echo -e "${COLOR_RESET}[DEBUG]${COLOR_RESET}   : $message" >&2
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [DEBUG] $message" >> "$LOG_FILE"
}

log_success() {
    local message="$1"
    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "SUCCESS:$message"
    else
        echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} : $message"
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [SUCCESS] $message" >> "$LOG_FILE"
}

# Machine output - stage transitions
log_stage() {
    local stage_num="$1"
    local stage_desc="$2"

    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "STAGE:${stage_num}:${stage_desc}"
    else
        log_info "[$stage_num/5] $stage_desc"
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [STAGE $stage_num] $stage_desc" >> "$LOG_FILE"
}

# Machine output - progress updates
log_progress() {
    local stage_num="$1"
    local percent="$2"

    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "PROGRESS:${stage_num}:${percent}"
    else
        [[ $QUIET -eq 0 ]] && echo -ne "\r  Progress: ${percent}%   "
    fi
    [[ -n "$LOG_FILE" ]] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] [PROGRESS Stage $stage_num] ${percent}%" >> "$LOG_FILE"
}

# Machine output - final status
log_status() {
    local status="$1"  # SUCCESS or FAILURE

    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "STATUS:${status}"
    else
        if [[ "$status" == "SUCCESS" ]]; then
            log_success "Operation completed successfully"
        else
            log_error "Operation failed"
        fi
    fi
}

# Error handling - print error and exit
die() {
    local message="$1"
    local exit_code="${2:-$EXIT_INVALID_ARGS}"

    log_error "$message"

    if [[ "$OUTPUT_FORMAT" == "machine" ]]; then
        echo "ERROR:${exit_code}:${message}"
        echo "STATUS:FAILURE"
    fi

    exit "$exit_code"
}

# Check if command exists
check_command() {
    local cmd="$1"
    local error_msg="${2:-Command not found: $cmd}"

    if ! command -v "$cmd" &> /dev/null; then
        die "$error_msg" "$EXIT_VIVADO_ERROR"
    fi
}

# Check if file exists and is readable
check_file_readable() {
    local file="$1"
    local error_msg="${2:-File not found or not readable: $file}"

    if [[ ! -f "$file" ]]; then
        die "$error_msg" "$EXIT_FILE_IO_ERROR"
    fi

    if [[ ! -r "$file" ]]; then
        die "File not readable: $file" "$EXIT_FILE_IO_ERROR"
    fi
}

# Check if directory exists and is writable
check_dir_writable() {
    local dir="$1"
    local error_msg="${2:-Directory not writable: $dir}"

    if [[ ! -d "$dir" ]]; then
        die "Directory not found: $dir" "$EXIT_FILE_IO_ERROR"
    fi

    if [[ ! -w "$dir" ]]; then
        die "$error_msg" "$EXIT_FILE_IO_ERROR"
    fi
}

# Initialize log file
init_log_file() {
    local operation="$1"
    local timestamp=$(date +'%Y%m%d-%H%M%S')
    local log_dir="${LOG_DIR:-/tmp/vivado-logs}"

    # Create log directory if it doesn't exist
    mkdir -p "$log_dir" 2>/dev/null || die "Cannot create log directory: $log_dir" "$EXIT_FILE_IO_ERROR"

    LOG_FILE="${log_dir}/${operation}-${timestamp}.log"

    # Create log file
    touch "$LOG_FILE" 2>/dev/null || die "Cannot create log file: $LOG_FILE" "$EXIT_FILE_IO_ERROR"

    log_debug "Log file initialized: $LOG_FILE"
}

# Parse size specification (e.g., "16M", "128K", "1G") to bytes
parse_size() {
    local size_spec="$1"

    if [[ "$size_spec" =~ ^([0-9]+)([KMG])?$ ]]; then
        local number="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"

        case "$unit" in
            K) echo $((number * 1024)) ;;
            M) echo $((number * 1024 * 1024)) ;;
            G) echo $((number * 1024 * 1024 * 1024)) ;;
            *) echo "$number" ;;
        esac
    else
        die "Invalid size specification: $size_spec" "$EXIT_INVALID_ARGS"
    fi
}

# Cleanup function (trap on EXIT)
cleanup_temp_files() {
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        log_debug "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi
}

# Show usage/help (to be overridden by main script)
show_usage() {
    cat << EOF
vivado-fpga-tool - Vivado FPGA SPI Flash Tool

Usage:
  vivado-fpga-tool <command> [options]

Commands:
  flash       Program SPI flash with binary file
  dump        Read SPI flash to binary file
  verify      Verify SPI flash contents
  info        Display FPGA and flash information (auto-detects if no board specified)

Global Options:
  --board=<name>      Board configuration name (required for flash/dump/verify, optional for info)
  --vivado=<path>     Vivado installation path (or set VIVADO_PATH in boards/default.conf)
  --depends=<path>    Override dependency directory
  --platform=<type>   Platform type (wsl2|linux|windows)
  --format=<type>     Output format (human|machine)
  --quiet             Minimal output (status only)
  --verbose           Detailed debug output
  --log=<path>        Custom log file path
  --help              Show this help message

Note: Create boards/default.conf to set default Vivado path (see boards/default.conf.example)

Flash Command Options:
  --file=<path>       Binary file to program (required)
  --verify            Verify flash contents after programming (optional)

Dump Command Options:
  --file=<path>       Output file for flash dump (required)
  --size=<size>       Flash size to read (e.g., 16M, 128K) (optional, defaults to board config)

Examples:
  # Auto-detect connected FPGAs
  vivado-fpga-tool info                                       # Uses boards/default.conf
  vivado-fpga-tool info --vivado=/mnt/c/Xilinx/2025.1/Vivado # Override Vivado path
  vivado-fpga-tool info --board=xc7s50-is25lp128f            # Uses board config

  # Flash programming
  vivado-fpga-tool flash --board=xc7s50-is25lp128f --file=firmware.bin --verify

  # Dump flash contents
  vivado-fpga-tool dump --board=xc7s50-is25lp128f --file=backup.bin

For more information, see README.md
EOF
}

# Export functions for use in other scripts
export -f log_info log_error log_warn log_debug log_success
export -f log_stage log_progress log_status
export -f die check_command check_file_readable check_dir_writable
export -f init_log_file parse_size cleanup_temp_files
