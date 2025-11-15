#!/bin/bash
# lib/vivado.sh - Vivado path resolution and execution wrapper
# Part of vivado-fpga-tool

# Vivado path (resolved by find_vivado_path)
VIVADO_BIN=""
VIVADO_VERSION=""

# Find Vivado installation path
# Priority order:
#   1. --vivado=<path> (CLI flag)
#   2. Board config VIVADO_PATH
#   3. $VIVADO_ROOT env var
#   4. CMake-embedded default (@VIVADO_PATH@)
#   5. Auto-detect from $PATH
find_vivado_path() {
    local vivado_path=""

    # Priority 1: CLI flag (set by main script as OPT_VIVADO)
    if [[ -n "${OPT_VIVADO:-}" ]]; then
        vivado_path="$OPT_VIVADO"
        log_debug "Vivado path from CLI flag: $vivado_path"
    # Priority 2: Board configuration
    elif [[ -n "${BOARD_VIVADO_PATH:-}" ]]; then
        vivado_path="$BOARD_VIVADO_PATH"
        log_debug "Vivado path from board config: $vivado_path"
    # Priority 3: Environment variable
    elif [[ -n "${VIVADO_ROOT:-}" ]]; then
        vivado_path="$VIVADO_ROOT"
        log_debug "Vivado path from VIVADO_ROOT env var: $vivado_path"
    # Priority 4: CMake-embedded (will be substituted during installation)
    elif [[ -n "${INSTALL_VIVADO_PATH:-}" ]]; then
        vivado_path="$INSTALL_VIVADO_PATH"
        log_debug "Vivado path from CMake configuration: $vivado_path"
    # Priority 5: Auto-detect from PATH (check vivado_lab first, then vivado)
    elif command -v vivado_lab &> /dev/null; then
        local vivado_exec=$(command -v vivado_lab)
        # Get directory: /path/to/Vivado_Lab/bin/vivado_lab -> /path/to/Vivado_Lab
        vivado_path=$(dirname "$(dirname "$vivado_exec")")
        log_debug "Vivado Lab path auto-detected from PATH: $vivado_path"
    elif command -v vivado &> /dev/null; then
        local vivado_exec=$(command -v vivado)
        # Get directory: /path/to/Vivado/bin/vivado -> /path/to/Vivado
        vivado_path=$(dirname "$(dirname "$vivado_exec")")
        log_debug "Vivado path auto-detected from PATH: $vivado_path"
    else
        log_error "Vivado or Vivado Lab not found."
        log_error ""
        log_error "Please specify Vivado path using one of these methods:"
        log_error "  1. Create boards/default.conf with VIVADO_PATH:"
        log_error "     cp boards/default.conf.example boards/default.conf"
        log_error "     # Edit boards/default.conf and set VIVADO_PATH"
        log_error ""
        log_error "  2. Use --vivado=<path> flag:"
        log_error "     vivado-fpga-tool info --vivado=/mnt/c/Xilinx/2025.1/Vivado"
        log_error "     vivado-fpga-tool info --vivado=/home/pi/Xilinx/2025.1/Vivado_Lab"
        log_error ""
        log_error "  3. Set VIVADO_ROOT environment variable:"
        log_error "     export VIVADO_ROOT=/mnt/c/Xilinx/2025.1/Vivado"
        log_error ""
        log_error "  4. Use --board=<name> to load Vivado path from board config:"
        log_error "     vivado-fpga-tool info --board=xc7s50-is25lp128f"
        log_error ""
        log_error "Note: Both full Vivado and Vivado Lab Edition are supported."
        log_error ""
        die "Vivado installation not found" "$EXIT_VIVADO_ERROR"
    fi

    # Validate path exists
    if [[ ! -d "$vivado_path" ]]; then
        die "Vivado path does not exist: $vivado_path" "$EXIT_VIVADO_ERROR"
    fi

    # Find the vivado executable (supports both full Vivado and Vivado Lab Edition)
    local vivado_exec=""
    local vivado_bin=""

    # Check for vivado_lab first (Lab Edition), then vivado (full version)
    if [[ $IS_WSL2 -eq 1 ]]; then
        vivado_exec="vivado.bat"
        vivado_bin="${vivado_path}/bin/${vivado_exec}"
    else
        # Native Linux/Windows - check which executable exists
        if [[ -f "${vivado_path}/bin/vivado_lab" ]]; then
            vivado_exec="vivado_lab"
            vivado_bin="${vivado_path}/bin/vivado_lab"
            log_debug "Detected Vivado Lab Edition"
        elif [[ -f "${vivado_path}/bin/vivado" ]]; then
            vivado_exec="vivado"
            vivado_bin="${vivado_path}/bin/vivado"
            log_debug "Detected full Vivado installation"
        elif [[ -f "${vivado_path}/bin/vivado.bat" ]]; then
            vivado_exec="vivado.bat"
            vivado_bin="${vivado_path}/bin/vivado.bat"
            log_debug "Detected Windows Vivado"
        else
            die "Vivado executable not found in: ${vivado_path}/bin/\n\nLooked for: vivado_lab, vivado, vivado.bat" "$EXIT_VIVADO_ERROR"
        fi
    fi

    # For WSL2, convert to WSL path if it's a Windows path
    if [[ $IS_WSL2 -eq 1 ]]; then
        if [[ "$vivado_bin" =~ ^[A-Za-z]:\\ ]]; then
            vivado_bin=$(windows_to_wsl_path "$vivado_bin")
        fi
    fi

    # Check if executable exists and is executable
    if [[ ! -f "$vivado_bin" ]] && [[ $IS_WSL2 -eq 0 ]]; then
        die "Vivado executable not found: $vivado_bin" "$EXIT_VIVADO_ERROR"
    fi

    VIVADO_BIN="$vivado_bin"
    log_info "Vivado found: $vivado_path"
    log_debug "Vivado executable: $VIVADO_BIN"

    # Try to detect Vivado version (optional, non-critical)
    detect_vivado_version "$vivado_path"
}

