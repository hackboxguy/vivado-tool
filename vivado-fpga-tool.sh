#!/bin/bash
# vivado-fpga-tool - Vivado FPGA SPI Flash Tool
# Test version (without CMake configuration)

# set -e  # Exit on error (disabled for debugging)
set -o pipefail  # Pipe failures propagate

# Version information (for testing, will be substituted by CMake)
readonly VERSION="1.0.0-dev"
readonly INSTALL_SHARE_DIR=""  # Empty for portable mode
readonly INSTALL_VIVADO_PATH=""  # Not set

# Resolve dependencies directory
resolve_depends_dir() {
    local depends_dir=""

    if [[ -n "${OPT_DEPENDS:-}" ]]; then
        depends_dir="$OPT_DEPENDS"
    elif [[ -n "${VIVADO_FPGA_TOOL_HOME:-}" ]]; then
        depends_dir="$VIVADO_FPGA_TOOL_HOME"
    elif [[ -n "${INSTALL_SHARE_DIR:-}" ]] && [[ "$INSTALL_SHARE_DIR" != "@"*"@" ]] && [[ -n "$INSTALL_SHARE_DIR" ]]; then
        # CMake-configured path (check it's not a placeholder)
        depends_dir="$INSTALL_SHARE_DIR"
    else
        # Portable mode: auto-detect from script location
        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        depends_dir="$script_dir"
    fi

    # Validate dependency directory
    if [[ ! -d "$depends_dir/lib" ]]; then
        echo "ERROR: Invalid dependency directory: $depends_dir" >&2
        echo "Expected to find: $depends_dir/lib/" >&2
        exit 1
    fi

    echo "$depends_dir"
}

# Initialize environment
DEPENDS_DIR=$(resolve_depends_dir)
LIB_DIR="${DEPENDS_DIR}/lib"
BOARD_DIR="${DEPENDS_DIR}/boards"
TEMPLATE_DIR="${DEPENDS_DIR}/tcl-templates"

# Source library files
# shellcheck disable=SC1090,SC1091
source "${LIB_DIR}/common.sh" || { echo "ERROR: Failed to load common.sh" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
source "${LIB_DIR}/platform.sh" || die "Failed to load platform.sh" 1
# shellcheck disable=SC1090,SC1091
source "${LIB_DIR}/board.sh" || die "Failed to load board.sh" 1
# shellcheck disable=SC1090,SC1091
source "${LIB_DIR}/vivado.sh" || die "Failed to load vivado.sh" 1
# shellcheck disable=SC1090,SC1091
source "${LIB_DIR}/tcl.sh" || die "Failed to load tcl.sh" 1

# Global options (set by argument parser)
OPT_BOARD=""
OPT_VIVADO=""
OPT_DEPENDS=""
OPT_PLATFORM=""
OPT_FORMAT="human"
OPT_LOG=""
VERBOSE=0
QUIET=0

# Command-specific options
OPT_FILE=""      # Binary file for flash/dump/verify
OPT_VERIFY=0     # Verify flag for flash command
OPT_SIZE=""      # Size for dump command

# Command to execute
COMMAND=""

# Parse command line arguments
parse_arguments() {
    [[ $# -eq 0 ]] && { show_usage; exit 0; }

    # Check for global options first (--help, --version)
    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi

    if [[ "$1" == "--version" ]]; then
        echo "vivado-fpga-tool version ${VERSION}"
        exit 0
    fi

    # First argument is the command
    COMMAND="$1"
    shift

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --board=*)
                OPT_BOARD="${1#*=}"
                shift
                ;;
            --vivado=*)
                OPT_VIVADO="${1#*=}"
                shift
                ;;
            --depends=*)
                OPT_DEPENDS="${1#*=}"
                shift
                ;;
            --platform=*)
                OPT_PLATFORM="${1#*=}"
                shift
                ;;
            --format=*)
                OPT_FORMAT="${1#*=}"
                shift
                ;;
            --log=*)
                OPT_LOG="${1#*=}"
                shift
                ;;
            --file=*)
                OPT_FILE="${1#*=}"
                shift
                ;;
            --size=*)
                OPT_SIZE="${1#*=}"
                shift
                ;;
            --verify)
                OPT_VERIFY=1
                shift
                ;;
            --verbose|-v)
                VERBOSE=1
                shift
                ;;
            --quiet|-q)
                QUIET=1
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            --version)
                echo "vivado-fpga-tool version ${VERSION}"
                exit 0
                ;;
            *)
                die "Unknown option: $1\n\nUse --help for usage information." "$EXIT_INVALID_ARGS"
                ;;
        esac
    done

    # Export options for library functions
    export OPT_BOARD OPT_VIVADO OPT_DEPENDS OPT_PLATFORM
    export OPT_FILE OPT_VERIFY OPT_SIZE
    export OUTPUT_FORMAT="$OPT_FORMAT"
    export VERBOSE QUIET
}

