# Flutter Mobile App

Flutter application for sending images to 6-color e-paper displays via BLE.

## Features

- **Image Selection**: Choose images from gallery with pan/zoom/rotate gestures
- **Real-time Processing**: Convert images to 6-color palette with dithering options
- **BLE Communication**: High-speed transfer with progress tracking
- **Image Library**: Persistent storage of processed images
- **OTA Updates**: Firmware update capability for Arduino devices
- **AI Content Reporting**: In-app flagging of offensive/misleading AI-generated content

## Setup

```bash
flutter pub get
flutter run
```

## Requirements

- Flutter SDK 3.9+
- Android device with BLE support (API 21+)
- Permissions: Bluetooth, Location, Storage

## AI-Generated Content Reporting

- Open the app menu and tap `Report AI Content`.
- Select issue type: Offensive • Sexual • Violent • Misleading • Other.
- Describe the problem and optionally attach a screenshot.
- Submit directly in-app. Reports are sent via a configurable HTTPS endpoint.

### Configure report endpoint

- Set `REPORT_ENDPOINT` in `lib/main.dart` to your HTTPS URL that accepts `multipart/form-data`:
	- Fields: `issueType`, `description`, `app`, `platform`
	- File: `screenshot` (optional)
- If unset, the app falls back to opening the email composer addressed to `support@inventorstech.io`.

## Key Files

- `lib/main.dart` - Main UI and application logic (monolithic design)
- `lib/ble_manager.dart` - Bluetooth communication handler
- `lib/image_processor.dart` - Image conversion and processing
- `pubspec.yaml` - Dependencies and asset configuration

## Asset Directories

- `FramePics/` - Sample images for testing
- `OTAFile/` - Firmware files for OTA updates
- `Logo/` - App icons and branding assets