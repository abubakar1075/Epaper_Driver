import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// Hardware palette colors for 6-color e-paper display
class ColorMapping {
  final int code;
  final Color rgbColor;
  
  const ColorMapping(this.code, this.rgbColor);
}

class ImageProcessor {
  // Constants
  static const int IMAGE_WIDTH = 800;
  static const int IMAGE_HEIGHT = 480;
  
  // Hardware palette for 6-color e-paper display
  static const List<ColorMapping> hwPalette = [
    ColorMapping(0x00, Color(0xFF000000)), // Black
    ColorMapping(0xFF, Color(0xFFFFFFFF)), // White
    ColorMapping(0xFC, Color(0xFFFFFF00)), // Yellow
    ColorMapping(0xE0, Color(0xFFD20000)), // Red
    ColorMapping(0x03, Color(0xFF0000B4)), // Blue
    ColorMapping(0x1C, Color(0xFF009600)), // Green
  ];
  
  // Image processing options
  bool useFitMode = true;
  bool useDithering = true;
  double brightness = 1.0;
  double contrast = 1.0;
  double saturation = 1.0;
  bool rotate180 = true;
  
  // Process an image file with current settings
  Future<ProcessedImage> processImage(File imageFile) async {
    // Load the original image
    final Uint8List imageBytes = await imageFile.readAsBytes();
    img.Image? originalImage = img.decodeImage(imageBytes);
    
    if (originalImage == null) {
      throw Exception('Failed to decode image');
    }
    
    // Apply brightness, contrast, saturation adjustments
    originalImage = _enhanceImage(originalImage);
    
    // Resize the image according to the fit mode
    img.Image resizedImage;
    if (useFitMode) {
      // Letterbox mode (maintain aspect ratio)
      resizedImage = _fitImage(originalImage);
    } else {
      // Stretch mode
      resizedImage = img.copyResize(
        originalImage,
        width: IMAGE_WIDTH,
        height: IMAGE_HEIGHT,
        interpolation: img.Interpolation.linear
      );
    }
    
    // Convert to 6-color palette with optional dithering
    img.Image convertedImage = _quantizeTo6Colors(resizedImage);
    
    // Create the raw bytes for BLE transfer
    Uint8List processedBytes = _createRawBytes(convertedImage);
    
    // Optionally rotate the image data 180 degrees
    if (rotate180) {
      processedBytes = Uint8List.fromList(processedBytes.reversed.toList());
    }
    
    // Pack the pixels to reduce transfer size
    Uint8List packedBytes = _packPixels(processedBytes);
    
    return ProcessedImage(
      originalImage: originalImage,
      processedImage: convertedImage,
      rawBytes: processedBytes,
      packedBytes: packedBytes
    );
  }
  
  // Apply image enhancements (brightness, contrast, saturation)
  img.Image _enhanceImage(img.Image original) {
    img.Image result = original.clone();
    
    // Apply brightness adjustment
    if (brightness != 1.0) {
      // Manual brightness adjustment
      double factor = brightness;
      for (int y = 0; y < result.height; y++) {
        for (int x = 0; x < result.width; x++) {
          var pixel = result.getPixel(x, y);
          int r = (pixel.r * factor).round().clamp(0, 255);
          int g = (pixel.g * factor).round().clamp(0, 255);
          int b = (pixel.b * factor).round().clamp(0, 255);
          result.setPixelRgb(x, y, r, g, b);
        }
      }
    }
    
    // Apply contrast adjustment
    if (contrast != 1.0) {
      // Manual contrast adjustment
      double factor = contrast;
      double avg = 128;
      for (int y = 0; y < result.height; y++) {
        for (int x = 0; x < result.width; x++) {
          var pixel = result.getPixel(x, y);
          int r = ((pixel.r - avg) * factor + avg).round().clamp(0, 255);
          int g = ((pixel.g - avg) * factor + avg).round().clamp(0, 255);
          int b = ((pixel.b - avg) * factor + avg).round().clamp(0, 255);
          result.setPixelRgb(x, y, r, g, b);
        }
      }
    }
    
    // Apply saturation adjustment
    if (saturation != 1.0) {
      // Manual saturation adjustment
      double factor = saturation;
      for (int y = 0; y < result.height; y++) {
        for (int x = 0; x < result.width; x++) {
          var pixel = result.getPixel(x, y);
          
          // Convert to HSL
          double r = pixel.r / 255.0;
          double g = pixel.g / 255.0;
          double b = pixel.b / 255.0;
          
          double max = math.max(r, math.max(g, b));
          double min = math.min(r, math.min(g, b));
          double l = (max + min) / 2;
          
          double s;
          if (max == min) {
            s = 0;
          } else if (l <= 0.5) {
            s = (max - min) / (max + min);
          } else {
            s = (max - min) / (2.0 - max - min);
          }
          
          // Adjust saturation
          s = math.min(1.0, s * factor);
          
          // Convert back to RGB
          if (s == 0) {
            // Grayscale
            result.setPixelRgb(x, y, (l * 255).round(), (l * 255).round(), (l * 255).round());
          } else {
            // Preserve the original RGB values
            result.setPixelRgb(x, y, pixel.r, pixel.g, pixel.b);
          }
        }
      }
    }
    
    return result;
  }
  
