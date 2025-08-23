# EPD Image Tool with BLE

This project consists of two parts:
1. A Python application (`epd_image_tool_ble.py`) that converts images to the e-paper display format and sends them via Bluetooth Low Energy (BLE)
2. An Arduino sketch (`GDEP073E01.ino`) that receives image data via BLE and displays it on an e-paper display

## Python Application

### Requirements
- Python 3.6 or higher
- Pillow: `pip install Pillow`
- Bleak (for BLE): `pip install bleak`

### Features
- Convert any image to the 6-color EPD format (800x480)
- Scan for BLE devices
- Connect to the Arduino BLE device
- Send image data to Arduino
- Options for image fitting and dithering

### Usage
1. Run the application: `python epd_image_tool_ble.py`
2. Open an image file
3. Adjust image settings (fit mode, dithering) if desired
4. Click "Scan for BLE Devices"
5. Select your Arduino device from the list and click "Connect"
6. Once connected, click "Send Image Data to Device"

## Arduino Implementation

### Requirements
- Arduino board with BLE capabilities (e.g., Arduino Nano 33 BLE, ESP32)
- ArduinoBLE library: Install via Arduino Library Manager

### Features
- Advertises as "EPD-Display" via BLE
- Receives image data from the Python application
- Displays received data on the e-paper display
- Prints all received data to the Serial Monitor (byte by byte)
- Continues to run the demo when not connected via BLE

### Installation
1. Install the ArduinoBLE library via the Arduino Library Manager
2. Upload the `GDEP073E01.ino` sketch to your Arduino board
3. Open the Serial Monitor at 115200 baud to see debug information and received data

## How it Works

1. The Python application converts an image to the 6-color EPD format
2. When sending data, it first sends the total data size (4 bytes)
3. Then it sends the image data in chunks of 512 bytes
4. The Arduino receives the data, displays progress on Serial Monitor
5. When all data is received, Arduino displays it on the e-paper display and prints all bytes to Serial Monitor
6. When not connected via BLE, the Arduino runs a demo displaying sample images and color patterns

## Troubleshooting

- Make sure Bluetooth is enabled on your computer
- Arduino board must support BLE
- The Serial Monitor in Arduino IDE shows connection status and received data
- Check that the BLE UUIDs match between Python and Arduino code
- Data transfer may take some time due to the large image size (800x480 = 384,000 bytes)
