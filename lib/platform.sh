#!/bin/bash
# lib/platform.sh - Platform detection and path conversion
# Part of vivado-fpga-tool

# Detect platform (WSL2, Linux, Windows)
# Sets global variables: PLATFORM, IS_WSL2, IS_LINUX, IS_WINDOWS
detect_platform() {
    # Check if running under WSL2
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        PLATFORM="wsl2"
        IS_WSL2=1
        IS_LINUX=0
        IS_WINDOWS=0
        log_debug "Platform detected: WSL2 (via WSLInterop)"
        return 0
    fi

    # Alternative WSL2 detection: check /proc/version for "microsoft" or "WSL"
    if [[ "$(uname -s)" == "Linux" ]] && grep -qi "microsoft.*wsl" /proc/version 2>/dev/null; then
        PLATFORM="wsl2"
        IS_WSL2=1
        IS_LINUX=0
        IS_WINDOWS=0
        log_debug "Platform detected: WSL2 (via /proc/version)"
        return 0
    fi

    # Check if running on native Linux
    if [[ "$(uname -s)" == "Linux" ]]; then
        PLATFORM="linux"
        IS_WSL2=0
        IS_LINUX=1
        IS_WINDOWS=0
        log_debug "Platform detected: Native Linux"
        return 0
    fi

    # Check if running on Windows (Git Bash, MSYS2, Cygwin)
    if [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]]; then
        PLATFORM="windows"
        IS_WSL2=0
        IS_LINUX=0
        IS_WINDOWS=1
        log_debug "Platform detected: Windows"
        return 0
    fi

    die "Unsupported platform: $(uname -s)" "$EXIT_PLATFORM_ERROR"
}

# Convert WSL path to Windows path
# Usage: wsl_to_windows_path "/mnt/c/Users/foo/file.txt"
# Returns: "C:\Users\foo\file.txt"
wsl_to_windows_path() {
    local wsl_path="$1"

    # Already a Windows path
    if [[ "$wsl_path" =~ ^[A-Za-z]:\\ ]]; then
        echo "$wsl_path"
        return 0
    fi

    # Convert /mnt/c/... to C:\...
    if [[ "$wsl_path" =~ ^/mnt/([a-z])/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1]}"
        local path="${BASH_REMATCH[2]}"
        # Convert forward slashes to backslashes
        path="${path//\//\\}"
        echo "${drive^^}:\\${path}"
        return 0
    fi

    # Use wslpath if available
    if command -v wslpath &> /dev/null; then
        wslpath -w "$wsl_path" 2>/dev/null && return 0
    fi

    # Fallback: return as-is and warn
    log_warn "Cannot convert WSL path to Windows: $wsl_path"
    echo "$wsl_path"
    return 1
}

