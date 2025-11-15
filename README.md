# Vivado FPGA Tool

A cross-platform command-line tool for programming Xilinx FPGAs and SPI flash memory via Vivado Hardware Manager.

## Key Features

- **Universal Hardware Support**: Supports ANY Xilinx FPGA and flash chips supported by Vivado Hardware Manager (not limited to specific devices)
- **Cross-Platform**: Works on both native Linux and WSL2 environments
- **Automated TCL Scripting**: Handles JTAG chain detection, BSCAN_SPI bitstream generation, and flash programming
- **Board Configuration System**: Easy hardware definition through simple configuration files

## Prerequisites

This tool requires Vivado Hardware Manager to be pre-installed on your system:
- **Vivado Lab Edition** (free, hardware programming only), or
- **Vivado Full Edition** (includes design tools)

This tool does NOT cover Vivado installation instructions. Please refer to Xilinx documentation for installing Vivado.

## Use Cases

### Remote FPGA Development & Debugging

Traditional Vivado workflows require a full Windows desktop installation with GUI, limiting FPGA programming to a fixed workstation. This TCL/shell-CLI wrapper enables:

- **Headless Remote Flashing**: Deploy on lightweight NUC PCs with barebone Linux (e.g., Arch Linux, no desktop GUI)
- **Network-Connected Programming Stations**: Set up dedicated remote programming devices accessible over SSH
- **Automated CI/CD Integration**: Flash FPGAs as part of automated testing pipelines
- **Multi-Board Development**: Manage multiple target boards from a single lightweight programming host

**Example Setup**: NUC PC + Vivado Lab Edition + vivado-tool = network-accessible FPGA programming server

### Portable FPGA Programming Solution

Combine this tool with lightweight hardware for on-the-go FPGA programming:

**Handheld JTAG Flashing Device**:
- **Hardware**: NUC PC + Platform USB cable + 12V battery pack + USB-based [micropanel](https://github.com/hackboxguy/micropanel) HMI (SSD1306 OLED + pushbuttons)
- **Software**: vivado-tool + [micropanel](https://github.com/hackboxguy/micropanel) daemon integration
- **Capability**: Menu-driven firmware selection and flashing via OLED display, powered by battery
- **Portability**: Bring FPGA programming capability directly to the field or production floor

This eliminates the need to:
- Transport target boards to a fixed programming station
- Maintain bulky desktop workstations for FPGA programming
- Rely on GUI-based workflows that require monitor/keyboard/mouse

### Comparison: Traditional vs. Lightweight Setup

| Aspect | Traditional Setup | vivado-tool + Lab Edition |
|--------|------------------|---------------------------|
| **Host OS** | Windows Desktop with GUI | Linux (no GUI required) |
| **Vivado Edition** | Full Edition (~100GB) | Lab Edition (~3GB) |
| **Hardware** | Desktop workstation | NUC PC or SBC |
| **Interface** | GUI-based Hardware Manager | CLI-based automation |
| **Remote Access** | VNC/RDP (slow, cumbersome) | SSH + scripts |
| **Portability** | Fixed installation | Battery-powered portable option |
| **Automation** | Manual clicks or complex TCL | Simple shell commands |

## Quick Start

### 1. Auto-detect connected FPGAs
```bash
./vivado-fpga-tool.sh info
```

### 2. Flash programming with verification
```bash
./vivado-fpga-tool.sh flash --board=xc7s50-is25lp128f --file=firmware.bin --verify
```

### 3. Dump flash contents to file
```bash
./vivado-fpga-tool.sh dump --board=xc7s50-is25lp128f --file=backup.bin
```

### 4. Override Vivado path (if not in default location)
```bash
./vivado-fpga-tool.sh info --vivado=/mnt/c/Xilinx/2025.1/Vivado
```

## Board Configuration

Board configurations define the FPGA and flash hardware. To add support for new hardware, simply create a configuration file in `boards/` directory.

### Example: boards/xc7s50-is25lp128f.conf
```bash
# FPGA Configuration
FPGA_PART="xc7s50csga324-1"
JTAG_DEVICE_INDEX=0

# SPI Flash Configuration
FLASH_PART="is25lp128f-spi-x1_x2_x4"
DEFAULT_FLASH_SIZE="16M"

# Vivado path
VIVADO_PATH="/mnt/c/Xilinx/2025.1/Vivado"

# Board description
BOARD_DESCRIPTION="XC7S50 Spartan-7 Board (IS25LP128F 16MB SPI Flash)"
```

### Currently Tested Hardware

The following configurations have been tested and validated:
- **7-series**: xc7s50 (Spartan-7) + IS25LP128F flash
- **UltraScale+**: xcau15p (Artix UltraScale+) + IS25WP128F flash

**Note**: These are examples only. The tool can be extended to support any FPGA and flash combination recognized by Vivado Hardware Manager by creating appropriate board configuration files.

## Platform Support

### Native Linux
```bash
# Auto-detects target-hw-fpga
./vivado-fpga-tool.sh info --vivado=/home/pi/Xilinx/2025.1/Vivado_Lab
```

### WSL2 (Windows Subsystem for Linux)
```bash
# Detect target-hw-fpga through Windows Vivado installation from WSL2
./vivado-fpga-tool.sh info --vivado=/mnt/c/Xilinx/2025.1/Vivado
```

## Command Reference

### info - Detect JTAG devices
```bash
./vivado-fpga-tool.sh info [--vivado=PATH] [--board=BOARD] [--log=LOGFILE]
```

### flash - Program SPI flash for board: xc7s50-is25lp128f
```bash
./vivado-fpga-tool.sh flash --board=xc7s50-is25lp128f --file=BINFILE [--verify] [--vivado=PATH]
```

### dump - Read flash contents for board: xcau15p-is25wp128f
```bash
./vivado-fpga-tool.sh dump --board=xcau15p-is25wp128f --file=OUTFILE [--size=SIZE] [--vivado=PATH]
```

## Logs

Operation logs are saved to `/tmp/vivado-logs/` by default. Override with `--log=PATH` option.

## Exit Codes

- 0: Success
- 1: Invalid usage
- 2: Missing dependency
- 3: Configuration error
- 4: File I/O error
- 5: Hardware not found
- 6: TCL execution failed

## License

This tool is provided as-is for FPGA development and programming workflows.

