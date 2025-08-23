# EPD Image Conversion Tool

A Python GUI utility to convert arbitrary images into an 800x480, 256-color (8bpp) byte array for the GDEP073E01 Arduino sketch (`gImage_1`).

## Features
- Open any Pillow-supported image (PNG, JPG, BMP, etc.)
- Resize to 800x480 via either:
  - Fit (letterbox / pillarbox with white padding)
  - Stretch (exact scale)
- Fixed 256-color RGB332 palette for deterministic output (index = (R<<5)|(G<<2)|B)
- Optional Floyd–Steinberg dithering (default on) to reduce banding
- Preview original and converted image side by side
- Export C header (`const unsigned char gImage_1[384000] = {...};`)
- Copy array directly to clipboard

> NOTE: Your existing `image.h` seems to use a *reduced* hardware palette (values like `0x00, 0x03, 0x1C, 0xE0, 0xFC, 0xFF`). If the e‑paper panel only understands those codes, you must add a mapping step. See below.

## Install Dependencies
Requires Python 3.9+ and Pillow.

```powershell
python -m pip install pillow
```

## Run
```powershell
python .\epd_image_tool.py
```

## Export & Use in Arduino
1. After loading and converting an image, click "Save C Header".
2. Replace the contents of your existing `image.h` with the new array (or rename appropriately) ensuring the size `[384000]` matches (800 * 480).
3. Rebuild / upload the Arduino sketch.

## Optional: Hardware Palette Remap
If the hardware expects a tiny set of color codes (e.g. 6 values), extend the script:

1. Define the allowed codes and their RGB meaning.
2. After quantization, remap each pixel index to the closest allowed RGB.
3. Output those codes instead of the generic 0–255 index.

Pseudo snippet inside `convert_image` before formatting:
```python
# Example hardware palette (dummy RGBs)
hw = [
    (0x00, (0,0,0)),
    (0x03, (0,0,64)),
    (0x1C, (128,0,0)),
    (0xE0, (255,255,0)),
    (0xFC, (255,255,255)),
    (0xFF, (255,0,0)),
]
# Build array of RGB for each output pixel, pick nearest hw color code.
```

## License
Provided as-is, no warranty.