# Convert Windows path to WSL path
# Usage: windows_to_wsl_path "C:\Users\foo\file.txt"
# Returns: "/mnt/c/Users/foo/file.txt"
windows_to_wsl_path() {
    local windows_path="$1"

    # Already a WSL/Unix path
    if [[ ! "$windows_path" =~ ^[A-Za-z]:\\ ]]; then
        echo "$windows_path"
        return 0
    fi

    # Convert C:\... to /mnt/c/...
    if [[ "$windows_path" =~ ^([A-Za-z]):\\(.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"  # Lowercase
        local path="${BASH_REMATCH[2]}"
        # Convert backslashes to forward slashes
        path="${path//\\//}"
        echo "/mnt/${drive}/${path}"
        return 0
    fi

    # Use wslpath if available
    if command -v wslpath &> /dev/null; then
        wslpath -u "$windows_path" 2>/dev/null && return 0
    fi

    # Fallback: return as-is and warn
    log_warn "Cannot convert Windows path to WSL: $windows_path"
    echo "$windows_path"
    return 1
}

# Create a temporary directory appropriate for the platform
# On WSL2 with Windows Vivado, creates directory on Windows filesystem
# Returns the path in the appropriate format
create_temp_dir() {
    local prefix="${1:-vivado-fpga-tool}"

    if [[ $IS_WSL2 -eq 1 ]]; then
        # Create temp dir on Windows filesystem for better performance
        local win_temp_dir="C:\\Temp\\${prefix}_$$"
        local wsl_temp_dir="/mnt/c/Temp/${prefix}_$$"

        # Ensure C:\Temp exists
        mkdir -p /mnt/c/Temp 2>/dev/null || die "Cannot create /mnt/c/Temp directory" "$EXIT_PLATFORM_ERROR"

        # Create the temp directory
        mkdir -p "$wsl_temp_dir" || die "Cannot create temporary directory: $wsl_temp_dir" "$EXIT_PLATFORM_ERROR"

        log_debug "Created WSL2 temp directory: $wsl_temp_dir (Windows: $win_temp_dir)"

        # Export both paths as global variables
        export TEMP_DIR_WSL="$wsl_temp_dir"
        export TEMP_DIR_WIN="$win_temp_dir"
        echo "$wsl_temp_dir"
    else
        # Native Linux or Windows - use mktemp
        local temp_dir=$(mktemp -d -t "${prefix}.XXXXXX") || die "Cannot create temporary directory" "$EXIT_PLATFORM_ERROR"

        log_debug "Created temp directory: $temp_dir"

        export TEMP_DIR="$temp_dir"
        echo "$temp_dir"
    fi
}

# Check if USB JTAG device is attached to WSL2
# This is a problem because Windows Vivado won't be able to access it
# Returns: 0 if USB is OK (not attached or not WSL2), 1 if USB is attached to WSL2
check_usb_attachment() {
    [[ $IS_WSL2 -eq 0 ]] && return 0  # Not WSL2, no issue

    # Check for common Xilinx JTAG adapter USB IDs
    # Platform Cable USB II: 03fd:0013
    # Digilent JTAG-HS3: 0403:6014
    local xilinx_usb_ids=("03fd:0013" "0403:6014")

    for usb_id in "${xilinx_usb_ids[@]}"; do
        if lsusb 2>/dev/null | grep -q "$usb_id"; then
            log_warn "USB JTAG device ($usb_id) detected in WSL2!"
            log_warn "This will prevent Windows Vivado from accessing the device."
            log_warn ""
            log_warn "To fix this, detach the USB device from WSL2:"
            log_warn "  usbipd detach --busid <BUSID>"
            log_warn ""
            log_warn "To list attached devices: usbipd list"
            return 1
        fi
    done

    log_debug "No USB JTAG devices attached to WSL2 (good)"
    return 0
}

# Determine Vivado executable name based on platform
# Returns: vivado (Linux) or vivado.bat (Windows)
get_vivado_executable() {
    if [[ $IS_WSL2 -eq 1 ]]; then
        echo "vivado.bat"
    elif [[ $IS_LINUX -eq 1 ]]; then
        echo "vivado"
    elif [[ $IS_WINDOWS -eq 1 ]]; then
        echo "vivado.bat"
    else
        die "Cannot determine Vivado executable for platform: $PLATFORM" "$EXIT_PLATFORM_ERROR"
    fi
}

# Execute command with platform-specific adjustments
# On WSL2, executes Windows commands via cmd.exe
# Usage: platform_execute <working_dir> <command> [args...]
platform_execute() {
    local working_dir="$1"
    shift
    local command="$@"

    if [[ $IS_WSL2 -eq 1 ]]; then
        # Convert working directory to Windows path
        local win_working_dir=$(wsl_to_windows_path "$working_dir")

        log_debug "Executing via cmd.exe in: $win_working_dir"
        log_debug "Command: $command"

        # Execute via cmd.exe
        cmd.exe /c "cd /d $win_working_dir && $command"
    else
        # Native execution
        log_debug "Executing in: $working_dir"
        log_debug "Command: $command"

        (cd "$working_dir" && eval "$command")
    fi
}

# Export global variables
export PLATFORM=""
export IS_WSL2=0
export IS_LINUX=0
export IS_WINDOWS=0

# Export functions
export -f detect_platform
export -f wsl_to_windows_path windows_to_wsl_path
export -f create_temp_dir check_usb_attachment
export -f get_vivado_executable platform_execute
