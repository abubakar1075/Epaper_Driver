"""EPD Image Conversion Tool (6-color only)

Converts an image to a const unsigned char gImage_1[384000] array (800x480) using
ONLY the 6 hardware-supported bytes: 00 FF FC E0 03 1C (Black White Yellow Red Blue Green).

GUI usage:
  1. Open image
  2. Choose Fit (letterbox) or Stretch, optionally toggle dithering
  3. Save header or copy array

CLI usage (optional quick convert):
  python epd_image_tool.py input.jpg output.h
"""
from __future__ import annotations
import os, sys
from dataclasses import dataclass
from typing import List, Tuple, Optional

try:
    from PIL import Image, ImageTk
except ImportError as e:  # pragma: no cover
    raise SystemExit("Pillow is required. Install with: pip install Pillow") from e

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

WIDTH = 800
HEIGHT = 480
ARRAY_NAME = "gImage_1"
OUTPUT_FILENAME = "image_converted.h"

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
    return quant.convert("RGB"), bytes(idx_to_code[i] for i in raw)

def format_c_array(name: str, data: bytes, line_bytes: int = 16) -> str:
    hex_chunks = [f"0x{b:02X}" for b in data]
    lines = [",".join(hex_chunks[i:i+line_bytes]) for i in range(0, len(hex_chunks), line_bytes)]
    body = ",\n".join(lines)
    return f"const unsigned char {name}[{len(data)}]={{/*6-color*/\n{body}\n}};\n"

def convert_image(path: str, opts: ConversionOptions) -> Tuple[Image.Image, Image.Image, bytes, str]:
    original = Image.open(path)
    prepared = resize_canvas(original, opts)
    disp_img, data = quantize_to_6color(prepared, opts)
    if len(data) != WIDTH * HEIGHT:
        raise ValueError("Unexpected data length")
    return original, disp_img, data, format_c_array(ARRAY_NAME, data)

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("EPD Image Converter 800x480 (6-color)")
        self.geometry("1200x700")
        self.options = ConversionOptions()
        self.original_tk = None
        self.converted_tk = None
        self.current_c_code: Optional[str] = None
        self._build_ui()

    def _build_ui(self):
        frm = ttk.Frame(self)
        frm.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)
        ctrl = ttk.Frame(frm)
        ctrl.pack(side=tk.LEFT, fill=tk.Y)
        ttk.Button(ctrl, text="Open Image", command=self.open_image).pack(fill=tk.X, pady=2)
        self.fit_mode_var = tk.StringVar(value=self.options.fit_mode)
        ttk.Label(ctrl, text="Resize Mode:").pack(anchor=tk.W)
        ttk.Radiobutton(ctrl, text="Fit (letterbox)", value="fit", variable=self.fit_mode_var).pack(anchor=tk.W)
        ttk.Radiobutton(ctrl, text="Stretch", value="stretch", variable=self.fit_mode_var).pack(anchor=tk.W)
        self.dither_var = tk.BooleanVar(value=self.options.dithering)
        ttk.Checkbutton(ctrl, text="Floyd–Steinberg Dithering", variable=self.dither_var).pack(anchor=tk.W, pady=4)
        ttk.Button(ctrl, text="Save C Header", command=self.save_header).pack(fill=tk.X, pady=(10,4))
        ttk.Button(ctrl, text="Copy Array to Clipboard", command=self.copy_code).pack(fill=tk.X)
        self.status_var = tk.StringVar(value="Idle")
        ttk.Label(ctrl, textvariable=self.status_var, wraplength=200, foreground="blue").pack(fill=tk.X, pady=10)
        canv = ttk.Frame(frm)
        canv.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.orig_canvas = tk.Label(canv, bg="#333")
        self.orig_canvas.pack(side=tk.LEFT, expand=True, padx=5, pady=5)
        self.conv_canvas = tk.Label(canv, bg="#222")
        self.conv_canvas.pack(side=tk.LEFT, expand=True, padx=5, pady=5)
        ttk.Label(canv, text="Output uses only: 00 FF FC E0 03 1C", foreground="gray").pack(fill=tk.X, pady=4)

    def open_image(self):
        path = filedialog.askopenfilename(title="Select Image", filetypes=[("Image Files", ".png .jpg .jpeg .bmp .gif .tif .tiff"), ("All Files", "*.*")])
        if not path:
            return
        self.options.fit_mode = self.fit_mode_var.get()
        self.options.dithering = self.dither_var.get()
        try:
            orig, pal_img, data, c_code = convert_image(path, self.options)
        except Exception as e:  # pragma: no cover
            messagebox.showerror("Conversion failed", str(e))
            return
        self.current_c_code = c_code
        self.status_var.set(f"Loaded {os.path.basename(path)} -> {len(data)} bytes")
        self._update_previews(orig, pal_img)

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
