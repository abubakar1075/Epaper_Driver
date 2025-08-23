"""EPD Image Conversion Tool (6-color) with BLE connectivity

Converts an image to a const unsigned char gImage_1[384000] array (800x480) using
ONLY the 6 hardware-supported bytes: 00 FF FC E0 03 1C (Black White Yellow Red Blue Green).

GUI usage:
  1. Open image
  2. Choose Fit (letterbox) or Stretch, optionally toggle dithering
  3. Optionally choose to rotate the image 180° before sending (not visible in preview)
  4. Scan for BLE devices
  5. Connect to your Arduino BLE device
  6. Send image data via BLE

CLI usage (optional quick convert):
  python epd_image_tool_ble.py input.jpg output.h
"""
from __future__ import annotations
import os, sys
import asyncio
import threading
from dataclasses import dataclass
from typing import List, Tuple, Optional, Dict, Any, Callable, Union

try:
    from PIL import Image, ImageTk, ImageEnhance, ImageFilter, ImageOps
except ImportError as e:  # pragma: no cover
    raise SystemExit("Pillow is required. Install with: pip install Pillow") from e

try:
    import numpy as np
except ImportError as e:  # pragma: no cover
    raise SystemExit("NumPy is required. Install with: pip install numpy") from e

try:
    import bleak
    from bleak import BleakScanner, BleakClient
    from bleak.backends.device import BLEDevice
except ImportError as e:  # pragma: no cover
    raise SystemExit("Bleak is required for BLE. Install with: pip install bleak") from e

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

WIDTH = 800
HEIGHT = 480
ARRAY_NAME = "gImage_1"
OUTPUT_FILENAME = "image_converted.h"
BLE_CHUNK_SIZE = 512  # Maximum chunk size for optimized transfer
BLE_ACK_THRESHOLD = 200  # Match the ESP32 acknowledgment threshold
MAX_CHUNK_SIZE = 512  # Maximum allowed chunk size

# We'll dynamically adjust this based on device capabilities
MAX_CHUNK_SIZE = 512

# Constants for BLE acknowledgements
ACK_SIZE_RECEIVED = 0x01  # Size acknowledgment
ACK_PROGRESS = 0x02       # Progress update
ACK_COMPLETE = 0x03       # Transfer complete
ACK_ERROR = 0xFF          # Error acknowledgment

# UUID for the Nordic UART Service (NUS) - common for BLE UART communication
# You may need to change these UUIDs based on your Arduino BLE implementation
UART_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
UART_RX_CHAR_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  # RX from the Arduino's perspective
UART_TX_CHAR_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  # TX from the Arduino's perspective

HW_PALETTE = [
    (0x00, (0, 0, 0)),        # Black
    (0xFF, (255, 255, 255)),  # White
    (0xFC, (255, 255, 0)),    # Yellow
    (0xE0, (210, 0, 0)),      # Red
    (0x03, (0, 0, 180)),      # Blue
    (0x1C, (0, 150, 0)),      # Green
]

@dataclass
class ConversionOptions:
    fit_mode: str = "fit"          # 'fit' (letterbox) or 'stretch'
    dithering: bool = True          # Floyd–Steinberg if True
    pad_color: Tuple[int, int, int] = (255, 255, 255)  # background for letterbox
    brightness: float = 1.0         # Brightness enhancement (1.0 = normal)
    contrast: float = 1.0           # Contrast enhancement (1.0 = normal)
    saturation: float = 1.0         # Color saturation (1.0 = normal)
    painting_effect: float = 0.0    # Painting effect strength (0.0 = none, 1.0 = max)
    rotate_180: bool = True         # Image always rotated 180 degrees before sending (hidden from UI)

def resize_canvas(img: Image.Image, opts: ConversionOptions) -> Image.Image:
    if opts.fit_mode == "stretch":
        return img.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
    aspect_src = img.width / img.height
    aspect_dst = WIDTH / HEIGHT
    if aspect_src > aspect_dst:
        new_w = WIDTH
        new_h = int(round(new_w / aspect_src))
    else:
        new_h = HEIGHT
        new_w = int(round(new_h * aspect_src))
    resized = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (WIDTH, HEIGHT), opts.pad_color)
    off_x = (WIDTH - new_w) // 2
    off_y = (HEIGHT - new_h) // 2
    canvas.paste(resized, (off_x, off_y))
    return canvas

