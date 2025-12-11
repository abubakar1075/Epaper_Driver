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

- Open the app menu or the AI view and tap `Report AI Content` / `Report Image`.
- Select issue type: Offensive • Sexual • Violent • Misleading • Other.
- Describe the problem and optionally include a screenshot (auto-attached for AI images).
- Submits directly in-app via HTTPS; no leaving the app.

### Configure report endpoint (Google Apps Script recommended)

- The app posts `application/x-www-form-urlencoded` to your Web App URL (`/exec`).
- Fields sent:
	- `issueType`, `description`, `app`, `platform`, optional `screenshotBase64` (PNG/JPEG base64)
- Configure the endpoint at build time using `--dart-define` (preferred):

```powershell
flutter run --dart-define=REPORT_ENDPOINT=https://script.google.com/macros/s/XXXX/exec
```

- Alternatively, set the default in `lib/main.dart` (`_REPORT_ENDPOINT_DEFAULT`).

### Apps Script quick-start (summary)

- Create a Google Apps Script > Deploy > Web app > Anyone.
- Implement `doPost(e)` to append to a Sheet and save `screenshotBase64` to Drive (optional) and return JSON.
- Ensure the Web App URL ends with `/exec` and accepts form-encoded data via `e.parameter`.

### Disclosure and safety

- AI-generated images are labeled in-app and include a built-in Report button.
- Basic on-device filtering blocks obviously unsafe prompts before generation.
- Reports contain only what you submit plus app name and platform; used for moderation only.

## Key Files

- `lib/main.dart` - Main UI and application logic (monolithic design)
- `lib/ble_manager.dart` - Bluetooth communication handler
- `lib/image_processor.dart` - Image conversion and processing
- `pubspec.yaml` - Dependencies and asset configuration

## Asset Directories

- `FramePics/` - Sample images for testing
- `OTAFile/` - Firmware files for OTA updates
- `Logo/` - App icons and branding assets