# Command: info - Display FPGA and flash information
cmd_info() {
    log_stage 1 "Connecting to FPGA"

    # Check if board is specified
    if [[ -z "$OPT_BOARD" ]]; then
        # Auto-detection mode (no board config)
        log_info "No board specified - running auto-detection mode"

        # Try to load default configuration (optional)
        load_default_config || true

        # Find Vivado
        find_vivado_path

        # Check USB attachment (WSL2 only)
        if ! check_usb_attachment; then
            die "USB JTAG device attached to WSL2. Please detach it first." "$EXIT_PLATFORM_ERROR"
        fi

        # Create temporary directory for TCL script
        local temp_dir=$(create_temp_dir)
        trap cleanup_temp_files EXIT

        # Generate auto-detect TCL script
        log_stage 2 "Generating auto-detect TCL script"
        local tcl_script="${temp_dir}/info.tcl"
        generate_info_autodetect_tcl "$tcl_script"

        # Execute Vivado
        log_stage 3 "Scanning JTAG chain"
        log_info "This may take a few moments..."

        if ! execute_vivado "$tcl_script" "$LOG_FILE"; then
            log_status "FAILURE"
            die "Failed to detect FPGA devices" "$EXIT_FPGA_CONNECT_FAILED"
        fi

        # Extract device info from log
        extract_device_info "$LOG_FILE"

        log_status "SUCCESS"

        # Show summary
        if [[ -n "$DETECTED_DEVICE_COUNT" ]]; then
            log_info "Devices found: $DETECTED_DEVICE_COUNT"
        fi
        if [[ -n "$DETECTED_FPGA_PART" ]]; then
            log_info "FPGA detected: $DETECTED_FPGA_PART"
        fi

        return 0
    else
        # Board-specific mode (with board config)
        # Load board configuration
        load_board_config "$OPT_BOARD"

        # Find Vivado
        find_vivado_path

        # Check USB attachment (WSL2 only)
        if ! check_usb_attachment; then
            die "USB JTAG device attached to WSL2. Please detach it first." "$EXIT_PLATFORM_ERROR"
        fi

        # Create temporary directory for TCL script
        local temp_dir=$(create_temp_dir)
        trap cleanup_temp_files EXIT

        # Generate TCL script
        log_stage 2 "Generating TCL script"
        local tcl_script="${temp_dir}/info.tcl"
        generate_info_tcl "$tcl_script"

        # Execute Vivado
        log_stage 3 "Executing Vivado Hardware Manager"
        log_info "This may take a few moments..."

        if ! execute_vivado "$tcl_script" "$LOG_FILE"; then
            log_status "FAILURE"
            die "Failed to detect FPGA/Flash" "$EXIT_FPGA_CONNECT_FAILED"
        fi

        # Extract device info from log
        extract_device_info "$LOG_FILE"

        log_status "SUCCESS"

        # Show summary
        if [[ -n "$DETECTED_FPGA_PART" ]]; then
            log_info "FPGA detected: $DETECTED_FPGA_PART"
        fi
        if [[ -n "$DETECTED_FLASH_PART" ]]; then
            log_info "Flash detected: $DETECTED_FLASH_PART"
        fi

        return 0
    fi
}