def quantize_to_6color(img: Image.Image, opts: ConversionOptions) -> Tuple[Image.Image, bytes]:
    # Apply image enhancements first
    img = enhance_image(img, opts)
    
    pal_entries: List[int] = []
    for _, (r, g, b) in HW_PALETTE:
        pal_entries.extend([r, g, b])
    pal_entries.extend([0, 0, 0] * (256 - len(HW_PALETTE)))
    pal_img_base = Image.new("P", (1, 1))
    pal_img_base.putpalette(pal_entries)
    dither_flag = Image.FLOYDSTEINBERG if opts.dithering else Image.Dither.NONE
    quant = img.convert("RGB").quantize(colors=len(HW_PALETTE), method=Image.MEDIANCUT,
                                        dither=dither_flag, palette=pal_img_base)
    idx_to_code = [code for code, _ in HW_PALETTE]
    raw = quant.tobytes()
    
    # Convert to normal unpacked format (1 byte per pixel)
    unpacked_data = bytes(idx_to_code[i] for i in raw)
    
    return quant.convert("RGB"), unpacked_data

def enhance_image(img: Image.Image, opts: ConversionOptions) -> Image.Image:
    """Apply various image enhancements based on the options"""
    # Convert to RGB mode to ensure compatibility with enhancement operations
    img = img.convert("RGB")
    
    # Apply brightness adjustment (make colors more vibrant)
    if opts.brightness != 1.0:
        enhancer = ImageEnhance.Brightness(img)
        img = enhancer.enhance(opts.brightness)
        
    # Apply contrast adjustment
    if opts.contrast != 1.0:
        enhancer = ImageEnhance.Contrast(img)
        img = enhancer.enhance(opts.contrast)
        
    # Apply color saturation adjustment
    if opts.saturation != 1.0:
        enhancer = ImageEnhance.Color(img)
        img = enhancer.enhance(opts.saturation)
    
    # Apply painting-like effect if requested
    if opts.painting_effect > 0:
        # Blend original with a smoothed version for a painting-like effect
        # First create a smoothed version
        smoothed = img.filter(ImageFilter.SMOOTH_MORE)
        
        # For stronger effect, apply additional smoothing and edge enhancement
        if opts.painting_effect > 0.5:
            edge_img = img.filter(ImageFilter.EDGE_ENHANCE)
            smoothed = smoothed.filter(ImageFilter.SMOOTH_MORE)
            
            # Create a painting-like effect by combining edge enhancement with smoothing
            # Convert to numpy arrays for easier blending
            img_array = np.array(img)
            smoothed_array = np.array(smoothed)
            edge_array = np.array(edge_img)
            
            # Blend based on painting effect strength
            strength = opts.painting_effect
            result_array = (
                img_array * (1 - strength) + 
                smoothed_array * (strength * 0.7) + 
                edge_array * (strength * 0.3)
            ).astype(np.uint8)
            
            img = Image.fromarray(result_array)
        else:
            # Simple blending for lighter effect
            img_array = np.array(img)
            smoothed_array = np.array(smoothed)
            result_array = (
                img_array * (1 - opts.painting_effect) + 
                smoothed_array * opts.painting_effect
            ).astype(np.uint8)
            
            img = Image.fromarray(result_array)
    
    return img

def format_c_array(name: str, data: bytes, line_bytes: int = 16) -> str:
    hex_chunks = [f"0x{b:02X}" for b in data]
    lines = [",".join(hex_chunks[i:i+line_bytes]) for i in range(0, len(hex_chunks), line_bytes)]
    body = ",\n".join(lines)
    return f"const unsigned char {name}[{len(data)}]={{/*6-color*/\n{body}\n}};\n"

