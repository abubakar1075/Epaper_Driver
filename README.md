# CanvasBT - EPaper BLE Image Transfer System

A complete system for sending images to Arduino-powered 6-color e-paper displays (800x480) via Bluetooth Low Energy. This repository contains three integrated components: a Flutter mobile app, Arduino firmware, and Python desktop tools.

## Project Structure

```
CanvasBT/
├── Flutter/          # Mobile app for Android/iOS
├── Arduino/          # ESP32 firmware for e-paper display
├── Python/           # Desktop image processing tools  
└── .github/          # Documentation and CI
```

## Components Overview

### Flutter Mobile App (`Flutter/`)
- Image selection from gallery with pan/zoom/rotate gestures
- Real-time image processing with 6-color palette conversion
- BLE device scanning and high-speed image transfer
- Image library with persistent storage
- OTA firmware update capability

### Arduino Firmware (`Arduino/Spectra6/`)
- ESP32-based BLE receiver for 800x480 6-color e-paper display
- SPIFFS image storage with periodic refresh (5-day cycle)
- Deep sleep power management with touch wake
- Battery monitoring and status reporting

### Python Tools (`Python/`)
- Desktop image conversion utilities
- BLE transfer tools for development/testing
- Support for all Pillow-compatible image formats

## Quick Start

### Flutter Mobile App
```bash
cd Flutter
flutter pub get
flutter run  # Requires Android device with BLE
```

### Arduino Setup
1. Open `Arduino/Spectra6/Spectra6.ino` in Arduino IDE
2. Install ArduinoBLE library
3. Upload to ESP32 board

### Python Tools
```bash
cd Python
pip install pillow bleak
python epd_image_tool_ble.py
```

## Key Features

### 6-Color E-Paper Display Support
- Hardware-specific color palette (Black, White, Yellow, Red, Blue, Green)
- Optimized image quantization with Floyd-Steinberg dithering
- 800x480 resolution with 2 pixels per byte packing

### High-Speed BLE Transfer
- Nordic UART service protocol
- 480-512 byte chunk sizes for optimal throughput
- Progress tracking with real-time speed monitoring
- Automatic reconnection and error recovery

### Advanced Image Processing
- Pan/zoom/rotate gestures for precise framing
- Brightness, contrast, saturation adjustments
- Fit (letterbox) vs Stretch resize modes
- 180° rotation option for display orientation

### Power Management
- Arduino deep sleep with 5-day refresh cycles
- Touch wake capability
- Battery percentage monitoring and reporting

## Hardware Requirements

- **Mobile Device**: Android with BLE support (API 21+)
- **Arduino**: ESP32 board with BLE capability
- **Display**: 6-color e-paper display (800x480)
- **Optional**: Touch sensor for wake functionality

## Development

Each component can be developed independently:

- **Flutter**: Standard Flutter development workflow
- **Arduino**: Arduino IDE with ArduinoBLE library
- **Python**: Python 3.6+ with Pillow and Bleak libraries

See individual folder README files for detailed setup instructions.