# Command: dump - Readback SPI flash contents to binary file
cmd_dump() {
    # Validate required options
    [[ -z "$OPT_BOARD" ]] && die "Dump command requires --board=<name>" "$EXIT_INVALID_ARGS"
    [[ -z "$OPT_FILE" ]] && die "Dump command requires --file=<output_file>" "$EXIT_INVALID_ARGS"

    log_stage 1 "Initializing flash readback operation"
    log_info "Board: $OPT_BOARD"
    log_info "Output file: $OPT_FILE"

    # Load board configuration
    load_board_config "$OPT_BOARD"

    # Determine readback size (from --size or board config)
    local readback_size="${OPT_SIZE:-$DEFAULT_FLASH_SIZE}"
    log_info "Readback size: $readback_size"

    # Find Vivado
    find_vivado_path

    # Check USB attachment (WSL2 only)
    if ! check_usb_attachment; then
        die "USB JTAG device attached to WSL2. Please detach it first." "$EXIT_PLATFORM_ERROR"
    fi

    # Create temporary directory for TCL script
    local temp_dir=$(create_temp_dir)
    trap cleanup_temp_files EXIT

    # Convert file path to absolute path (required for all platforms)
    # Vivado runs from temp directory, so relative paths won't work
    local output_file=$(readlink -f "$OPT_FILE" 2>/dev/null || echo "$PWD/$OPT_FILE")

    # Create parent directory if it doesn't exist
    local output_dir=$(dirname "$output_file")
    mkdir -p "$output_dir" 2>/dev/null || true

    # Generate TCL script
    log_stage 2 "Generating dump TCL script"
    local tcl_script="${temp_dir}/dump.tcl"
    generate_dump_tcl "$tcl_script" "$output_file" "$readback_size"

    # Execute Vivado
    log_stage 3 "Executing Vivado Hardware Manager"
    log_info "This may take several minutes depending on flash size..."

    if ! execute_vivado "$tcl_script" "$LOG_FILE"; then
        log_status "FAILURE"

        # Try to determine specific error from log
        if grep -qi "not detected\|not found" "$LOG_FILE" 2>/dev/null; then
            die "Flash device not detected" "$EXIT_FLASH_NOT_DETECTED"
        elif grep -qi "file.*error\|cannot.*write" "$LOG_FILE" 2>/dev/null; then
            die "Output file error" "$EXIT_FILE_IO_ERROR"
        else
            die "Flash readback failed" "$EXIT_VIVADO_ERROR"
        fi
    fi

    log_status "SUCCESS"
    log_success "Flash readback completed successfully"

    # Show file size
    if [[ -f "$OPT_FILE" ]]; then
        local file_size=$(stat -f%z "$OPT_FILE" 2>/dev/null || stat -c%s "$OPT_FILE" 2>/dev/null || echo "unknown")
        log_info "Output file size: $file_size bytes"
    fi

    return 0
}