def pack_pixels(data: bytes) -> bytes:
    """
    Pack 2 pixels into 1 byte to reduce data size by half
    Each 6-color value will use 4 bits (high 4 bits for first pixel, low 4 bits for second)
    """
    # Map from 8-bit color codes to 4-bit codes
    color_map = {
        0x00: 0x0,  # Black
        0xFF: 0x1,  # White
        0xFC: 0x2,  # Yellow
        0xE0: 0x3,  # Red
        0x03: 0x5,  # Blue
        0x1C: 0x6,  # Green
    }
    
    result = bytearray()
    # Pack two pixels into one byte
    for i in range(0, len(data), 2):
        if i+1 < len(data):
            pixel1 = color_map.get(data[i], 0)
            pixel2 = color_map.get(data[i+1], 0)
            packed = (pixel1 << 4) | pixel2
            result.append(packed)
        else:
            # Handle odd number of pixels (shouldn't happen with 800x480 display)
            pixel1 = color_map.get(data[i], 0)
            result.append(pixel1 << 4)
            
    return bytes(result)

def convert_image(path_or_image: Union[str, Image.Image], opts: ConversionOptions) -> Tuple[Image.Image, Image.Image, bytes, str]:
    if isinstance(path_or_image, str):
        original = Image.open(path_or_image)
    else:
        original = path_or_image
    prepared = resize_canvas(original, opts)
    disp_img, data = quantize_to_6color(prepared, opts)
    if len(data) != WIDTH * HEIGHT:
        raise ValueError("Unexpected data length")
    return original, disp_img, data, format_c_array(ARRAY_NAME, data)

def rotate_image_data_180(data: bytes) -> bytes:
    """Rotate image data 180 degrees by reversing the byte order"""
    # For 180 degree rotation, we simply reverse the order of pixels
    return data[::-1]

