# CanvasBT — EPaper BLE Image Transfer System

An end-to-end, practical reference for sending images to a 6‑color e‑paper display over Bluetooth Low Energy (BLE). This repo combines:
- Flutter mobile app (select/process image, send over BLE)
- ESP32/Arduino firmware (receive, persist, and render to e‑paper)
- Python tools (desktop image conversion and BLE utilities)

## Educational Intent

This is a personal, non‑commercial project published publicly to help engineers and learners understand mobile ↔ BLE ↔ embedded firmware ↔ e‑paper display integration. It focuses on real constraints: BLE throughput, MTU/chunking, limited RAM, image quantization, and e‑paper refresh behavior.

## What You’ll Learn

- Designing a BLE data transfer flow from mobile to microcontroller
- Handling chunking, buffering, acknowledgments, and integrity checks
- Converting images to a 6‑color e‑paper format (quantization + optional dithering)
- Structuring firmware for display initialization, frame buffer handling, and refresh sequencing
- Organizing a multi‑component system repo for reproducibility

## System Overview

Flutter App → (BLE) → ESP32 Firmware → (SPI/GPIO) → 6‑Color E‑Paper Display

Typical workflow:
1. Choose an image in the Flutter app
2. Enhance and quantize to hardware palette (optionally dither)
3. Pack pixels and transfer over BLE in chunks
4. ESP32 reassembles the image payload and persists if needed
5. ESP32 renders to e‑paper and triggers a refresh

## Repository Structure

- [Flutter/](Flutter/) — Mobile app with all UI + BLE + image logic
	- Core files: [lib/main.dart](Flutter/lib/main.dart), [lib/ble_manager.dart](Flutter/lib/ble_manager.dart), [lib/image_processor.dart](Flutter/lib/image_processor.dart)
	- Platforms: [android/](Flutter/android/), [ios/](Flutter/ios/), [windows/](Flutter/windows/), [linux/](Flutter/linux/), [macos/](Flutter/macos/), [web/](Flutter/web/)
	- Assets/examples: [Framepic/](Framepic/), [SamplePics/](SamplePics/), [EmulatorScreenshots/](EmulatorScreenshots/)
- [Arduino/Spectra6/](Arduino/Spectra6/) — ESP32 firmware and display drivers
	- Key files: [Spectra6.ino](Arduino/Spectra6/Spectra6.ino), [BLE.cpp](Arduino/Spectra6/BLE.cpp), [SPICom.cpp](Arduino/Spectra6/SPICom.cpp), [W21.cpp](Arduino/Spectra6/W21.cpp)
	- Build artifacts (example boards): [build/esp32.esp32.dfrobot_firebeetle2_esp32e/](Arduino/Spectra6/build/esp32.esp32.dfrobot_firebeetle2_esp32e/)
- [Python/](Python/) — Desktop tools: [epd_image_tool.py](Python/epd_image_tool.py), [epd_image_tool_ble.py](Python/epd_image_tool_ble.py)
- Documentation: [USER_MANUAL.md](USER_MANUAL.md), project notes in [.github/copilot-instructions.md](.github/copilot-instructions.md)

## Hardware Requirements

- ESP32 development board (tested on FireBeetle2 ESP32‑E and similar)
- 6‑color e‑paper display, 800×480 (landscape)
- SPI wiring: MOSI, SCLK, CS; control pins: DC, RST, BUSY; power: VCC, GND
- Optional touch/wake input

Tip: Pin mapping varies by display/module; check the firmware for pin defines and adapt wiring accordingly.

### Wiring & Connections

SPI and control signals required:

- Data/Clock: MOSI, SCLK
- Select: CS
- Control: DC (data/command), RST (reset), BUSY (controller busy)
- Power: VCC, GND

Example pin mapping template (fill with your board pins):

| Signal | ESP32 Pin | Notes |
|--------|-----------|-------|
| MOSI   | GPIO XX   | SPI data out |
| SCLK   | GPIO XX   | SPI clock |
| CS     | GPIO XX   | Chip select |
| DC     | GPIO XX   | Data/Command select |
| RST    | GPIO XX   | Hardware reset |
| BUSY   | GPIO XX   | Display busy (input to ESP32) |
| VCC    | 3V3       | Stable 3.3V |
| GND    | GND       | Common ground |

ESD and power tips:
- Keep SPI lines short and tidy; use ground reference next to signal lines where possible.
- Ensure 3.3V supply is robust; brownouts cause BLE drops or partial refreshes.
- Use level‑compatible displays; do not drive 5V logic into the panel.