# Command: flash - Program SPI flash with binary file
cmd_flash() {
    # Validate required options
    [[ -z "$OPT_BOARD" ]] && die "Flash command requires --board=<name>" "$EXIT_INVALID_ARGS"
    [[ -z "$OPT_FILE" ]] && die "Flash command requires --file=<binary_file>" "$EXIT_INVALID_ARGS"

    # Check if binary file exists
    check_file_readable "$OPT_FILE" "Binary file not found or not readable: $OPT_FILE"

    log_stage 1 "Initializing flash operation"
    log_info "Board: $OPT_BOARD"
    log_info "Binary file: $OPT_FILE"
    [[ $OPT_VERIFY -eq 1 ]] && log_info "Verify: enabled" || log_info "Verify: disabled"

    # Load board configuration
    load_board_config "$OPT_BOARD"

    # Find Vivado
    find_vivado_path

    # Check USB attachment (WSL2 only)
    if ! check_usb_attachment; then
        die "USB JTAG device attached to WSL2. Please detach it first." "$EXIT_PLATFORM_ERROR"
    fi

    # Create temporary directory for TCL script
    local temp_dir=$(create_temp_dir)
    trap cleanup_temp_files EXIT

    # Convert file path to absolute path (required for all platforms)
    # Vivado runs from temp directory, so relative paths won't work
    local binary_file=$(readlink -f "$OPT_FILE")

    # Generate TCL script
    log_stage 2 "Generating flash TCL script"
    local tcl_script="${temp_dir}/flash.tcl"
    generate_flash_tcl "$tcl_script" "$binary_file" "$OPT_VERIFY"

    # Execute Vivado
    log_stage 3 "Executing Vivado Hardware Manager"
    log_info "This may take several minutes depending on file size..."

    if ! execute_vivado "$tcl_script" "$LOG_FILE"; then
        log_status "FAILURE"

        # Try to determine specific error from log
        if grep -qi "erase.*fail" "$LOG_FILE" 2>/dev/null; then
            die "Flash erase operation failed" "$EXIT_FLASH_ERASE_FAILED"
        elif grep -qi "program.*fail\|write.*fail" "$LOG_FILE" 2>/dev/null; then
            die "Flash programming operation failed" "$EXIT_FLASH_WRITE_FAILED"
        elif grep -qi "verify.*fail" "$LOG_FILE" 2>/dev/null; then
            die "Flash verification failed" "$EXIT_FLASH_VERIFY_FAILED"
        elif grep -qi "not detected\|not found" "$LOG_FILE" 2>/dev/null; then
            die "Flash device not detected" "$EXIT_FLASH_NOT_DETECTED"
        else
            die "Flash programming failed" "$EXIT_VIVADO_ERROR"
        fi
    fi

    log_status "SUCCESS"
    log_success "Flash programming completed successfully"

    [[ $OPT_VERIFY -eq 1 ]] && log_info "Flash verification: PASSED"
    log_info "Power cycle the board to boot from the new flash image"

    return 0
}

# Main execution
main() {
    # Parse arguments
    parse_arguments "$@"

    # Detect platform (can be overridden by --platform)
    if [[ -n "$OPT_PLATFORM" ]]; then
        PLATFORM="$OPT_PLATFORM"
        case "$PLATFORM" in
            wsl2)
                IS_WSL2=1
                IS_LINUX=0
                IS_WINDOWS=0
                ;;
            linux)
                IS_WSL2=0
                IS_LINUX=1
                IS_WINDOWS=0
                ;;
            windows)
                IS_WSL2=0
                IS_LINUX=0
                IS_WINDOWS=1
                ;;
            *)
                die "Invalid platform: $OPT_PLATFORM (valid: wsl2, linux, windows)" "$EXIT_PLATFORM_ERROR"
                ;;
        esac
        log_debug "Platform overridden: $PLATFORM"
    else
        detect_platform
    fi

    # Initialize logging
    if [[ -n "$OPT_LOG" ]]; then
        LOG_FILE="$OPT_LOG"
        mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || die "Cannot create log directory: $(dirname "$LOG_FILE")" "$EXIT_FILE_IO_ERROR"
        touch "$LOG_FILE" || die "Cannot create log file: $LOG_FILE" "$EXIT_FILE_IO_ERROR"
        log_debug "Custom log file: $LOG_FILE"
    else
        init_log_file "$COMMAND"
    fi

    log_debug "========================================"
    log_debug "vivado-fpga-tool v${VERSION}"
    log_debug "Command: $COMMAND"
    log_debug "Platform: $PLATFORM"
    log_debug "Depends: $DEPENDS_DIR"
    log_debug "========================================"

    # Execute command
    case "$COMMAND" in
        info)
            cmd_info
            ;;
        flash)
            cmd_flash
            ;;
        dump)
            cmd_dump
            ;;
        verify)
            die "Command '$COMMAND' not yet implemented. Coming soon!" "$EXIT_INVALID_ARGS"
            ;;
        *)
            die "Unknown command: $COMMAND\n\nUse --help for usage information." "$EXIT_INVALID_ARGS"
            ;;
    esac

    log_debug "Command completed successfully"
    [[ -n "$LOG_FILE" ]] && log_info "Log file: $LOG_FILE"
}

# Run main function
main "$@"