# Detect Vivado version
detect_vivado_version() {
    local vivado_path="$1"

    # Try to find version from path (e.g., /path/to/Xilinx/2025.1/Vivado -> 2025.1)
    if [[ "$vivado_path" =~ /([0-9]+\.[0-9]+)/ ]]; then
        VIVADO_VERSION="${BASH_REMATCH[1]}"
        log_debug "Vivado version detected from path: $VIVADO_VERSION"
        return 0
    fi

    # Try to detect from vivado -version (can be slow, skip for now)
    log_debug "Could not detect Vivado version from path"
    VIVADO_VERSION="unknown"
}

# Execute Vivado with TCL script
# Usage: execute_vivado <tcl_script> [log_file]
execute_vivado() {
    local tcl_script="$1"
    local log_file="${2:-}"

    [[ ! -f "$tcl_script" ]] && die "TCL script not found: $tcl_script" "$EXIT_VIVADO_ERROR"

    local working_dir=$(dirname "$tcl_script")
    local tcl_basename=$(basename "$tcl_script")

    log_info "Executing Vivado in batch mode..."
    log_debug "TCL script: $tcl_script"
    log_debug "Working directory: $working_dir"

    # Build Vivado command
    local vivado_cmd=""

    if [[ $IS_WSL2 -eq 1 ]]; then
        # WSL2: Execute via cmd.exe
        # Convert paths and double backslashes for cmd.exe (following reference: build_xcau15p_wsl.sh)
        local win_working_dir=$(wsl_to_windows_path "$working_dir" | sed 's/\\/\\\\/g')
        local win_vivado_bin=$(wsl_to_windows_path "$VIVADO_BIN" | sed 's/\\/\\\\/g')

        log_debug "Windows working directory: $win_working_dir"
        log_debug "Windows Vivado executable: $win_vivado_bin"

        vivado_cmd="cd /d $win_working_dir && $win_vivado_bin -mode batch -notrace -source $tcl_basename"

        log_debug "Executing via cmd.exe: $vivado_cmd"

        # Change to the working directory first (avoid UNC path issues)
        # Then execute cmd.exe from a Windows-accessible path
        if [[ $VERBOSE -eq 1 ]]; then
            # Verbose mode: show all output
            if [[ -n "$log_file" ]]; then
                (cd "$working_dir" && cmd.exe /c "$vivado_cmd" 2>&1) | tee -a "$log_file"
            else
                (cd "$working_dir" && cmd.exe /c "$vivado_cmd" 2>&1)
            fi
        else
            # Normal mode: suppress most output, log everything
            if [[ -n "$log_file" ]]; then
                (cd "$working_dir" && cmd.exe /c "$vivado_cmd" 2>&1) >> "$log_file"
            else
                (cd "$working_dir" && cmd.exe /c "$vivado_cmd" 2>&1) > /dev/null
            fi
        fi
    else
        # Native Linux: Direct execution
        vivado_cmd="\"$VIVADO_BIN\" -mode batch -notrace -source \"$tcl_basename\""

        log_debug "Executing: $vivado_cmd"

        # Execute and capture output
        if [[ $VERBOSE -eq 1 ]]; then
            # Verbose mode: show all output
            if [[ -n "$log_file" ]]; then
                (cd "$working_dir" && eval "$vivado_cmd" 2>&1 | tee -a "$log_file")
            else
                (cd "$working_dir" && eval "$vivado_cmd" 2>&1)
            fi
        else
            # Normal mode: suppress most output, log everything
            if [[ -n "$log_file" ]]; then
                (cd "$working_dir" && eval "$vivado_cmd" 2>&1) >> "$log_file"
            else
                (cd "$working_dir" && eval "$vivado_cmd" 2>&1) > /dev/null
            fi
        fi
    fi

    local exit_code=${PIPESTATUS[0]}

    if [[ $exit_code -ne 0 ]]; then
        log_error "Vivado execution failed with exit code: $exit_code"
        [[ -n "$log_file" ]] && log_error "Check log file for details: $log_file"
        return "$EXIT_VIVADO_ERROR"
    fi

    log_debug "Vivado execution completed successfully"
    return 0
}