## Software Requirements

- Flutter SDK (stable), Android Studio or VS Code
- Android phone recommended for BLE testing
- Arduino IDE with ESP32 board support; ArduinoBLE library
- Python 3.9+ (virtual environment recommended)

## Getting Started

### Flutter App

```bash
cd Flutter
flutter pub get
flutter run
```

Notes:
- Requires a BLE‑capable Android device connected via USB (or emulator with suitable BLE proxies).
- The app scans for devices with “EPD” in the advertisement name.

Quick architecture diagram:

```
┌────────────┐      BLE      ┌──────────────┐    SPI/GPIO    ┌─────────────────┐
│  Flutter   │ ───────────▶  │   ESP32      │ ─────────────▶ │  E‑Paper Panel  │
│   (App)    │ ◀───────────  │  (Firmware)  │ ◀───────────── │  (6‑Color, 800×480)
└────────────┘  Status/ACK   └──────────────┘   Busy/Control └─────────────────┘
```

### Arduino Firmware (ESP32)

1. Open the firmware in Arduino IDE: [Arduino/Spectra6/Spectra6.ino](Arduino/Spectra6/Spectra6.ino)
2. Install and select your ESP32 board package.
3. Ensure required libraries (ArduinoBLE, SPI, FS/SPIFFS) are available.
4. Build and upload to your ESP32.

After flashing:
- The device advertises over BLE (e.g., name includes “EPD”).
- Battery percentage is sent on connection.
- Deep sleep is used for low power; touch wake is supported.

### Python Tools (Optional/Desktop)

```bash
cd Python
python epd_image_tool.py --help
python epd_image_tool_ble.py --help
```

Examples:

```bash
# Standalone image conversion
python epd_image_tool.py --input SamplePics/photo.jpg --output out.bin

# BLE transfer from desktop (development aid)
python epd_image_tool_ble.py --file out.bin
```

## Display + Image Processing

- Display resolution: 800×480
- Pixels packed at 2 pixels per byte (palette index nibble pairs)
- Optional 180° rotation supported for orientation

Hardware palette (critical for compatibility):

```dart
static const List<ColorMap> hwPalette = [
	ColorMap(0x00, Color.fromRGBO(0, 0, 0, 1)),       // Black
	ColorMap(0xFF, Color.fromRGBO(255, 255, 255, 1)), // White  
	ColorMap(0xFC, Color.fromRGBO(255, 255, 0, 1)),   // Yellow
	ColorMap(0xE0, Color.fromRGBO(210, 0, 0, 1)),     // Red
	ColorMap(0x03, Color.fromRGBO(0, 0, 180, 1)),     // Blue
	ColorMap(0x1C, Color.fromRGBO(0, 150, 0, 1)),     // Green
];
```

Pipeline: Load → Enhance (brightness/contrast/saturation) → Resize (fit/stretch) → Quantize to 6 colors (optional Floyd‑Steinberg) → Pack pixels → Optional rotation → BLE transfer.

### Image Packing Format

- Two pixels per byte: `hi_nibble = pixel0_index`, `lo_nibble = pixel1_index`.
- Palette index must match the hardware palette order shown above.
- Row ordering follows the chosen orientation; rotation is applied pre‑transfer when enabled.

## BLE Protocol

- Service: Nordic UART `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- Transfer types: `0x10` image, `0x20` OTA update
- Handshake: 4‑byte size header → ACK → chunked data
- Acknowledgments: `0x01` (size received), `0x02` (progress), `0x03` (complete), `0xFF` (error)
- Battery status: `0xB0` + percentage byte on connection
- Chunk size: 480 bytes (optimized for MTU and reliability)

Device discovery: the app scans for advertisements containing “EPD”.

### Packet/Handshake Details

Header exchange (image or OTA):
- Mobile sends 4‑byte size header (little‑endian length of payload) and transfer type byte (`0x10` image, `0x20` OTA).
- ESP32 replies with ACK `0x01` to confirm size reception.

Chunk transfer:
- Mobile streams payload in 480‑byte chunks.
- ESP32 issues periodic progress ACK `0x02` (implementation‑dependent cadence).
- On completion, ESP32 replies `0x03` or `0xFF` on error.

Battery status:
- On connection, ESP32 sends `0xB0` followed by a single percentage byte.

Recommended reliability notes:
- If MTU is smaller or unstable, reduce chunk size or increase ACK cadence.
- Consider adding sequence numbers and CRC in future (see Roadmap) for stronger integrity.

### Transfer Flow (ASCII)

```
App                                  ESP32
───                                  ────
Connect BLE  ───────────────────────▶ Advertise "EPD"
Receive 0xB0% ◀────────────────────── Battery status
Send header(size,type) ─────────────▶
					 ◀────────────── 0x01 (size ACK)
