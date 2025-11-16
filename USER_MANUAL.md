# CanvasBT User Manual
## 6-Color E-Paper Photo Frame

---

## Table of Contents
1. [Quick Start Guide](#quick-start-guide)
2. [Understanding Your Photo Frame](#understanding-your-photo-frame)
3. [Installing the Mobile App](#installing-the-mobile-app)
4. [Connecting to Your Frame](#connecting-to-your-frame)
5. [Sending Images](#sending-images)
6. [Image Library Management](#image-library-management)
7. [Frame Controls](#frame-controls)
8. [Image Adjustments](#image-adjustments)
9. [Battery & Charging](#battery--charging)
10. [Firmware Updates](#firmware-updates)
11. [Troubleshooting](#troubleshooting)
12. [Technical Specifications](#technical-specifications)

---

## Quick Start Guide

### First Time Setup (5 Minutes)

1. **Charge Your Frame**
   - Connect USB cable to the frame
   - Charge for at least 2 hours before first use
   - Green indicator shows charging status

2. **Install the App**
   - Install CanvasBT.apk on your Android phone
   - Grant Bluetooth and Storage permissions when prompted

3. **Wake Up the Frame**
   - Touch the sensor area on the frame
   - Frame wakes up and Bluetooth activates

4. **Connect & Send**
   - Open CanvasBT app
   - Tap "Scan" to find your frame
   - Tap "Connect" when you see "EPD-Display"
   - Select any image from your phone
   - Tap "Send to Frame"
   - Touch the frame sensor to display the image

**Done!** Your first image is now displayed on the frame.

---

## Understanding Your Photo Frame

### What Makes It Special

Your e-paper photo frame displays images using **6 vibrant colors**:
- **Black** - Deep and rich
- **White** - Crisp and clean
- **Red** - Bold and vivid
- **Yellow** - Bright and warm
- **Blue** - Cool and striking
- **Green** - Fresh and natural

### Power-Saving Technology

- **Ultra-Low Power**: Image stays visible for weeks without power
- **Deep Sleep Mode**: Frame sleeps when idle to save battery
- **Smart Wake-Up**: Touch sensor activates instantly
- **Long Battery Life**: Up to 5 days between charges with normal use

### Display Specifications

- **Resolution**: 800 × 480 pixels (landscape) / 480 × 800 pixels (portrait)
- **Refresh Time**: 10-15 seconds per image
- **Viewing Angle**: 170° (viewable from any angle)
- **No Backlight**: Easy on the eyes, readable in bright sunlight

---

## Installing the Mobile App

### Requirements

- Android phone (version 7.0 or higher)
- Bluetooth enabled
- 100 MB free storage space

### Installation Steps

1. **Install APK**
   - Transfer `app-release.apk` to your phone
   - Open the file
   - Tap "Install" (you may need to allow "Install from Unknown Sources")

2. **Grant Permissions**
   - **Bluetooth**: Required to connect to frame
   - **Location**: Required for Bluetooth scanning (Android requirement)
   - **Storage**: Required to access your photos
   - **Camera**: Optional, for taking new photos

3. **First Launch**
   - App opens with empty "Saved" library
   - One sample image is pre-loaded for testing
   - You're ready to connect!

---

## Connecting to Your Frame

### Bluetooth Connection

1. **Wake the Frame**
   - Touch the sensor area on the frame
   - Frame turns on Bluetooth (stays on for 60 seconds)

2. **Scan for Devices**
   - Open CanvasBT app
   - Tap "Scan" button at the top
   - Wait 5-10 seconds

3. **Connect**
   - Your frame appears as "EPD-Display"
   - Tap "Connect" next to the device name
   - Status shows "Ready to Send" when connected

### Connection Status Messages

| Message | Meaning |
|---------|---------|
| Ready to Send | Connected successfully, ready to transfer |
| Scanning... | Looking for nearby frames |
| Connecting... | Establishing connection |
| Battery: X% | Current battery level |
| Charger connected | USB power detected |
| Disconnected | Connection lost or ended |

### Staying Connected

- Connection lasts as long as you keep the app open
- Frame automatically disconnects after 5 minutes of inactivity
- To reconnect: Touch frame sensor and tap "Connect" in app

---

## Sending Images

### Quick Send (Fastest Method)

1. **Choose Your Image**
   - Tap "Gallery" to select from phone
   - Or tap "Camera" to take a new photo
   - Or tap "Saved" to use previously edited images

2. **Adjust Image (Optional)**
   - Use brightness/contrast/saturation sliders if needed
   - Switch between Portrait/Landscape orientation
   - Choose "Fit" or "Stretch" mode
   - Pinch to zoom, drag to reposition

3. **Send to Frame**
   - Tap "Send to Frame" button
   - Wait 15-20 seconds for transfer
   - Message shows "Transfer complete"

4. **Display on Frame**
   - Touch the frame sensor
   - Image appears in 10-15 seconds
   - Frame goes to sleep automatically

### Image Transfer Details

- **Transfer Speed**: ~20 KB/s (15-20 seconds for full image)
- **Connection Range**: Up to 10 meters (30 feet)
- **Auto-Retry**: App reconnects automatically if interrupted
- **Multiple Transfers**: Send as many images as you want

---

## Image Library Management

### Saved Images Library

The "Saved" section stores your prepared images ready to send instantly.

#### Saving Images

1. **From Gallery/Camera**
   - Select and adjust your image
   - Image is automatically added to "Saved"
   - No need to manually save

2. **Library Capacity**
   - Store unlimited images (limited by phone storage)
   - Each image is ~200 KB
   - Images are pre-processed for fast sending

#### Managing Your Library

1. **View Saved Images**
   - Tap "Saved" button
   - Scroll through your image collection
   - Tap any image to select it for sending

2. **Delete Images**
   - Long-press any image in "Saved"
   - Tap "Delete" to remove from library
   - This frees up phone storage

3. **Re-edit Images**
   - Select image from "Saved"
   - Adjust settings again if needed
   - Send updated version to frame

---

## Frame Controls

### Touch Sensor Operation

Your frame has a capacitive touch sensor for control.

#### Wake Up & Display Image

- **Single Touch**: Wakes frame and displays current image
- **Held for 2+ seconds**: Cycles to next stored image on frame
- **While charging**: Touch still works normally

#### Stored Images on Frame

The frame stores up to **3 images** internally:
- **Slot 1**: Most recent image sent
- **Slot 2**: Second most recent
- **Slot 3**: Third most recent

**To cycle through stored images:**
1. Touch and hold sensor for 2 seconds
2. Release when you feel vibration (if enabled)
3. Image changes to next slot
4. Repeat to cycle through all 3 images

### Frame States

| State | What's Happening |
|-------|------------------|
| Sleeping | Display visible, no power used |
| Waking | Touch detected, Bluetooth starting |
| Connected | App connected, ready to receive |
| Receiving | Transferring image data |
| Refreshing | Updating display (10-15 seconds) |
| Back to Sleep | Display updated, entering sleep mode |

---

## Image Adjustments

### Orientation Modes

#### Landscape Mode (800 × 480)
- **Best for**: Wide photos, landscapes, group photos
- **Frame position**: Horizontal
- **Default mode**: Frame designed for landscape

#### Portrait Mode (480 × 800)
- **Best for**: Selfies, portraits, tall images
- **Frame position**: Vertical
- **Toggle**: Tap portrait/landscape icon in app

### Fit vs Stretch Modes

#### Fit Mode (Recommended)
- **What it does**: Fits entire image within frame with black borders
- **Preserves**: Original aspect ratio (no distortion)
- **Best for**: Photos you don't want to crop

#### Stretch Mode
- **What it does**: Fills entire frame, may crop edges
- **Behavior**: Stretches or crops to fill completely
- **Best for**: Backgrounds, patterns, abstract images

### Image Enhancement Controls

#### Brightness
- **Range**: -100 to +100
- **Use for**: Dark or overexposed photos
- **Tip**: Increase for photos taken indoors

#### Contrast
- **Range**: -100 to +100
- **Use for**: Flat or washed-out images
- **Tip**: Increase to make colors pop

#### Saturation
- **Range**: -100 to +100
- **Use for**: Dull or oversaturated colors
- **Tip**: Decrease for subtle, muted tones

### Pan, Zoom, and Rotate

1. **Zoom In/Out**
   - Pinch gesture on image preview
   - Zoom in to see details
   - Zoom out to see full image

2. **Pan/Reposition**
   - Drag image with one finger
   - Reposition after zooming
   - Center your subject perfectly

3. **Rotate**
   - Tap rotation button for precise 90° turns
   - Or use two-finger rotation gesture
   - Align horizon or adjust orientation

---

## Battery & Charging

### Battery Information

#### Battery Status Display

The app shows battery level at these times:
- When first connected to frame
- When charger is plugged in
- When charger is unplugged

**Battery Messages:**
- "Battery: 85%" - Current charge level
- "Charger connected" - USB power detected

#### Battery Life Expectations

| Usage Pattern | Battery Life |
|---------------|--------------|
| Image displayed (sleeping) | 30+ days |
| Daily image change | 5-7 days |
| Multiple daily changes | 2-3 days |
| Constant Bluetooth use | 8-10 hours |

### Charging Instructions

1. **Connect Charger**
   - Use included USB cable
   - Plug into 5V USB charger (phone charger works)
   - Charging indicator lights up

2. **Charging Time**
   - Empty to full: 3-4 hours
   - Partial charge: 1-2 hours
   - Can use frame while charging

3. **Charging Status**
   - App shows "Charger connected" when detected
   - Frame remains functional during charging
   - Unplug when battery reaches 100%

### Power-Saving Tips

- Let frame sleep between uses (automatic)
- Disconnect Bluetooth when not sending images
- Avoid excessive image changes (display refresh uses power)
- Keep frame at room temperature
- Update images once per day for longest battery life

---

## Firmware Updates

### Why Update Firmware?

- Bug fixes and stability improvements
- New features and enhancements
- Better battery performance
- Improved image quality

### Update Process

1. **Prepare Update File**
   - Receive `firmware.bin` file from manufacturer
   - Place file in `OTAFile` folder in app directory
   - File size typically 1-2 MB

2. **Connect to Frame**
   - Touch frame sensor to wake
   - Connect via app
   - Ensure battery is above 50%

3. **Send Update**
   - Tap "OTA Update" in app menu
   - Select firmware file
   - Tap "Send Update"

4. **Wait for Installation**
   - Transfer takes 30-60 seconds
   - Frame installs automatically
   - Frame restarts (60 seconds)
   - Update complete!

### Update Status Messages

| Message | Meaning |
|---------|---------|
| Update file selected | Ready to send |
| Transferring... | Sending firmware to frame |
| Transfer complete | Frame installing update |
| (Frame restarts) | Installation successful |

### Important Update Notes

- **Do not interrupt**: Keep app open during transfer
- **Stay in range**: Keep phone near frame
- **Keep charged**: Battery must be >50%
- **Previous images preserved**: Your 3 stored images remain intact
- **Settings preserved**: Touch calibration and preferences saved

---

## Troubleshooting

### Connection Issues

#### Problem: Can't find frame when scanning

**Solutions:**
1. Touch frame sensor to ensure Bluetooth is active
2. Move phone closer to frame (within 1 meter)
3. Ensure no other device is connected to frame
4. Restart Bluetooth on phone
5. Close and reopen app

#### Problem: Connection drops during transfer

**Solutions:**
1. Keep phone and frame within 5 meters
2. Avoid obstacles between phone and frame
3. Close other Bluetooth apps on phone
4. Ensure frame battery isn't critically low
5. Retry transfer - app auto-resumes where it left off

### Image Display Issues

#### Problem: Image looks wrong or distorted

**Solutions:**
1. Check orientation setting (Portrait vs Landscape)
2. Try "Fit" mode instead of "Stretch"
3. Adjust brightness/contrast in app
4. Use high-quality source images (not heavily compressed)
5. Avoid images with fine text or tiny details

#### Problem: Colors don't look right

**Solutions:**
1. Frame uses 6 specific colors - your image is converted
2. Increase saturation for more vivid colors
3. Adjust contrast to make colors distinct
4. Some colors (like orange, purple) convert to nearest match
5. This is normal for e-paper technology

#### Problem: Image doesn't update on frame

**Solutions:**
1. Touch frame sensor after transfer completes
2. Wait 15 seconds for display refresh
3. Ensure transfer showed "Complete" message
4. Try sending image again
5. Charge frame if battery is low

### Touch Sensor Issues

#### Problem: Frame doesn't wake when touched

**Solutions:**
1. Press sensor area firmly (2-second hold)
2. Clean sensor area with soft cloth
3. Ensure battery isn't depleted
4. Sensor may need calibration (see below)

#### Problem: Touch too sensitive or not sensitive enough

**Calibrate Touch Sensor:**
1. Connect to frame via app
2. Tap "Calibrate Touch" in menu
3. Follow on-screen instructions
4. Touch sensor when prompted
5. Calibration saved automatically

### General Issues

#### Problem: Battery drains quickly

**Solutions:**
1. Let frame sleep between uses
2. Reduce number of daily image changes
3. Disconnect Bluetooth when not needed
4. Ensure firmware is up to date
5. Replace battery if frame is >1 year old

#### Problem: Transfer is very slow

**Solutions:**
1. Move phone closer to frame
2. Ensure phone Bluetooth is not busy with other devices
3. Close background apps on phone
4. Restart both phone and frame
5. Check for phone system updates

---

## Technical Specifications

### Frame Hardware

| Specification | Details |
|---------------|---------|
| Display Type | 6-color e-paper (ACeP technology) |
| Resolution | 800 × 480 pixels (landscape) |
| Display Size | 5.83 inches diagonal |
| Colors | Black, White, Red, Yellow, Blue, Green |
| Viewing Angle | 170° |
| Refresh Rate | ~15 seconds per update |
| Power Source | Rechargeable Li-ion battery (2000 mAh) |
| Charging | 5V USB Type-C |
| Wireless | Bluetooth 5.0 LE |
| Storage | 3 images (internal flash memory) |
| Processor | ESP32 dual-core @ 240 MHz |
| Touch Sensor | Capacitive touch (calibrated) |
| Dimensions | 150 × 95 × 12 mm |
| Weight | 120 grams |

### Mobile App

| Specification | Details |
|---------------|---------|
| Platform | Android 7.0+ |
| Bluetooth | BLE 4.0 or higher |
| Storage Required | ~100 MB |
| Image Formats | PNG, JPG, JPEG, WEBP |
| Max Image Size | 20 MB (source file) |
| Library Capacity | Unlimited (phone storage limited) |
| Transfer Speed | ~20 KB/s |
| Range | Up to 10 meters |

### Color Specifications

| Color | RGB Values | Hardware Code |
|-------|------------|---------------|
| Black | (0, 0, 0) | 0x00 |
| White | (255, 255, 255) | 0xFF |
| Red | (210, 0, 0) | 0xE0 |
| Yellow | (255, 255, 0) | 0xFC |
| Blue | (0, 0, 180) | 0x03 |
| Green | (0, 150, 0) | 0x1C |

### Environmental Conditions

| Parameter | Range |
|-----------|-------|
| Operating Temperature | 0°C to 40°C |
| Storage Temperature | -10°C to 50°C |
| Humidity | 20% to 80% (non-condensing) |
| Altitude | 0 to 3000 meters |

---

## Safety Information

### Important Safety Guidelines

⚠️ **Do Not:**
- Expose frame to water or moisture
- Disassemble the device
- Use damaged charging cables
- Expose to extreme temperatures
- Drop or impact the frame
- Use near strong magnets

✓ **Do:**
- Use only approved USB chargers
- Keep away from heat sources
- Clean with soft, dry cloth only
- Store in cool, dry place
- Handle display surface carefully
- Keep away from direct sunlight (for charging)

### Battery Safety

- Lithium-ion battery inside - do not puncture
- Dispose according to local e-waste regulations
- If battery swells, stop using immediately
- Charge in well-ventilated area
- Unplug when fully charged

---

## Warranty & Support

### Warranty Coverage

- **Duration**: 1 year from purchase date
- **Covers**: Manufacturing defects, hardware failures
- **Does not cover**: Physical damage, water damage, battery wear

### Contact Support

For technical support, warranty claims, or questions:
- **Email**: support@canvasbt.com
- **Website**: www.canvasbt.com/support
- **Response Time**: Within 24-48 hours

### Firmware Updates

Check for latest firmware updates at:
**www.canvasbt.com/downloads**

---

## Tips for Best Results

### Photography Tips

1. **Use high-quality images** - At least 1920 × 1080 resolution
2. **Good lighting** - Well-lit photos display better
3. **High contrast** - Bold subjects work best
4. **Avoid gradients** - 6 colors means gradients become banded
5. **Simple compositions** - Less busy images look clearer

### App Usage Tips

1. **Save your favorites** - Build a library of ready-to-send images
2. **Adjust before sending** - Preview looks exactly like frame output
3. **Stay connected** - Keep app open during transfer
4. **Test settings** - Try different brightness/contrast for each image
5. **Landscape works best** - Frame designed for horizontal orientation

### Frame Maintenance

1. **Clean regularly** - Wipe display with microfiber cloth
2. **Charge monthly** - Even if not used, charge once per month
3. **Update firmware** - Install updates when available
4. **Calibrate annually** - Re-calibrate touch sensor yearly
5. **Proper storage** - Store powered off in cool, dry place

---

## Frequently Asked Questions

**Q: How long does the image stay visible without power?**  
A: Indefinitely. E-paper holds the image without any power consumption.

**Q: Can I use photos with more than 6 colors?**  
A: Yes! The app automatically converts any photo to the 6-color palette.

**Q: How many images can the frame store?**  
A: 3 images internally. Cycle through them by long-pressing the sensor.

**Q: Does it work with iPhone?**  
A: Currently Android only. iOS version planned for future release.

**Q: Can I display the frame vertically (portrait)?**  
A: Yes, just select portrait mode in the app before sending.

**Q: What happens if transfer is interrupted?**  
A: The app will resume from where it stopped. Just reconnect and continue.

**Q: Can I print photos with this?**  
A: No, this is a digital display only. Images are shown electronically.

**Q: How do I change the displayed image?**  
A: Send a new image from the app, then touch the frame sensor to display it.

**Q: Can multiple phones connect to one frame?**  
A: Not simultaneously, but any phone with the app can connect one at a time.

**Q: What's the typical battery life?**  
A: 5-7 days with daily image changes, or 30+ days displaying one static image.

---

## Quick Reference Card

### Most Common Actions

| To Do This | Steps |
|------------|-------|
| Display new image | 1. Connect → 2. Select image → 3. Send → 4. Touch frame |
| Change orientation | Tap portrait/landscape icon in app |
| Cycle stored images | Long-press frame sensor for 2 seconds |
| Check battery | Connect to frame, status shows automatically |
| Charge frame | Plug in USB cable, wait 3-4 hours |
| Wake frame | Touch sensor area briefly |
| Update firmware | Connect → OTA Update → Select file → Send |
| Save to library | Select from Gallery/Camera (auto-saves) |
| Delete from library | Long-press image in Saved → Delete |
| Adjust brightness | Use brightness slider before sending |

---

**Thank you for choosing CanvasBT E-Paper Photo Frame!**

Enjoy displaying your favorite memories in vivid 6-color detail.

*User Manual Version 1.0 - November 2025*
