# Arduino ESP32 Firmware

ESP32 firmware for 6-color e-paper display with BLE image reception.

## Features

- **BLE Server**: Nordic UART service for image reception
- **E-Paper Display**: 800x480 6-color display driver
- **Power Management**: Deep sleep with periodic refresh (5-day cycle)
- **Touch Wake**: Wake from sleep on touch sensor activation
- **SPIFFS Storage**: Persistent image storage on flash
- **Battery Monitoring**: ADC-based battery percentage reporting

## Setup

1. Open `Spectra6.ino` in Arduino IDE
2. Install required libraries:
   - ArduinoBLE
   - SPIFFS (ESP32)
3. Configure board: ESP32 Dev Module
4. Upload firmware

## Hardware Configuration

- **Display**: 6-color e-paper 800x480 (SPI interface)
- **Touch Sensor**: Connected to GPIO for wake functionality
- **Battery**: Monitored via ADC pin
- **LED Indicators**: Status and activity indicators

## Key Files

- `Spectra6.ino` - Main firmware and setup
- `BLE.h/BLE.cpp` - Bluetooth communication handler
- `W21.h/W21.cpp` - E-paper display driver
- `SPICom.h/SPICom.cpp` - SPI communication interface
- `image.h` - Default image data

## Power Consumption

- **Active**: ~80mA during BLE transfer
- **Deep Sleep**: <1mA with periodic wake
- **Refresh Cycle**: Every 5 days or on touch wake