Send chunks (480B × N) ─────────────▶
					 ◀────────────── 0x02 (progress)
End of chunks ──────────────────────▶
					 ◀────────────── 0x03 (complete) or 0xFF (error)
```

OTA follows the same flow with type `0x20`, writing to firmware/image storage as defined in the ESP32 code.

## App Architecture & State

- Monolithic learning app with UI in [lib/main.dart](Flutter/lib/main.dart)
- BLE communication handled in [lib/ble_manager.dart](Flutter/lib/ble_manager.dart)
- Image processing in [lib/image_processor.dart](Flutter/lib/image_processor.dart)
- `setState()` used for state updates; BLE connection state tracked with timers
- Image library cached in memory and persisted via JSON/local storage
- Gestures: pan/zoom/rotate for precise framing

### UI/UX Flow Chart (Simplified)

```
[Launch]
	│
	├─▶ [Scan BLE] ─▶ [Select Device] ─▶ [Connect]
	│                                  │
	│                                  └─▶ [Battery %] overlay
	│
	├─▶ [Pick Image] ─▶ [Frame (pan/zoom/rotate)] ─▶ [Enhance]
	│                                                     │
	│                                                     └─▶ [Quantize + Pack]
	│                                                                     │
	└────────────────────────────────────────────────────────────────────▶ [Send]
																								  │
																								  └─▶ [Progress + Speed]
																											│
																											└─▶ [Complete → Refresh]
```

## Performance & Debugging

- High‑speed BLE: tuned chunk size (480 bytes) and batched ACKs
- Background isolates for image conversion to keep UI responsive
- Extensive console logging across Flutter and Arduino
- Real‑time transfer speed display during BLE operations
- Automatic reconnection attempts on disconnection

### Tips
- Enable verbose logs in both app and firmware to diagnose MTU and timing issues.
- Use a BLE scanner app to verify advertisement and connection parameters.
- When tuning throughput, adjust connection interval and preferred PHY (if supported by device).

## Troubleshooting

- If BLE MTU negotiation is limited, transfers fall back gracefully; reducing chunk size improves reliability.
- Ensure the ESP32 is powered adequately; weak power can cause BLE drops or SPI timing issues.
- For slow refresh: 6‑color e‑paper refresh is inherently slower; this is expected.
- On Android, grant Bluetooth, location, and storage permissions if prompted.

Common issues and remedies:
- Garbled image: verify palette index mapping and packing (2 pixels/byte).
- Partial frame update: ensure the firmware processes the full payload before refresh; check `BUSY` handling.
- Frequent BLE disconnects: check power supply, antenna orientation, and reduce chunk size.
- Very slow refresh: expected for multi‑color e‑paper; consider pre‑processing to reduce transitions.

## Roadmap (Optional)

- Add CRC/integrity verification and retry strategy
- Improve compression to reduce transfer time
- iOS testing and notes
- Wiring diagram, pin mapping table, and hardware photos
- docs/ARCHITECTURE.md with packet diagrams and flow

Additional ideas:
- Add ASCII timing diagrams for SPI transfers.
- Provide pin mapping examples per board (FireBeetle2, ESP32‑WROOM, etc.).
- Export PNG diagrams into a `docs/` folder for quick reference.

## Contributing

Contributions are welcome:
- Fork the repo
- Create a feature branch
- Open a pull request with a clear description

## Security

Do not commit credentials, tokens, or private keys. If you discover a security issue, please open an issue describing it at a high level.

## License

Recommended: MIT License (permissive). If you’d like to adopt it, add a `LICENSE` file at the repo root.

## Author

Abu Bakar — Embedded Systems Engineer (UK)
GitHub: https://github.com/abubakar1075

## See Also

- Mobile app source and docs: [Flutter/](Flutter/)
- Firmware and hardware integration: [Arduino/Spectra6/](Arduino/Spectra6/)
- Desktop tooling: [Python/](Python/)
- User guide: [USER_MANUAL.md](USER_MANUAL.md)
