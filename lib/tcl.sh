#!/bin/bash
# lib/tcl.sh - TCL script generation from templates
# Part of vivado-fpga-tool

# Generate TCL script from template
# Usage: generate_tcl_script <template_name> <output_file> [additional_vars...]
# Example: generate_tcl_script "info" "/tmp/info.tcl"
generate_tcl_script() {
    local template_name="$1"
    local output_file="$2"
    shift 2

    local template_file="${TEMPLATE_DIR}/${template_name}.tcl.template"

    [[ ! -f "$template_file" ]] && die "TCL template not found: $template_file" "$EXIT_VIVADO_ERROR"

    log_debug "Generating TCL script from template: $template_name"
    log_debug "  Template: $template_file"
    log_debug "  Output: $output_file"

    # Get FPGA device name
    local fpga_device=$(get_fpga_device_name)

    # Prepare variables for substitution
    local vars=(
        "FPGA_PART=$FPGA_PART"
        "FPGA_DEVICE=$fpga_device"
        "FLASH_PART=$FLASH_PART"
        "JTAG_DEVICE_INDEX=$JTAG_DEVICE_INDEX"
        "DEFAULT_FLASH_SIZE=$DEFAULT_FLASH_SIZE"
    )

    # Add any additional variables passed as arguments
    vars+=("$@")

    # Read template and perform substitution
    local content
    content=$(<"$template_file") || die "Failed to read template: $template_file" "$EXIT_VIVADO_ERROR"

    # Perform variable substitution
    for var in "${vars[@]}"; do
        local key="${var%%=*}"
        local value="${var#*=}"

        log_debug "  Substituting: {{$key}} -> $value"

        # Replace {{KEY}} with value
        content="${content//\{\{$key\}\}/$value}"
    done

    # Write output file
    echo "$content" > "$output_file" || die "Failed to write TCL script: $output_file" "$EXIT_FILE_IO_ERROR"

    log_debug "TCL script generated successfully: $output_file"
}

# Generate info command TCL script
# Usage: generate_info_tcl <output_file>
generate_info_tcl() {
    local output_file="$1"

    generate_tcl_script "info" "$output_file"
}

# Generate info auto-detect TCL script (no board config required)
# Usage: generate_info_autodetect_tcl <output_file>
generate_info_autodetect_tcl() {
    local output_file="$1"

    local template_file="${TEMPLATE_DIR}/info-autodetect.tcl.template"

    [[ ! -f "$template_file" ]] && die "TCL template not found: $template_file" "$EXIT_VIVADO_ERROR"

    log_debug "Generating auto-detect TCL script from template: info-autodetect"
    log_debug "  Template: $template_file"
    log_debug "  Output: $output_file"

    # No variable substitution needed for auto-detect
    cp "$template_file" "$output_file" || die "Failed to copy TCL template: $template_file" "$EXIT_FILE_IO_ERROR"

    log_debug "TCL script generated successfully: $output_file"
}

# Generate flash command TCL script
# Usage: generate_flash_tcl <output_file> <binary_file> <verify>
generate_flash_tcl() {
    local output_file="$1"
    local binary_file="$2"
    local verify="${3:-0}"

    # Convert binary file path for platform
    local tcl_binary_file="$binary_file"

    if [[ $IS_WSL2 -eq 1 ]]; then
        # Convert to Windows path for Vivado TCL
        tcl_binary_file=$(wsl_to_windows_path "$binary_file")
        # Convert backslashes to forward slashes (TCL prefers forward slashes)
        tcl_binary_file="${tcl_binary_file//\\/\/}"
    fi

    generate_tcl_script "flash" "$output_file" \
        "BINARY_FILE=$tcl_binary_file" \
        "VERIFY=$verify"
}

# Generate dump (readback) command TCL script
# Usage: generate_dump_tcl <output_file> <output_binary> <size>
generate_dump_tcl() {
    local output_file="$1"
    local output_binary="$2"
    local size="${3:-}"

    # Convert output file path for platform
    local tcl_output_binary="$output_binary"

    if [[ $IS_WSL2 -eq 1 ]]; then
        # Convert to Windows path for Vivado TCL
        tcl_output_binary=$(wsl_to_windows_path "$output_binary")
        # Convert backslashes to forward slashes (TCL prefers forward slashes)
        tcl_output_binary="${tcl_output_binary//\\/\/}"
    fi

    # Determine readback size
    local readback_size="${size:-$DEFAULT_FLASH_SIZE}"

    generate_tcl_script "dump" "$output_file" \
        "OUTPUT_FILE=$tcl_output_binary" \
        "READBACK_SIZE=$readback_size"
}

# Export functions
export -f generate_tcl_script
export -f generate_info_tcl generate_info_autodetect_tcl
export -f generate_flash_tcl generate_dump_tcl