class BLEManager:
    def __init__(self, status_callback: Callable[[str], None]):
        self.status_callback = status_callback
        self.devices: List[BLEDevice] = []
        self.client: Optional[BleakClient] = None
        self.connected_device: Optional[BLEDevice] = None
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self._run_event_loop, daemon=True)
        self.thread.start()

    def _run_event_loop(self):
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    async def _scan_devices(self):
        self.devices = []
        self.status_callback("Scanning for BLE devices...")
        devices = await BleakScanner.discover()
        self.devices = [d for d in devices if d.name is not None]
        self.status_callback(f"Found {len(self.devices)} BLE devices")
        return self.devices

    def scan_devices(self, callback: Callable[[List[BLEDevice]], None]):
        """Scan for BLE devices and pass the results to the callback"""
        async def scan_and_callback():
            devices = await self._scan_devices()
            # Schedule the callback on the main thread
            callback(devices)
        asyncio.run_coroutine_threadsafe(scan_and_callback(), self.loop)

    async def _connect_to_device(self, device: BLEDevice):
        global BLE_CHUNK_SIZE  # Declare global at the start of the function
        self.status_callback(f"Connecting to {device.name}...")
        try:
            client = BleakClient(device.address, mtu_size=BLE_CHUNK_SIZE)  # Request large MTU immediately
            await client.connect()
            self.client = client
            self.connected_device = device
            self.status_callback(f"Connected to {device.name}")
            
            # Get the actual MTU size
            mtu_size = client.mtu_size
            self.status_callback(f"Negotiated MTU size: {mtu_size}")
            
            # Set up notification handler for TX characteristic
            def notification_handler(sender, data):
                if len(data) >= 1:
                    ack_type = data[0]
                    if ack_type == ACK_SIZE_RECEIVED:
                        self.status_callback("Size received by device")
                    elif ack_type == ACK_PROGRESS:
                        if len(data) >= 2:
                            progress = data[1]
                            self.status_callback(f"Device progress: {progress}%")
                    elif ack_type == ACK_COMPLETE:
                        self.status_callback("Transfer complete acknowledgment")
                    elif ack_type == ACK_ERROR:
                        self.status_callback("Error acknowledgment from device")
                    else:
                        self.status_callback(f"Unknown acknowledgment type: {ack_type}")
            
            # Enable notifications for the TX characteristic
            for service in client.services:
                if service.uuid.lower() == UART_SERVICE_UUID.lower():
                    for char in service.characteristics:
                        if char.uuid.lower() == UART_TX_CHAR_UUID.lower():
                            await client.start_notify(char.uuid, notification_handler)
                            self.status_callback("Notifications enabled")
                            break
            
            # Adjust chunk size based on negotiated MTU (if supported by platform)
            if mtu_size and mtu_size > 23:  # If we got a valid MTU larger than default
                # MTU - 3 bytes overhead = max ATT payload
                BLE_CHUNK_SIZE = min(MAX_CHUNK_SIZE, mtu_size - 3)
                self.status_callback(f"Adjusted chunk size to {BLE_CHUNK_SIZE} bytes")
            
            return True
        except Exception as e:
            self.status_callback(f"Failed to connect: {str(e)}")
            return False

    def connect_to_device(self, device: BLEDevice, callback: Callable[[bool], None]):
        """Connect to a BLE device and call the callback with success/failure"""
        async def connect_and_callback():
            success = await self._connect_to_device(device)
            callback(success)
        asyncio.run_coroutine_threadsafe(connect_and_callback(), self.loop)

    def disconnect(self):
        """Disconnect from the current BLE device"""
        async def disconnect_async():
            if self.client and self.client.is_connected:
                await self.client.disconnect()
                self.status_callback("Disconnected")
                self.client = None
                self.connected_device = None
        asyncio.run_coroutine_threadsafe(disconnect_async(), self.loop)

    async def _send_data(self, data: bytes, rotate_180: bool = True):
        """Send data to the connected BLE device"""
        global BLE_CHUNK_SIZE, BLE_ACK_THRESHOLD  # Add global declarations
        
        if not self.client or not self.client.is_connected:
            self.status_callback("Not connected to any device")
            return False

        try:
            # Check if the UART service and characteristic are available
            services = self.client.services
            uart_service = None
            for service in services:
                if service.uuid.lower() == UART_SERVICE_UUID.lower():
                    uart_service = service
                    break

            if not uart_service:
                self.status_callback("UART service not found on device")
                return False

            rx_char = None
            for char in uart_service.characteristics:
                if char.uuid.lower() == UART_RX_CHAR_UUID.lower():
                    rx_char = char
                    break

            if not rx_char:
                self.status_callback("UART RX characteristic not found")
                return False

            # Always apply 180-degree rotation (now mandatory)
            data = rotate_image_data_180(data)
            
            # Pack the data (2 pixels per byte)
            packed_data = pack_pixels(data)
            self.status_callback(f"Packed data size: {len(packed_data)} bytes (original: {len(data)} bytes)")
            
            # Record start time for speed calculation
            start_time = asyncio.get_event_loop().time()
            
            # Send the total size first as a 4-byte value (of the packed data)
            total_size = len(packed_data)
            size_bytes = total_size.to_bytes(4, byteorder='little')
            await self.client.write_gatt_char(rx_char, size_bytes)
            
            # Minimal delay to ensure ESP32 processes the size
            await asyncio.sleep(0.05)  # Reduced from 0.1s to 0.05s
            
            # Send data in chunks at maximum speed
            chunks = [packed_data[i:i+BLE_CHUNK_SIZE] for i in range(0, len(packed_data), BLE_CHUNK_SIZE)]
            total_chunks = len(chunks)
            
            self.status_callback(f"Sending {total_chunks} chunks of {BLE_CHUNK_SIZE} bytes each")
            bytes_sent = 0
            ack_counter = 0
            
            for i, chunk in enumerate(chunks):
                # Only show status updates occasionally to reduce overhead
                if i % 20 == 0 or i == total_chunks - 1:
                    self.status_callback(f"Sending chunk {i+1}/{total_chunks}")
                
                await self.client.write_gatt_char(rx_char, chunk)
                bytes_sent += len(chunk)
                ack_counter += 1
                
                # Update progress periodically, matching the ESP32's ACK_THRESHOLD
                if ack_counter >= BLE_ACK_THRESHOLD or i == total_chunks - 1:
                    ack_counter = 0
                    progress = int(bytes_sent * 100 / total_size)
                    
                    # Calculate and show transfer speed
                    current_time = asyncio.get_event_loop().time()
                    elapsed_time = current_time - start_time
                    if elapsed_time > 0:
                        speed_kbps = (bytes_sent / 1024) / elapsed_time
                        # Only update UI every 10% to reduce overhead
                        if progress % 10 == 0 or progress == 100:
                            self.status_callback(f"Progress: {progress}% - Speed: {speed_kbps:.2f} KB/s")
                    
                    # Minimal delay only when acknowledgment is needed
                    # No delay needed in most cases to maximize transfer speed
                    pass
                else:
                    # No delay between chunks for maximum speed when not waiting for ACK
                    pass
            
            # Calculate final transfer statistics
            end_time = asyncio.get_event_loop().time()
            total_time = end_time - start_time
            avg_speed_kbps = (total_size / 1024) / total_time if total_time > 0 else 0
            
            self.status_callback(f"Data transfer complete: {total_size} bytes sent in {total_time:.2f} seconds")
            self.status_callback(f"Average transfer speed: {avg_speed_kbps:.2f} KB/s")
            return True
        except Exception as e:
            self.status_callback(f"Error sending data: {str(e)}")
            return False

    def send_data(self, data: bytes, callback: Callable[[bool], None], rotate_180: bool = False):
        """Send data to the connected BLE device and call the callback with success/failure"""
        async def send_and_callback():
            success = await self._send_data(data, rotate_180)
            callback(success)
        asyncio.run_coroutine_threadsafe(send_and_callback(), self.loop)

    def cleanup(self):
        """Clean up resources"""
        self.disconnect()
        self.loop.call_soon_threadsafe(self.loop.stop)


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("EPD Image Converter 800x480 (6-color) with BLE")
        self.geometry("1200x700")
        self.options = ConversionOptions()
        self.original_tk = None
        self.converted_tk = None
        self.current_c_code: Optional[str] = None
        self.image_data: Optional[bytes] = None
        self.original_image: Optional[Image.Image] = None  # Store original image for reprocessing
        
        # Initialize the BLE manager
        self.ble_manager = BLEManager(self.update_status)
        
        # Set up for closing the window
        self.protocol("WM_DELETE_WINDOW", self.on_closing)
        
        self._build_ui()

    def _build_ui(self):
        frm = ttk.Frame(self)
        frm.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)
        
        # Create a frame for image control and BLE control with a separator
        ctrl_frame = ttk.Frame(frm)
        ctrl_frame.pack(side=tk.LEFT, fill=tk.Y)
        
        # Image control section
        img_ctrl = ttk.LabelFrame(ctrl_frame, text="Image Control")
        img_ctrl.pack(fill=tk.X, pady=5)
        ttk.Button(img_ctrl, text="Open Image", command=self.open_image).pack(fill=tk.X, pady=2, padx=5)
        self.fit_mode_var = tk.StringVar(value=self.options.fit_mode)
        ttk.Label(img_ctrl, text="Resize Mode:").pack(anchor=tk.W, padx=5)
        ttk.Radiobutton(img_ctrl, text="Fit (letterbox)", value="fit", variable=self.fit_mode_var).pack(anchor=tk.W, padx=5)
        ttk.Radiobutton(img_ctrl, text="Stretch", value="stretch", variable=self.fit_mode_var).pack(anchor=tk.W, padx=5)
        
        self.dither_var = tk.BooleanVar(value=self.options.dithering)
        ttk.Checkbutton(img_ctrl, text="Floyd–Steinberg Dithering", variable=self.dither_var, command=self.apply_changes).pack(anchor=tk.W, pady=4, padx=5)
        
        # Hidden rotation option (always true, but UI element removed)
        self.rotate_var = tk.BooleanVar(value=True)
        
        # Image enhancement sliders
        ttk.Separator(img_ctrl, orient=tk.HORIZONTAL).pack(fill=tk.X, pady=5, padx=5)
        ttk.Label(img_ctrl, text="Image Enhancement:").pack(anchor=tk.W, padx=5, pady=(5, 0))
        
        # Brightness slider
        ttk.Label(img_ctrl, text="Brightness:").pack(anchor=tk.W, padx=5)
        self.brightness_var = tk.DoubleVar(value=self.options.brightness)
        brightness_slider = ttk.Scale(img_ctrl, from_=0.5, to=1.5, variable=self.brightness_var, 
                                     orient=tk.HORIZONTAL, length=200, command=self.on_slider_change)
        brightness_slider.pack(fill=tk.X, padx=5)
        
        # Contrast slider
        ttk.Label(img_ctrl, text="Contrast:").pack(anchor=tk.W, padx=5)
        self.contrast_var = tk.DoubleVar(value=self.options.contrast)
        contrast_slider = ttk.Scale(img_ctrl, from_=0.5, to=1.5, variable=self.contrast_var, 
                                   orient=tk.HORIZONTAL, length=200, command=self.on_slider_change)
        contrast_slider.pack(fill=tk.X, padx=5)
        
        # Saturation slider
        ttk.Label(img_ctrl, text="Color Saturation:").pack(anchor=tk.W, padx=5)
        self.saturation_var = tk.DoubleVar(value=self.options.saturation)
        saturation_slider = ttk.Scale(img_ctrl, from_=0.5, to=1.5, variable=self.saturation_var, 
                                     orient=tk.HORIZONTAL, length=200, command=self.on_slider_change)
        saturation_slider.pack(fill=tk.X, padx=5)
        
        # Painting effect slider
        ttk.Label(img_ctrl, text="Painting Effect:").pack(anchor=tk.W, padx=5)
        self.painting_var = tk.DoubleVar(value=self.options.painting_effect)
        painting_slider = ttk.Scale(img_ctrl, from_=0.0, to=1.0, variable=self.painting_var, 
                                   orient=tk.HORIZONTAL, length=200, command=self.on_slider_change)
        painting_slider.pack(fill=tk.X, padx=5)
        
        # Reset button for image enhancements
        ttk.Button(img_ctrl, text="Reset Enhancements", command=self.reset_enhancements).pack(fill=tk.X, pady=(5, 10), padx=5)
        
        ttk.Button(img_ctrl, text="Save C Header", command=self.save_header).pack(fill=tk.X, pady=(10,4), padx=5)
        ttk.Button(img_ctrl, text="Copy Array to Clipboard", command=self.copy_code).pack(fill=tk.X, padx=5)
        
        # BLE control section
        ble_ctrl = ttk.LabelFrame(ctrl_frame, text="BLE Control")
        ble_ctrl.pack(fill=tk.X, pady=10)
        ttk.Button(ble_ctrl, text="Scan for BLE Devices", command=self.scan_ble_devices).pack(fill=tk.X, pady=2, padx=5)
        
        # Device selection
        ttk.Label(ble_ctrl, text="Select Device:").pack(anchor=tk.W, padx=5, pady=(5,0))
        self.device_listbox = tk.Listbox(ble_ctrl, height=5)
        self.device_listbox.pack(fill=tk.X, padx=5, pady=2)
        
        # Connect/Disconnect button
        self.connect_var = tk.StringVar(value="Connect")
        self.connect_button = ttk.Button(ble_ctrl, textvariable=self.connect_var, command=self.toggle_connection)
        self.connect_button.pack(fill=tk.X, pady=2, padx=5)
        
        # Send data button
        self.send_button = ttk.Button(ble_ctrl, text="Send Image Data to Device", command=self.send_image_data, state=tk.DISABLED)
        self.send_button.pack(fill=tk.X, pady=10, padx=5)
        
        # Status display
        self.status_var = tk.StringVar(value="Idle")
        status_frame = ttk.LabelFrame(ctrl_frame, text="Status")
        status_frame.pack(fill=tk.X, pady=5)
        ttk.Label(status_frame, textvariable=self.status_var, wraplength=200, foreground="blue").pack(fill=tk.X, pady=5, padx=5)
        
        # Canvas section for image preview
        canv = ttk.Frame(frm)
        canv.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        
        ttk.Label(canv, text="Original Image").pack(pady=(0,5))
        self.orig_canvas = tk.Label(canv, bg="#333")
        self.orig_canvas.pack(side=tk.TOP, expand=True, padx=5, pady=5)
        
        ttk.Label(canv, text="Converted Image").pack(pady=(10,5))
        self.conv_canvas = tk.Label(canv, bg="#222")
        self.conv_canvas.pack(side=tk.TOP, expand=True, padx=5, pady=5)
        
        ttk.Label(canv, text="Output uses only: 00 FF FC E0 03 1C", foreground="gray").pack(fill=tk.X, pady=4)

    def update_status(self, message: str):
        """Update the status message - this can be called from other threads"""
        self.status_var.set(message)
        # Force update of the UI
        self.update_idletasks()

    def open_image(self):
        path = filedialog.askopenfilename(title="Select Image", filetypes=[("Image Files", ".png .jpg .jpeg .bmp .gif .tif .tiff"), ("All Files", "*.*")])
        if not path:
            return
        try:
            # Store the original image for reprocessing when settings change
            self.original_image = Image.open(path)
            # Apply current settings to the image
            self.apply_changes()
            self.status_var.set(f"Loaded {os.path.basename(path)}")
        except Exception as e:  # pragma: no cover
            messagebox.showerror("Conversion failed", str(e))
            return

    def _update_previews(self, orig: Image.Image, pal_img: Image.Image):
        preview_w, preview_h = WIDTH//2, HEIGHT//2
        o_disp = orig.copy()
        o_disp.thumbnail((preview_w, preview_h), Image.Resampling.LANCZOS)
        c_disp = pal_img.resize((preview_w, preview_h), Image.Resampling.NEAREST)
        self.original_tk = ImageTk.PhotoImage(o_disp)
        self.converted_tk = ImageTk.PhotoImage(c_disp)
        self.orig_canvas.configure(image=self.original_tk)
        self.conv_canvas.configure(image=self.converted_tk)

    def save_header(self):
        if not self.current_c_code:
            messagebox.showinfo("Nothing to save", "Load & convert an image first.")
            return
        out_path = filedialog.asksaveasfilename(defaultextension=".h", initialfile=OUTPUT_FILENAME, filetypes=[("C Header", ".h"), ("All Files", "*.*")])
        if not out_path:
            return
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(self.current_c_code)
        self.status_var.set(f"Saved header: {os.path.basename(out_path)}")

    def copy_code(self):
        if not self.current_c_code:
            messagebox.showinfo("Nothing to copy", "Load & convert an image first.")
            return
        self.clipboard_clear()
        self.clipboard_append(self.current_c_code)
        self.status_var.set("C array copied to clipboard")
        
    def apply_changes(self, *args):
        """Apply all current settings to the image and update preview"""
        if not self.original_image:
            return
            
        # Update options from UI controls
        self.options.fit_mode = self.fit_mode_var.get()
        self.options.dithering = self.dither_var.get()
        self.options.brightness = self.brightness_var.get()
        self.options.contrast = self.contrast_var.get()
        self.options.saturation = self.saturation_var.get()
        self.options.painting_effect = self.painting_var.get()
        self.options.rotate_180 = True  # Always set to true (hidden from UI)
        
        # Convert the image with current settings
        try:
            # Pass the PIL Image object directly instead of a path
            orig, pal_img, data, c_code = convert_image(self.original_image, self.options)
            self.image_data = data
            self.current_c_code = c_code
            self.status_var.set(f"Image processed: {len(data)} bytes")
            self._update_previews(orig, pal_img)
            
            # Enable the send button if we're connected
            if self.ble_manager.client and self.ble_manager.client.is_connected:
                self.send_button.config(state=tk.NORMAL)
        except Exception as e:
            messagebox.showerror("Conversion failed", str(e))

    def on_slider_change(self, *args):
        """Handler for slider value changes - update the image with a small delay"""
        # Use after to prevent too many updates when dragging sliders
        if hasattr(self, 'update_id'):
            self.after_cancel(self.update_id)
        self.update_id = self.after(100, self.apply_changes)
        
    def reset_enhancements(self):
        """Reset all enhancement sliders to default values"""
        self.brightness_var.set(1.0)
        self.contrast_var.set(1.0)
        self.saturation_var.set(1.0)
        self.painting_var.set(0.0)
        self.apply_changes()

    def scan_ble_devices(self):
        """Scan for BLE devices and update the device listbox"""
        # Clear the listbox
        self.device_listbox.delete(0, tk.END)
        # Update status
        self.update_status("Scanning for BLE devices...")
        # Start scanning
        self.ble_manager.scan_devices(self.update_device_list)

    def update_device_list(self, devices: List[BLEDevice]):
        """Update the device listbox with the scan results"""
        self.device_listbox.delete(0, tk.END)
        for i, device in enumerate(devices):
            display_name = f"{device.name} ({device.address})"
            self.device_listbox.insert(i, display_name)
        if devices:
            self.update_status(f"Found {len(devices)} BLE devices")
        else:
            self.update_status("No BLE devices found")

    def toggle_connection(self):
        """Connect to or disconnect from the selected device"""
        if self.ble_manager.client and self.ble_manager.client.is_connected:
            # Disconnect
            self.ble_manager.disconnect()
            self.connect_var.set("Connect")
            self.send_button.config(state=tk.DISABLED)
        else:
            # Connect to the selected device
            selection = self.device_listbox.curselection()
            if not selection:
                messagebox.showinfo("No device selected", "Please select a device from the list.")
                return
            
            device_index = selection[0]
            if device_index >= len(self.ble_manager.devices):
                messagebox.showinfo("Invalid selection", "Please scan for devices again.")
                return
            
            device = self.ble_manager.devices[device_index]
            self.ble_manager.connect_to_device(device, self.connection_callback)

    def connection_callback(self, success: bool):
        """Called when a connection attempt completes"""
        if success:
            self.connect_var.set("Disconnect")
            if self.image_data:
                self.send_button.config(state=tk.NORMAL)
        else:
            self.connect_var.set("Connect")
            self.send_button.config(state=tk.DISABLED)

    def send_image_data(self):
        """Send the image data to the connected device"""
        if not self.image_data:
            messagebox.showinfo("No image data", "Load & convert an image first.")
            return
            
        if not self.ble_manager.client or not self.ble_manager.client.is_connected:
            messagebox.showinfo("Not connected", "Connect to a BLE device first.")
            return
        
        # Always rotate 180 degrees (now hardcoded)
        rotate_180 = True
        self.update_status("Preparing image data...")
        
        self.update_status("Sending image data...")
        self.send_button.config(state=tk.DISABLED)
        
        def send_callback(success: bool):
            if success:
                self.update_status("Image data sent successfully")
            else:
                self.update_status("Failed to send image data")
            self.send_button.config(state=tk.NORMAL)
            
        self.ble_manager.send_data(self.image_data, send_callback, rotate_180)

    def on_closing(self):
        """Clean up BLE resources before closing"""
        self.ble_manager.cleanup()
        self.destroy()

def main():  # pragma: no cover
    # CLI quick path
    if len(sys.argv) == 3 and os.path.isfile(sys.argv[1]):
        inp, outp = sys.argv[1], sys.argv[2]
        opts = ConversionOptions()
        _, _, data, c_code = convert_image(inp, opts)
        with open(outp, "w", encoding="utf-8") as f:
            f.write(c_code)
        print(f"Wrote {outp} ({len(data)} bytes)")
        return
    app = App()
    app.mainloop()

if __name__ == "__main__":  # pragma: no cover
    main()