# Parse Vivado output for progress information
# This is called during Vivado execution to extract progress
# Usage: parse_vivado_progress <line> <current_stage>
parse_vivado_progress() {
    local line="$1"
    local current_stage="$2"

    # Erase operation progress
    if [[ "$line" =~ Performing\ Erase\ Operation ]]; then
        log_progress "$current_stage" 0
    elif [[ "$line" =~ Erase\ Operation\ successful ]]; then
        log_progress "$current_stage" 100
    fi

    # Program operation progress
    if [[ "$line" =~ Performing\ Program\ Operation ]]; then
        log_progress "$current_stage" 0
    elif [[ "$line" =~ Program\ Operation\ successful ]]; then
        log_progress "$current_stage" 100
    fi

    # Program and Verify operation
    if [[ "$line" =~ Performing\ Program\ and\ Verify\ Operations ]]; then
        log_progress "$current_stage" 0
    elif [[ "$line" =~ Program/Verify\ Operation\ successful ]]; then
        log_progress "$current_stage" 100
    fi

    # Readback operation progress
    if [[ "$line" =~ Performing\ Readback\ Operation ]]; then
        log_progress "$current_stage" 0
    elif [[ "$line" =~ Readback\ Operation\ successful ]]; then
        log_progress "$current_stage" 100
    fi

    # Flash detection (Mfg ID, Memory Type, etc.)
    if [[ "$line" =~ Mfg\ ID\ :\ ([0-9a-fA-F]+) ]]; then
        local mfg_id="${BASH_REMATCH[1]}"
        log_debug "Flash detected - Mfg ID: 0x$mfg_id"
    fi
}

# Extract device information from log file
# Usage: extract_device_info <log_file>
extract_device_info() {
    local log_file="$1"

    [[ ! -f "$log_file" ]] && return 1

    # Extract FPGA part name
    local fpga_part=$(grep -oP 'Part Name:\s+\K[^\s]+' "$log_file" | head -1)

    # Extract flash part (if detected)
    local flash_part=$(grep -oP 'Flash Part:\s+\K.+$' "$log_file" | head -1)

    # Extract device count for auto-detect mode
    local device_count=$(grep -oP 'Found \K[0-9]+(?= device)' "$log_file" | head -1)

    # Export for use by calling function
    export DETECTED_FPGA_PART="$fpga_part"
    export DETECTED_FLASH_PART="$flash_part"
    export DETECTED_DEVICE_COUNT="$device_count"
}

# Export functions
export -f find_vivado_path detect_vivado_version
export -f execute_vivado parse_vivado_progress extract_device_info
