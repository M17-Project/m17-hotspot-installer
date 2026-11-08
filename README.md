# M17 CC1200/SX1255/MMDVM Hotspot Installation Script

This repository contains a Bash script to convert a Raspberry Pi (with a CC1200, SX1255 or MMDVM hat) into a fully functional **M17 digital voice hotspot**. The script automates the entire installation and setup process, including configuring UART, installing the gateway, setting up the web dashboard, and updating the HAT's firmware (optional).

## Install Script Usage

Execute the following on the Raspberry Pi to download the installer:

```
wget https://raw.githubusercontent.com/M17-Project/m17-hotspot-installer/refs/heads/main/m17-hotspot-installer.sh
```

Carefully read the script before you execute it with:

```
chmod u+x m17-hotspot-installer.sh
sudo ./m17-hotspot-installer.sh
```

Options:

- `-n` don't flash the HAT firmware
- `-f` offer to flash the HAT firmware even if it is up to date
- `-u` don't check for a newer version of the installer

At every prompt, pressing Enter picks the default, shown in capitals: `(Y/n)` means yes, `(y/N)` means no.

## Features

- Verifies root and OS requirements (Bookworm or Trixie, 64-bit)
- Intended for a **fresh install** of Raspberry Pi OS Lite (64-bit), Bookworm or Trixie
- Configures UART for GPIO access
- Prompts for required reboots after system update and boot option changes
- Installs all necessary packages via APT
- Creates a dedicated _m17_ user for running services
- Clones the following M17 Project repositories:
  - [MMDVM](https://github.com/M17-Project/MMDVM) and [MMDVM_HS](https://github.com/M17-Project/MMDVM_HS) (prebuilt MMDVM firmware)
  - [rpi-dashboard](https://github.com/M17-Project/rpi-dashboard) (web interface)
- Downloads the latest [CC1200_HAT-fw](https://github.com/M17-Project/CC1200_HAT-fw/releases) release for CC1200 HATs
- Installs [m17-gateway](https://github.com/jancona/m17)
- Configures NGINX and PHP-FPM to serve the dashboard
- Allows the dashboard to reboot and shut down the Raspberry Pi (Settings page, Device control)
- Identifies a CC1200 or MMDVM HAT and suggests its type
- Reads the HAT's firmware version and offers an update via stm32flash only when a newer one is available (see `-f` and `-n` above). MMDVM_HS_Hat and MMDVM_HS_Dual_Hat boards get the right firmware file automatically; for other MMDVM boards, you choose it from a list
- Script may be re-run to update software to the latest version
- Checks for a newer version of itself on each run and offers to use it

## Tested Hardware and OS

This script was tested on:

- **Raspberry Pi Zero 2 W**
- **Raspberry Pi OS Lite (64-bit), Bookworm (Debian 12-based) and Trixie (Debian 13-based)**

Other Pi models or OS versions may work but are **not officially supported**.

## Prerequisites

- Fresh install of Raspberry Pi OS Bookworm or Trixie **Lite (64-bit)**
- Raspberry Pi with internet access
- CC1200, SX1255 or MMDVM HAT connected
- Run the script as **root**

## File Summary

- `/opt/m17/` - Main working directory for M17-related repositories
- `/opt/m17/rpi-dashboard/` - Web interface root (served by NGINX)
- `/opt/m17/m17-gateway/` - m17-gateway installation root
- `/etc/m17-gateway.ini` - Gateway configuration file
- `/boot/firmware/config.txt` - UART settings applied here

## Hotspot Usage

This script builds an M17 hotspot which consists of two software components:

- [m17-gateway](https://github.com/jancona/m17)
- [rpi-dashboard](https://github.com/M17-Project/rpi-dashboard)

Please read the manual of both software packages.

To start _m17-gateway_ manually, just execute the following line:

```
sudo systemctl start m17-gateway.service
```

This service will connect you to the M17 reflector of your choice. Its log can be followed with `journalctl -u m17-gateway -f`.

To access the dashboard, simply navigate your browser to _http://<IP_OF_YOUR_RPI>_.

The installer sets *Modem / Type* to match the HAT you select. If you change the HAT later, update *Type* on the Gateway page (`cc1200`, `sx1255` or `mmdvm`) or re-run the installer, which suggests the HAT it finds. With an SX1255 or MMDVM HAT, also check the settings below.

### SX1255 Configuration

The following fields on the Gateway page may have to be changed for the SX1255:

* Under *Radio*:
  * For duplex operation, *Duplex* must be set to `true`.
  * To run in Duplex mode, the *RXFrequency* and *TXFrequency* must be different.
* Under *Modem*:
  * *ALSACaptureDevice* and *ALSAPlaybackDevice* can normally stay blank: m17-gateway then finds the SX1255's sound card itself. To choose a device, pick it from the list on the Gateway page.

For SX1255 HATs, the installer turns off HDMI audio, so that m17-gateway cannot pick the HDMI output for transmitting.

### MMDVM Configuration

The following fields on the Gateway page may have to be changed for MMDVM:

* Under *Radio*:
  * To run a Duplex HAT in duplex mode, *Duplex* must be set to `true`.
  * To run in Duplex mode, the *RXFrequency* and *TXFrequency* must be different.
* Under *Modem*:
  * *Speed* (the serial port's baud rate) may need to be changed to the value the HAT supports, often `115200` for hotspots.

## Disclaimer

This script makes **system-wide changes** and should **only be run on a clean install**. Do **not** use on a production system or one with existing services unless you know what you're doing.

## Support

For questions or issues, please contact [M17 Project](https://m17project.org/) or open a GitHub issue in the relevant repository.

## License

This script is provided as-is, under the GPL License. Contributions welcome.
