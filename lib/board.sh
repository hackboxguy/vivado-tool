#!/bin/bash
# lib/board.sh - Board configuration loading and validation
# Part of vivado-fpga-tool

# Board configuration variables (populated by load_board_config)
FPGA_PART=""
FPGA_DEVICE=""        # Optional: explicit device name (e.g., "xcau15p_0"), auto-derived if not set
FLASH_PART=""
JTAG_DEVICE_INDEX=""
DEFAULT_FLASH_SIZE=""
BSCAN_BITSTREAM=""
BOARD_DESCRIPTION=""
BOARD_VIVADO_PATH=""  # Board-specific Vivado path override

# Load default configuration (optional, for auto-detection mode)
# This is a lightweight config that only needs VIVADO_PATH
# Usage: load_default_config
load_default_config() {
    local search_paths=(
        "./boards/default.conf"
        "$HOME/.config/vivado-fpga-tool/boards/default.conf"
        "${BOARD_DIR}/default.conf"
    )

    log_debug "Searching for default config: default.conf"

    for path in "${search_paths[@]}"; do
        log_debug "  Checking: $path"
        if [[ -f "$path" ]]; then
            log_debug "  Found: $path"
            log_info "Loading default configuration"
            log_debug "Config file: $path"

            # Source the configuration file
            # shellcheck disable=SC1090
            source "$path" || {
                log_warn "Failed to load default configuration: $path"
                return 1
            }

            # Export VIVADO_PATH if set in default config
            if [[ -n "${VIVADO_PATH:-}" ]]; then
                export BOARD_VIVADO_PATH="$VIVADO_PATH"
                log_debug "Default Vivado path: $BOARD_VIVADO_PATH"
            fi

            return 0
        fi
    done

    log_debug "No default.conf found (this is optional)"
    return 1
}

# Find board configuration file
# Search order:
#   1. ./boards/<board>.conf
#   2. ~/.config/vivado-fpga-tool/boards/<board>.conf
#   3. $BOARD_DIR/<board>.conf (from --depends)
find_board_config() {
    local board_name="$1"

    local search_paths=(
        "./boards/${board_name}.conf"
        "$HOME/.config/vivado-fpga-tool/boards/${board_name}.conf"
        "${BOARD_DIR}/${board_name}.conf"
    )

    log_debug "Searching for board config: ${board_name}.conf"

    for path in "${search_paths[@]}"; do
        log_debug "  Checking: $path"
        if [[ -f "$path" ]]; then
            log_debug "  Found: $path"
            echo "$path"
            return 0
        fi
    done

    die "Board configuration not found: ${board_name}.conf\n\nSearched in:\n  ${search_paths[*]}" "$EXIT_INVALID_ARGS"
}

# Load board configuration
# Usage: load_board_config <board_name>
load_board_config() {
    local board_name="$1"

    [[ -z "$board_name" ]] && die "Board name not specified. Use --board=<name>" "$EXIT_INVALID_ARGS"

    local config_file=$(find_board_config "$board_name")

    log_info "Loading board configuration: $board_name"
    log_debug "Config file: $config_file"

    # Source the configuration file
    # shellcheck disable=SC1090
    source "$config_file" || die "Failed to load board configuration: $config_file" "$EXIT_INVALID_ARGS"

    # Validate required fields
    validate_board_config

    # Display board info
    log_debug "Board configuration loaded:"
    log_debug "  FPGA Part: $FPGA_PART"
    log_debug "  Flash Part: $FLASH_PART"
    log_debug "  JTAG Index: $JTAG_DEVICE_INDEX"
    log_debug "  Flash Size: $DEFAULT_FLASH_SIZE"
    [[ -n "$BSCAN_BITSTREAM" ]] && log_debug "  BSCAN Bitstream: $BSCAN_BITSTREAM"
    [[ -n "$BOARD_DESCRIPTION" ]] && log_debug "  Description: $BOARD_DESCRIPTION"
    [[ -n "$VIVADO_PATH" ]] && BOARD_VIVADO_PATH="$VIVADO_PATH" && log_debug "  Vivado Path: $VIVADO_PATH"
}

