# iPhone 5c iOS 6 Tool

A DEMO for running **iOS 6.1.3 / 6.1.4 on the iPhone 5c**. It takes an original iPhone 5 IPSW, applies the port patches, builds a restore image, and handles flashing and tethered boot.

Hacktivation and jailbreak (Cydia / Substrate) are enabled by default. You can turn them off when building the firmware.

**A computer is required to boot after every restart or power-off.** Enter DFU and use this tool to boot again. Flashing erases your data, so back up first. Baseband flashing is currently disabled.

## Supported devices and hardware

- **iPhone5,3 / N48**: firmware generation is supported; **not tested on hardware yet**.
- **iPhone5,4 / N49**: partially tested on hardware, as listed below.

| Feature | Status on N49 |
| --- | --- |
| Display and touch | Tested and working |
| Manual / automatic screen sleep and wake | Tested and working |
| USB | Communication tested in both the system and restore environment |
| Wi-Fi | Networking worked in a development build; the latest combined firmware still needs retesting |
| Bluetooth | Other devices can discover and connect to it; no Bluetooth accessories available to test other features |
| Speaker | Playback tested |
| Microphone | Captured nonzero audio and responses to test tones; speech and individual microphones still need testing |
| Earpiece | Playback routing tested; audible output still needs confirmation |
| Baseband / SIM | Not yet fully working in testing. Not enabled by default; the status bar shows “Searching…” |
| GPS | Not enabled by default. Optional patch can track satellites and output NMEA; no valid position fix yet |
| Cameras, flash and sensors | Compatibility patches included; individual features still need testing |

These results come from development testing, including separate patches and RAM boots. The latest combined firmware has not been fully tested. N48 hardware behavior is still unknown.

Other hardware features and potential bugs have not been fully tested. Feedback and bug reports are welcome!

## Requirements

- Linux x86_64 / arm64 or macOS Intel / Apple Silicon (macOS untested).
- Bash 3.2+, Python 3.10+ (3.12+ to build host tools). Linux x86_64 bundled tools need glibc 2.38+.
- USB data cable, internet access and several GB of free space.
- macOS: Homebrew and Command Line Tools. Other missing dependencies are installed automatically.

## Usage

Download the whole tool directory and run inside it:

```sh
chmod +x tool.sh
./tool.sh
```

1. Connect one iPhone 5c in DFU, or unlock it and trust the computer.
2. Follow the menu to choose an iOS version and build options. Let the tool download the source IPSW, or select an original **iPhone 5 (iPhone5,1 / iPhone5,2) iOS 6.1.3 / 6.1.4 IPSW**.
3. Build the firmware, then choose flash and type `ERASE`. Enter DFU when prompted.
4. After flashing, **manually enter DFU again** and select **Tethered boot**.

Keep the tool and its `runtime/` directory for future boots. After every restart, enter DFU and use **Tethered boot** again.

Common commands:

```sh
# Download and build firmware
./tool.sh prepare --version 6.1.3 --download

# Or build from a local original IPSW
./tool.sh prepare --version 6.1.4 --source-ipsw '/path/to/source.ipsw'

# Flash prepared firmware (use the same version and build options; erases data)
./tool.sh flash --version 6.1.3 --execute --erase

# Boot after entering DFU
./tool.sh boot --execute

# Show all options
./tool.sh --help
```

Without `--execute`, `flash` and `boot` only show a preview.

## Credits

- [Legacy iOS Kit / LukeZGD](https://github.com/LukeZGD/Legacy-iOS-Kit)
- [a6meowing](https://github.com/LukeZGD/a6meowing), [gaster](https://github.com/LukeZGD/gaster), [iBoot32Patcher](https://github.com/LukeZGD/iBoot32Patcher)
- [libimobiledevice](https://github.com/libimobiledevice), [libirecovery](https://github.com/libimobiledevice/libirecovery), [idevicerestore](https://github.com/libimobiledevice/idevicerestore)
- [xpwn](https://github.com/xerub/xpwn), [daibutsuCFW](https://github.com/LukeZGD/daibutsuCFW)
- Everyone who helped with hardware testing and feedback