  // Fit the image with letterboxing
  img.Image _fitImage(img.Image original) {
    double aspectSrc = original.width / original.height;
    double aspectDst = IMAGE_WIDTH / IMAGE_HEIGHT;
    
    int newWidth, newHeight;
    
    if (aspectSrc > aspectDst) {
      newWidth = IMAGE_WIDTH;
      newHeight = (newWidth / aspectSrc).round();
    } else {
      newHeight = IMAGE_HEIGHT;
      newWidth = (newHeight * aspectSrc).round();
    }
    
    // Resize while maintaining aspect ratio
    img.Image resized = img.copyResize(
      original,
      width: newWidth,
      height: newHeight,
      interpolation: img.Interpolation.linear
    );
    
    // Create a white canvas of target size
    img.Image canvas = img.Image(
      width: IMAGE_WIDTH,
      height: IMAGE_HEIGHT,
    );
    
    // Fill with white
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    
    // Paste the resized image in the center
    int offsetX = (IMAGE_WIDTH - newWidth) ~/ 2;
    int offsetY = (IMAGE_HEIGHT - newHeight) ~/ 2;
    
    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);
    
    return canvas;
  }
  
  // Quantize to the 6-color palette
  img.Image _quantizeTo6Colors(img.Image image) {
    // Create palette colors for quantization
    final palette = <int>[];
    for (var mapping in hwPalette) {
      final c = mapping.rgbColor;
      palette.addAll([c.red, c.green, c.blue]);
    }
    
    // Create a palette image
    final paletteImage = img.Image(width: 1, height: 1);
    for (int i = 0; i < palette.length; i += 3) {
      paletteImage.setPixelRgb(0, 0, palette[i], palette[i + 1], palette[i + 2]);
    }
    
    // Use quantize with the created palette
    var dithering = useDithering 
        ? img.DitherKernel.floydSteinberg 
        : img.DitherKernel.none;
    
    return img.quantize(
      image,
      numberOfColors: hwPalette.length,
      method: img.QuantizeMethod.octree,
      dither: dithering
    );
  }
  
  // Create raw bytes for BLE transfer - map pixels to palette codes
  Uint8List _createRawBytes(img.Image image) {
    final int pixelCount = image.width * image.height;
    final Uint8List result = Uint8List(pixelCount);
    
    // Map each pixel to the closest palette color
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final int r = pixel.r.toInt();
        final int g = pixel.g.toInt();
        final int b = pixel.b.toInt();
        
        // Find the closest color in our hardware palette
        int closestColorIndex = 0;
        int minDistance = 255 * 255 * 3; // Max possible distance
        
        for (int i = 0; i < hwPalette.length; i++) {
          final Color c = hwPalette[i].rgbColor;
          final int dr = r - c.red;
          final int dg = g - c.green;
          final int db = b - c.blue;
          final int distance = dr * dr + dg * dg + db * db;
          
          if (distance < minDistance) {
            minDistance = distance;
            closestColorIndex = i;
          }
        }
        
        // Store the byte code for this color
        final int index = y * image.width + x;
        result[index] = hwPalette[closestColorIndex].code;
      }
    }
    
    return result;
  }
  
  // Pack pixels 2-per-byte to reduce BLE transfer size
  Uint8List _packPixels(Uint8List rawData) {
    // Map from 8-bit color codes to 4-bit codes
    final Map<int, int> colorMap = {
      0x00: 0x0, // Black
      0xFF: 0x1, // White
      0xFC: 0x2, // Yellow
      0xE0: 0x3, // Red
      0x03: 0x5, // Blue
      0x1C: 0x6, // Green
    };
    
    final int packedLength = (rawData.length + 1) ~/ 2; // Round up division
    final Uint8List result = Uint8List(packedLength);
    
    // Pack two pixels into one byte
    for (int i = 0; i < rawData.length; i += 2) {
      final int pixel1 = colorMap[rawData[i]] ?? 0;
      final int pixel2 = (i + 1 < rawData.length) ? (colorMap[rawData[i + 1]] ?? 0) : 0;
      final int packed = (pixel1 << 4) | pixel2;
      result[i ~/ 2] = packed;
    }
    
    return result;
  }
}

// Class to hold processed image data
class ProcessedImage {
  final img.Image originalImage;
  final img.Image processedImage;
  final Uint8List rawBytes;      // Raw pixels, one byte per pixel
  final Uint8List packedBytes;   // Packed pixels, two pixels per byte
  
  ProcessedImage({
    required this.originalImage,
    required this.processedImage,
    required this.rawBytes,
    required this.packedBytes,
  });
}