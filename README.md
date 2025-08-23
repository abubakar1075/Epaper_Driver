# EPaper Image Sender App

This Flutter application allows you to send images to an Arduino-powered 6-color ePaper display over Bluetooth Low Energy (BLE). It replaces the functionality of the Python application with a mobile app that can be used on Android devices.

## Features

- Image selection from gallery
- Image processing with adjustable settings:
  - Fit/Stretch modes for resizing
  - Dithering toggle for better color representation
  - Brightness, contrast, and saturation adjustments
  - 180° rotation option
- BLE device scanning and connection
- Image transfer with progress tracking
- Real-time transfer speed display

## Requirements

- Flutter SDK
- Android device with BLE support (minimum API level 21)
- Arduino device running the provided Spectra6 firmware

## Getting Started

1. Clone this repository
2. Run `flutter pub get` to install dependencies
3. Connect your Android device
4. Run `flutter run` to start the application

## How to Use

1. **Select an Image**: Tap the "Select Image" button to choose an image from your gallery.
2. **Adjust Image Settings**: Modify the processing settings as needed:
   - Choose between Fit (letterbox) or Stretch resize modes
   - Toggle dithering on/off
   - Adjust brightness, contrast, and saturation
   - Enable/disable 180° rotation
3. **Scan for BLE Devices**: Tap "Scan for BLE Devices" to find nearby Arduino devices
4. **Connect to Device**: Tap on your Arduino device in the list to connect
5. **Send Image**: Once connected, tap "Send Image to Device" to transfer the image

## Permissions

The app requires the following permissions:
- Bluetooth (scan, connect, advertise)
- Location (required for BLE scanning on Android)
- Storage (for image access)

## Arduino Compatibility

This app is designed to work with the Arduino Spectra6 firmware that drives a 6-color ePaper display. The Arduino code should be flashed to an ESP32 board connected to the ePaper display.

## Technical Details

- Image processing uses the 6-color palette supported by the ePaper display
- Image data is packed to reduce transfer size (2 pixels per byte)
- BLE transfer uses a chunk size of 512 bytes for optimal performance
- Progress updates and acknowledgments are sent from the Arduino device

## Troubleshooting

- If the app can't find your Arduino device, make sure Bluetooth is enabled and the device is powered on
- If the connection fails, try restarting the Arduino device
- If the image doesn't display correctly, try adjusting the processing settings or using a different image