# Validate board configuration
validate_board_config() {
    local errors=()

    # Check required fields
    [[ -z "$FPGA_PART" ]] && errors+=("FPGA_PART is not defined")
    [[ -z "$FLASH_PART" ]] && errors+=("FLASH_PART is not defined")
    [[ -z "$JTAG_DEVICE_INDEX" ]] && errors+=("JTAG_DEVICE_INDEX is not defined")
    [[ -z "$DEFAULT_FLASH_SIZE" ]] && errors+=("DEFAULT_FLASH_SIZE is not defined")

    # If there are errors, die with a comprehensive message
    if [[ ${#errors[@]} -gt 0 ]]; then
        local error_msg="Invalid board configuration:\n"
        for error in "${errors[@]}"; do
            error_msg+="  - $error\n"
        done
        die "$error_msg" "$EXIT_INVALID_ARGS"
    fi

    # Validate JTAG_DEVICE_INDEX is a number
    if ! [[ "$JTAG_DEVICE_INDEX" =~ ^[0-9]+$ ]]; then
        die "Invalid JTAG_DEVICE_INDEX: $JTAG_DEVICE_INDEX (must be a number)" "$EXIT_INVALID_ARGS"
    fi

    # Validate DEFAULT_FLASH_SIZE format (e.g., 16M, 128K, 1G)
    if ! [[ "$DEFAULT_FLASH_SIZE" =~ ^[0-9]+[KMG]?$ ]]; then
        die "Invalid DEFAULT_FLASH_SIZE: $DEFAULT_FLASH_SIZE (expected format: 16M, 128K, etc.)" "$EXIT_INVALID_ARGS"
    fi

    # Check BSCAN_BITSTREAM exists if specified
    if [[ -n "$BSCAN_BITSTREAM" ]]; then
        if [[ ! -f "$BSCAN_BITSTREAM" ]]; then
            log_warn "BSCAN_BITSTREAM specified but file not found: $BSCAN_BITSTREAM"
            log_warn "Will use Vivado auto-generation instead"
            BSCAN_BITSTREAM=""  # Clear it so we use auto-generation
        fi
    else
        log_debug "No BSCAN_BITSTREAM specified, will use Vivado auto-generation"
    fi

    log_debug "Board configuration validated successfully"
}

# Get FPGA device name for Vivado TCL (e.g., "xc7s50_0" from "xc7s50csga324-1")
# Usage: get_fpga_device_name
get_fpga_device_name() {
    # If FPGA_DEVICE is explicitly set in board config, use it
    if [[ -n "$FPGA_DEVICE" ]]; then
        echo "$FPGA_DEVICE"
        return 0
    fi

    # Otherwise, extract base part name (before the package/speed grade)
    # 7-series:    xc7s50csga324-1 -> xc7s50
    #              xc7a35ticsg324-1L -> xc7a35ti
    # UltraScale+: xcau15p-ffvb676-2-e -> xcau15p
    #              xcvu9p-flga2104-2-e -> xcvu9p

    # Pattern 1: 7-series - xc + digit + letter + digits + optional ti
    if [[ "$FPGA_PART" =~ ^(xc[0-9]+[a-z][0-9]+)(ti)? ]]; then
        local base_part="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        echo "${base_part}_${JTAG_DEVICE_INDEX}"
        return 0
    fi

    # Pattern 2: UltraScale/UltraScale+ - xc + letters + digits + optional p
    if [[ "$FPGA_PART" =~ ^(xc[a-z]+[0-9]+)(p)? ]]; then
        local base_part="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        echo "${base_part}_${JTAG_DEVICE_INDEX}"
        return 0
    fi

    die "Cannot parse FPGA part name: $FPGA_PART (use explicit FPGA_DEVICE in board config)" "$EXIT_INVALID_ARGS"
}

# Get FPGA family (for future use)
# Usage: get_fpga_family
get_fpga_family() {
    case "$FPGA_PART" in
        xc7s*|xc7a*|xc7k*|xc7v*)
            echo "7series"
            ;;
        xcau*|xcvu*|xcku*)
            echo "ultrascale"
            ;;
        *)
            log_warn "Unknown FPGA family for part: $FPGA_PART"
            echo "unknown"
            ;;
    esac
}

# Export functions
export -f load_default_config find_board_config load_board_config validate_board_config
export -f get_fpga_device_name get_fpga_family
