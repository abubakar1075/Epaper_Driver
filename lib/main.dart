import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tuple/tuple.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EPaper Image Sender',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const EPaperImageSender(),
    );
  }
}

class EPaperImageSender extends StatefulWidget {
  const EPaperImageSender({super.key});

  @override
  State<EPaperImageSender> createState() => _EPaperImageSenderState();
}

class _EPaperImageSenderState extends State<EPaperImageSender> {
  // Constants
  static const int IMAGE_WIDTH = 800;
  static const int IMAGE_HEIGHT = 480;
  static const int BLE_CHUNK_SIZE = 230; // Reduced from 512 to stay under BLE MTU limit

  // BLE UUIDs - match with Arduino code
  static const String UART_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String UART_RX_CHAR_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // To Arduino
  static const String UART_TX_CHAR_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // From Arduino

  // Acknowledgment types
  static const int ACK_SIZE_RECEIVED = 0x01;
  static const int ACK_PROGRESS = 0x02;
  static const int ACK_COMPLETE = 0x03;
  static const int ACK_ERROR = 0xFF;

  // Hardware palette for 6-color e-paper display - exact RGB values from Python
  static const List<ColorMap> hwPalette = [
    ColorMap(0x00, Color.fromRGBO(0, 0, 0, 1)),       // Black
    ColorMap(0xFF, Color.fromRGBO(255, 255, 255, 1)), // White
    ColorMap(0xFC, Color.fromRGBO(255, 255, 0, 1)),   // Yellow (255, 255, 0)
    ColorMap(0xE0, Color.fromRGBO(210, 0, 0, 1)),     // Red (210, 0, 0)
    ColorMap(0x03, Color.fromRGBO(0, 0, 180, 1)),     // Blue (0, 0, 180)
    ColorMap(0x1C, Color.fromRGBO(0, 150, 0, 1)),     // Green (0, 150, 0)
  ];
  
  // Image processing options
  bool _useDithering = true;
  double _brightness = 1.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  bool _rotate180 = true;

  // UI State
  File? _originalImage;
  ui.Image? _uiOriginal; // decoded for painting
  img.Image? _processedImage;
  Uint8List? _processedBytes;
  final List<BluetoothDevice> _devicesList = [];
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxCharacteristic;
  bool _isScanning = false;
  bool _isConnecting = false;
  bool _isSending = false;
  String _statusMessage = "Ready";
  int _transferProgress = 0;
  double _transferSpeed = 0;

  // Crop/transform state for interactive framing
  bool _viewInitialized = false;
  double _viewScale = 1.0; // applied to image
  double _viewRotation = 0.0; // radians
  Offset _viewTranslation = Offset.zero; // translation inside frame
  // Zoom limits (will be refined after image/frame init)
  double _minScale = 0.05;
  double _maxScale = 40.0;
  // Gesture temps
  double _startScale = 1.0;
  double _startRotation = 0.0;
  Offset _startTranslation = Offset.zero;
  Offset _startFocal = Offset.zero;
  double _frameWidth = 0;
  double _frameHeight = 0;
  Offset _frameOrigin = Offset.zero; // top-left of crop frame inside workspace
  bool _verticalFrame = false; // portrait orientation toggle
  
  // For image processing
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  @override
  void dispose() {
    _disconnectDevice();
    super.dispose();
  }

  void _resetView(){
    if(_uiOriginal==null){ return; }
    setState((){
      _viewInitialized = false; // recompute cover scale next build
      _viewRotation = 0.0;
    });
  }

  // Request necessary permissions
  Future<void> _checkPermissions() async {
    if (Platform.isAndroid) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.location,
        Permission.storage,
      ].request();
      
      bool allGranted = true;
      statuses.forEach((permission, status) {
        if (!status.isGranted) {
          allGranted = false;
        }
      });
      
      if (!allGranted) {
        _updateStatus("Missing permissions. Please grant Bluetooth and location permissions.");
      }
    }
  }

  // Update the status message
  void _updateStatus(String message) {
    setState(() {
      _statusMessage = message;
    });
  }

  // Pick an image from gallery
  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    
    if (pickedFile != null) {
      setState(() {
        _originalImage = File(pickedFile.path);
        _processedImage = null;
        _processedBytes = null;
        _transferProgress = 0;
        _uiOriginal = null;
        _viewInitialized = false;
      });
      await _loadUiImage();
      
      // Wait for user to adjust then press Process / Send
    }
  }

  Future<void> _loadUiImage() async {
    if (_originalImage == null) return;
    final bytes = await _originalImage!.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    setState(() { _uiOriginal = frame.image; });
  }

  // Process the selected image with current settings
  Future<void> _processImage() async {
    if (_originalImage == null) return;
    
    _updateStatus("Processing image...");
    
    try {
      // Load the original image
      final Uint8List imageBytes = await _originalImage!.readAsBytes();
      img.Image? originalImage = img.decodeImage(imageBytes);
      
      if (originalImage == null) {
        _updateStatus("Failed to decode image");
        return;
      }
      
  // (Enhancements applied within quantization step to avoid double processing)
      
  // Build 800x480 from interactive frame (pan/zoom/rotate) regardless of fit mode toggle
  img.Image resizedImage = _generateCroppedBaseImage(originalImage);
      
      // Convert to 6-color palette with optional dithering and get raw bytes
      Tuple2<img.Image, Uint8List> result = _quantizeTo6ColorAndCreateRawBytes(resizedImage);
      img.Image convertedImage = result.item1;
      Uint8List processedBytes = result.item2;
      
      // Optionally rotate the image data 180 degrees
      if (_rotate180) {
        processedBytes = Uint8List.fromList(processedBytes.reversed.toList());
      }
      
      setState(() {
        _processedImage = convertedImage;
        _processedBytes = processedBytes;
      });
      
      _updateStatus("Image processed successfully (${processedBytes.length} bytes)");
    } catch (e) {
      _updateStatus("Error processing image: $e");
    }
  }

  img.Image _generateCroppedBaseImage(img.Image source) {
    if (_uiOriginal == null || _frameWidth == 0 || _frameHeight == 0) {
      return _fitImage(source);
    }
    final double cosR = math.cos(_viewRotation);
    final double sinR = math.sin(_viewRotation);
    final double invScale = 1.0 / _viewScale;
    final int targetW = _verticalFrame ? IMAGE_HEIGHT : IMAGE_WIDTH; // 480 if vertical
    final int targetH = _verticalFrame ? IMAGE_WIDTH : IMAGE_HEIGHT; // 800 if vertical
    final img.Image working = img.Image(width: targetW, height: targetH, format: img.Format.uint8);
    for (int oy = 0; oy < targetH; oy++) {
      final double wy = _frameOrigin.dy + (oy / targetH) * _frameHeight; // workspace y
      for (int ox = 0; ox < targetW; ox++) {
        final double wx = _frameOrigin.dx + (ox / targetW) * _frameWidth; // workspace x
        double ix = wx - _viewTranslation.dx;
        double iy = wy - _viewTranslation.dy;
        double rx = ix * cosR + iy * sinR;
        double ry = -ix * sinR + iy * cosR;
        double sx = rx * invScale;
        double sy = ry * invScale;
        if (sx < 0 || sy < 0 || sx >= source.width - 1 || sy >= source.height - 1) {
          working.setPixelRgba(ox, oy, 255, 255, 255, 255);
          continue;
        }
        final int x0 = sx.floor();
        final int y0 = sy.floor();
        final int x1 = x0 + 1;
        final int y1 = y0 + 1;
        final double tx = sx - x0;
        final double ty = sy - y0;
        final p00 = source.getPixel(x0, y0);
        final p10 = source.getPixel(x1, y0);
        final p01 = source.getPixel(x0, y1);
        final p11 = source.getPixel(x1, y1);
        int lerp(num a, num b, double t) => (a + (b - a) * t).round();
        final r0 = lerp(p00.r, p10.r, tx); final g0 = lerp(p00.g, p10.g, tx); final b0 = lerp(p00.b, p10.b, tx);
        final r1 = lerp(p01.r, p11.r, tx); final g1 = lerp(p01.g, p11.g, tx); final b1 = lerp(p01.b, p11.b, tx);
        final r = lerp(r0, r1, ty); final g = lerp(g0, g1, ty); final b = lerp(b0, b1, ty);
        working.setPixelRgba(ox, oy, r, g, b, 255);
      }
    }
    if (_verticalFrame) {
      return img.copyRotate(working, angle: 90);
    }
    return working;
  }

  // Apply image enhancements (brightness, contrast, saturation)
  img.Image _enhanceImage(img.Image original) {
    img.Image result = original.clone();
    
    // Apply brightness adjustment first, like in the Python version
    if (_brightness != 1.0) {
      double factor = _brightness;
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
    if (_contrast != 1.0) {
      double factor = _contrast;
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
    
    // Apply saturation adjustment (simplified but effective version)
    if (_saturation != 1.0) {
      double factor = _saturation;
      for (int y = 0; y < result.height; y++) {
        for (int x = 0; x < result.width; x++) {
          var pixel = result.getPixel(x, y);
          
          // Convert to HSL-like space
          double r = pixel.r / 255.0;
          double g = pixel.g / 255.0;
          double b = pixel.b / 255.0;
          
          double max = math.max(r, math.max(g, b));
          double min = math.min(r, math.min(g, b));
          double lum = (max + min) / 2;
          double sat = (max == min) ? 0 : 
                      (lum <= 0.5) ? (max - min) / (max + min) : 
                                     (max - min) / (2.0 - max - min);
          
          // Adjust saturation
          sat = math.min(1.0, sat * factor);
          
          // If it's a grayscale pixel, leave it alone
          if (max == min) {
            continue; // No change for grayscale pixels
          }
          
          // For colored pixels, adjust the saturation
          // This is a simplified version that works by moving RGB values 
          // closer to or further from the luminance value
          double adjustmentFactor = factor - 1.0;
          
          double newR = r + adjustmentFactor * (r - lum);
          double newG = g + adjustmentFactor * (g - lum);
          double newB = b + adjustmentFactor * (b - lum);
          
          // Clamp values
          newR = math.max(0.0, math.min(1.0, newR));
          newG = math.max(0.0, math.min(1.0, newG));
          newB = math.max(0.0, math.min(1.0, newB));
          
          // Set new RGB values
          result.setPixelRgb(x, y, 
            (newR * 255).round(), 
            (newG * 255).round(), 
            (newB * 255).round()
          );
        }
      }
    }
    
    // Apply color boosting to better match hardware palette
    // This helps ensure colors will map correctly to the 6-color palette
    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        var pixel = result.getPixel(x, y);
        int r = pixel.r.toInt();
        int g = pixel.g.toInt();
        int b = pixel.b.toInt();
        
        // Boost yellow detection
        if (r > 200 && g > 200 && b < 100) {
          result.setPixelRgb(x, y, 255, 255, 0); // Pure yellow
        }
        
        // Boost red detection
        if (r > 200 && g < 100 && b < 100) {
          result.setPixelRgb(x, y, 210, 0, 0); // Match hardware red
        }
        
        // Boost blue detection
        if (r < 100 && g < 100 && b > 200) {
          result.setPixelRgb(x, y, 0, 0, 180); // Match hardware blue
        }
        
        // Boost green detection
        if (r < 100 && g > 150 && b < 100) {
          result.setPixelRgb(x, y, 0, 150, 0); // Match hardware green
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
      format: img.Format.uint8,
    );
    
    // Fill with white
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    
    // Paste the resized image in the center
    int offsetX = (IMAGE_WIDTH - newWidth) ~/ 2;
    int offsetY = (IMAGE_HEIGHT - newHeight) ~/ 2;
    
    img.compositeImage(canvas, resized, dstX: offsetX, dstY: offsetY);
    
    return canvas;
  }

  // Quantize to 6-color palette with manual nearest-color + optional Floyd–Steinberg dithering
  Tuple2<img.Image, Uint8List> _quantizeTo6ColorAndCreateRawBytes(img.Image image) {
    // Apply enhancements once (Python enhances inside its quantize function)
    final img.Image enhanced = _enhanceImage(image.clone());
    final int w = enhanced.width;
    final int h = enhanced.height;

    // Working buffer (r,g,b doubles) for dithering adjustments
    final List<double> work = List<double>.filled(w * h * 3, 0.0, growable: false);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = enhanced.getPixel(x, y);
        final int base = (y * w + x) * 3;
        work[base] = p.r.toDouble();
        work[base + 1] = p.g.toDouble();
        work[base + 2] = p.b.toDouble();
      }
    }

    final List<int> codes = hwPalette.map((c) => c.code).toList();
    final List<List<int>> palette = hwPalette
        .map((m) => [m.rgbColor.red, m.rgbColor.green, m.rgbColor.blue])
        .toList(growable: false);

    final Uint8List rawCodes = Uint8List(w * h);
    final img.Image displayImage = img.Image(width: w, height: h, format: img.Format.uint8);

    // Floyd–Steinberg weights
    const double w1 = 7 / 16, w2 = 3 / 16, w3 = 5 / 16, w4 = 1 / 16;
    final bool useDither = _useDithering;

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int base = (y * w + x) * 3;
        double r = work[base];
        double g = work[base + 1];
        double b = work[base + 2];

        r = r.clamp(0.0, 255.0);
        g = g.clamp(0.0, 255.0);
        b = b.clamp(0.0, 255.0);

        int bestIdx = 0;
        double bestDist = double.infinity;
        for (int i = 0; i < palette.length; i++) {
          final pr = palette[i][0].toDouble();
          final pg = palette[i][1].toDouble();
          final pb = palette[i][2].toDouble();
          final double dr = pr - r;
          final double dg = pg - g;
          final double db = pb - b;
          final double dist = dr * dr + dg * dg + db * db;
          if (dist < bestDist) {
            bestDist = dist;
            bestIdx = i;
          }
        }

        final int nr = palette[bestIdx][0];
        final int ng = palette[bestIdx][1];
        final int nb = palette[bestIdx][2];

        final int pixelIndex = y * w + x;
        rawCodes[pixelIndex] = codes[bestIdx];
        displayImage.setPixelRgb(x, y, nr, ng, nb);

        if (useDither) {
          final double errR = r - nr;
          final double errG = g - ng;
          final double errB = b - nb;
          void addErr(int tx, int ty, double f) {
            if (tx < 0 || tx >= w || ty < 0 || ty >= h) return;
            final int tb = (ty * w + tx) * 3;
            work[tb] += errR * f;
            work[tb + 1] += errG * f;
            work[tb + 2] += errB * f;
          }
          addErr(x + 1, y, w1);
          addErr(x - 1, y + 1, w2);
            addErr(x, y + 1, w3);
          addErr(x + 1, y + 1, w4);
        }
      }
    }

    return Tuple2(displayImage, rawCodes);
  }

  // Create raw bytes for BLE transfer - map pixels to palette codes
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

  // Start BLE device scan
  Future<void> _scanForDevices() async {
    if (_isScanning) return;
    
    setState(() {
      _devicesList.clear();
      _isScanning = true;
    });
    
    _updateStatus("Scanning for BLE devices...");
    
    try {
      // Check if Bluetooth is on
      if (!(await FlutterBluePlus.isOn)) {
        _updateStatus("Bluetooth is turned off");
        setState(() {
          _isScanning = false;
        });
        return;
      }
      
      // Start scanning
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      
      // Listen for scan results
      FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.advName.isNotEmpty && !_devicesList.contains(result.device)) {
            setState(() {
              _devicesList.add(result.device);
            });
          }
        }
      }, onError: (e) {
        _updateStatus("Scan error: $e");
      });
      
      // When scan completes
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      
      setState(() {
        _isScanning = false;
      });
      
      if (_devicesList.isEmpty) {
        _updateStatus("No BLE devices found");
      } else {
        _updateStatus("Found ${_devicesList.length} BLE devices");
      }
    } catch (e) {
      _updateStatus("Error scanning: $e");
      setState(() {
        _isScanning = false;
      });
    }
  }

  // Connect to a selected device
  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting) return;
    
    setState(() {
      _isConnecting = true;
    });
    
    _updateStatus("Connecting to ${device.advName}...");
    
    try {
      // Connect to the device
      await device.connect();
      
      // Request MTU increase - this might allow larger data chunks on supported devices
      try {
        await device.requestMtu(512);
        _updateStatus("Requested larger MTU size");
      } catch (e) {
        _updateStatus("Could not negotiate MTU: $e");
        // Continue anyway with smaller chunks
      }
      
      // Discover services
      _updateStatus("Discovering services...");
      List<BluetoothService> services = await device.discoverServices();
      
      // Find our UART service
      BluetoothService? uartService;
      BluetoothCharacteristic? rxChar;
      BluetoothCharacteristic? txChar;
      
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() == UART_SERVICE_UUID.toUpperCase()) {
          uartService = service;
          
          // Find our characteristics
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() == UART_RX_CHAR_UUID.toUpperCase()) {
              rxChar = characteristic;
            } else if (characteristic.uuid.toString().toUpperCase() == UART_TX_CHAR_UUID.toUpperCase()) {
              txChar = characteristic;
            }
          }
          break;
        }
      }
      
      if (uartService == null || rxChar == null || txChar == null) {
        throw Exception("Required UART service or characteristics not found");
      }
      
      // Set up notification handler for TX characteristic
      await txChar.setNotifyValue(true);
      txChar.onValueReceived.listen(_handleNotification);
      
      setState(() {
        _connectedDevice = device;
        _rxCharacteristic = rxChar;
        _isConnecting = false;
      });
      
      _updateStatus("Connected to ${device.advName}");
    } catch (e) {
      _updateStatus("Connection failed: $e");
      setState(() {
        _isConnecting = false;
      });
    }
  }

  // Disconnect from device
  Future<void> _disconnectDevice() async {
    if (_connectedDevice == null) return;
    
    try {
      await _connectedDevice!.disconnect();
      setState(() {
        _connectedDevice = null;
        _rxCharacteristic = null;
      });
      _updateStatus("Disconnected");
    } catch (e) {
      _updateStatus("Error disconnecting: $e");
    }
  }

  // Handle notifications from the device
  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    
    // Parse the acknowledgment type
    int ackType = data[0];
    
    switch (ackType) {
      case ACK_SIZE_RECEIVED:
        _updateStatus("Size received by device");
        break;
        
      case ACK_PROGRESS:
        if (data.length >= 2) {
          int progress = data[1];
          setState(() {
            _transferProgress = progress;
          });
          _updateStatus("Transfer progress: $progress%");
        }
        break;
        
      case ACK_COMPLETE:
        setState(() {
          _isSending = false;
          _transferProgress = 100;
        });
        _updateStatus("Transfer completed successfully");
        break;
        
      case ACK_ERROR:
        setState(() {
          _isSending = false;
        });
        _updateStatus("Error reported by device");
        break;
        
      default:
        _updateStatus("Unknown acknowledgment type: $ackType");
    }
  }

  // Send the processed image to the connected device
  Future<void> _sendImageData() async {
    if (_connectedDevice == null || _rxCharacteristic == null || _processedBytes == null || _isSending) {
      return;
    }
    
    setState(() {
      _isSending = true;
      _transferProgress = 0;
      _transferSpeed = 0;
    });
    
    try {
      _updateStatus("Preparing image data...");
      
      // Pack the pixels to reduce transfer size
      Uint8List packedData = _packPixels(_processedBytes!);
      _updateStatus("Packed data size: ${packedData.length} bytes");
      
      // First send the total size as a 4-byte value
      int totalSize = packedData.length;
      Uint8List sizeBytes = Uint8List(4);
      sizeBytes[0] = totalSize & 0xFF;
      sizeBytes[1] = (totalSize >> 8) & 0xFF;
      sizeBytes[2] = (totalSize >> 16) & 0xFF;
      sizeBytes[3] = (totalSize >> 24) & 0xFF;
      
      // Send the size
      await _rxCharacteristic!.write(sizeBytes);
      _updateStatus("Sent size: $totalSize bytes");
      
      // Small delay to ensure Arduino processes the size
      await Future.delayed(const Duration(milliseconds: 50));
      
      // Start the transfer timer
      int startTime = DateTime.now().millisecondsSinceEpoch;
      int bytesSent = 0;
      
      // Split data into chunks and send
      List<Uint8List> chunks = [];
      for (int i = 0; i < packedData.length; i += BLE_CHUNK_SIZE) {
        int end = math.min(i + BLE_CHUNK_SIZE, packedData.length);
        chunks.add(Uint8List.fromList(packedData.sublist(i, end)));
      }
      
      _updateStatus("Sending ${chunks.length} chunks...");
      
      for (int i = 0; i < chunks.length; i++) {
        // Only show status updates occasionally to reduce overhead
        if (i % 20 == 0 || i == chunks.length - 1) {
          _updateStatus("Sending chunk ${i+1}/${chunks.length}");
        }
        
        try {
          // Use write without any optional parameters
          await _rxCharacteristic!.write(chunks[i]);
          bytesSent += chunks[i].length;
          
          // Small delay between chunks to prevent overwhelming the device
          await Future.delayed(const Duration(milliseconds: 10));
        } catch (e) {
          _updateStatus("Error sending chunk ${i+1}: $e");
          // Try again with a smaller chunk if possible
          if (chunks[i].length > 100) {
            _updateStatus("Retrying with smaller chunk...");
            try {
              // Split the problematic chunk in half and try again
              int halfSize = chunks[i].length ~/ 2;
              await _rxCharacteristic!.write(chunks[i].sublist(0, halfSize));
              await Future.delayed(const Duration(milliseconds: 20));
              await _rxCharacteristic!.write(chunks[i].sublist(halfSize));
              bytesSent += chunks[i].length;
            } catch (retryError) {
              _updateStatus("Retry failed: $retryError");
              // If this fails too, we should abort to prevent more errors
              throw Exception("BLE data transfer failed after retry");
            }
          } else {
            // The chunk is already small, just propagate the error
            rethrow;
          }
        }
        
        // Calculate and update progress
        int progress = (bytesSent * 100 ~/ totalSize);
        int currentTime = DateTime.now().millisecondsSinceEpoch;
        int elapsedTime = currentTime - startTime;
        
        if (elapsedTime > 0) {
          double speedKBps = (bytesSent / 1024) / (elapsedTime / 1000);
          
          setState(() {
            _transferProgress = progress;
            _transferSpeed = speedKBps;
          });
          
          // Only update detailed status every 10%
          if (progress % 10 == 0 || progress == 100) {
            _updateStatus("Progress: $progress% - Speed: ${speedKBps.toStringAsFixed(2)} KB/s");
          }
        }
      }
      
      // Final transfer statistics
      int endTime = DateTime.now().millisecondsSinceEpoch;
      double totalTime = (endTime - startTime) / 1000;
      double avgSpeed = (totalSize / 1024) / totalTime;
      
      _updateStatus("Data transfer complete: $totalSize bytes in ${totalTime.toStringAsFixed(2)} seconds");
      _updateStatus("Average speed: ${avgSpeed.toStringAsFixed(2)} KB/s");
      
      // We don't set _isSending to false here - wait for ACK_COMPLETE
    } catch (e) {
      _updateStatus("Error sending data: $e");
      setState(() {
        _isSending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EPaper Image Sender'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_connectedDevice == null) ...[
                Text('BLE Control', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _isScanning ? null : _scanForDevices,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: Text(_isScanning ? 'Scanning...' : 'Scan for BLE Devices'),
                ),
                const SizedBox(height: 8),
                if (_devicesList.isNotEmpty)
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView.builder(
                      itemCount: _devicesList.length,
                      itemBuilder: (context, index) {
                        final d = _devicesList[index];
                        return ListTile(
                          title: Text(d.advName.isEmpty ? '(Unnamed)' : d.advName),
                          subtitle: Text(d.remoteId.str),
                          trailing: const Icon(Icons.bluetooth),
                          onTap: _isConnecting ? null : () => _connectToDevice(d),
                        );
                      },
                    ),
                  ),
                if (_isConnecting) const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: LinearProgressIndicator(),
                ),
                const SizedBox(height: 16),
                _statusCard(),
              ] else ...[
                // Connected: show image workflow
                Row(children:[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Select Image Please'),
                    ),
                  ),
                  const SizedBox(width:8),
                  ElevatedButton.icon(
                    onPressed: _disconnectDevice,
                    icon: const Icon(Icons.bluetooth_disabled),
                    label: Text('Disconnect ${_connectedDevice!.advName}'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                  ),
                ]),
                const SizedBox(height: 12),
                if (_originalImage != null) _buildCropFrame(),
                const SizedBox(height: 12),
                if (_originalImage != null) Row(children:[
                  ElevatedButton(
                    onPressed: (){ setState((){ _verticalFrame = !_verticalFrame; _viewInitialized = false; }); },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _verticalFrame ? Colors.deepPurple : null,
                      foregroundColor: _verticalFrame ? Colors.white : null,
                    ),
                    child: Text(_verticalFrame ? 'Vertical ✓' : 'Vertical'),
                  ),
                  const SizedBox(width:8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _processImage,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Process Image'),
                    ),
                  ),
                  const SizedBox(width:8),
                  if (_processedBytes != null)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isSending ? null : _sendImageData,
                        icon: const Icon(Icons.send),
                        label: Text(_isSending ? 'Sending...' : 'Send To Device'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                      ),
                    ),
                ]),
                const SizedBox(height: 12),
                if (_originalImage != null || _processedImage != null)
                  Container(
                    height: 200,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(children:[
                      if (_originalImage != null) Expanded(child: Column(children:[const Text('Original'), Expanded(child: Image.file(_originalImage!, fit: BoxFit.contain))])),
                      if (_originalImage != null && _processedImage != null) const VerticalDivider(),
                      if (_processedImage != null) Expanded(child: Column(children:[const Text('Processed'), Expanded(child: Image.memory(Uint8List.fromList(img.encodePng(_processedImage!)), fit: BoxFit.contain))])),
                    ]),
                  ),
                if (_isSending) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: _transferProgress/100),
                  Text('${_transferProgress}% - ${_transferSpeed.toStringAsFixed(2)} KB/s'),
                ],
                const SizedBox(height: 12),
                _statusCard(),
              ]
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard() => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.grey[200],
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Status', style: Theme.of(context).textTheme.titleMedium),
        Text(_statusMessage),
      ],
    ),
  );

  Widget _buildCropFrame() {
    return SizedBox(
      height: 320, // workspace height
      child: LayoutBuilder(builder: (context, constraints) {
        final workspaceW = constraints.maxWidth;
        final workspaceH = constraints.maxHeight;
        // Base frame width half of available
        _frameWidth = workspaceW * 0.5;
        if (_verticalFrame) {
          _frameHeight = _frameWidth * (IMAGE_WIDTH / IMAGE_HEIGHT); // portrait 800/480
        } else {
          _frameHeight = _frameWidth * (IMAGE_HEIGHT / IMAGE_WIDTH); // landscape 480/800
        }
        if (_frameHeight > workspaceH) {
          _frameHeight = workspaceH * 0.5; // fallback based on height
          if (_verticalFrame) {
            _frameWidth = _frameHeight * (IMAGE_HEIGHT / IMAGE_WIDTH);
          } else {
            _frameWidth = _frameHeight * (IMAGE_WIDTH / IMAGE_HEIGHT);
          }
        }
        _frameOrigin = Offset(
          (workspaceW - _frameWidth)/2,
          (workspaceH - _frameHeight)/2,
        );
        if (!_viewInitialized && _uiOriginal != null) {
          final iw = _uiOriginal!.width.toDouble();
          final ih = _uiOriginal!.height.toDouble();
          // scale so image fully covers frame
          final coverScale = math.max(_frameWidth / iw, _frameHeight / ih);
          _viewScale = coverScale;
          // Allow zooming out to a small fraction of cover, in, to large magnification
          _minScale = coverScale * 0.01; // 1% of cover size (very far zoom out)
          if (_minScale < 0.005) _minScale = 0.005;
          _maxScale = coverScale * 80; // very deep zoom possible
          // center image in workspace
          _viewTranslation = Offset(
            (workspaceW - iw*coverScale)/2,
            (workspaceH - ih*coverScale)/2,
          );
          _viewInitialized = true;
        }
        return GestureDetector(
          onDoubleTap: _resetView,
          onScaleStart: (d){
            _startScale = _viewScale; _startRotation = _viewRotation; _startTranslation = _viewTranslation; _startFocal = d.focalPoint;},
          onScaleUpdate: (d){
            setState((){
              _viewScale = (_startScale * d.scale).clamp(_minScale, _maxScale);
              _viewRotation = _startRotation + d.rotation;
              _viewTranslation = _startTranslation + (d.focalPoint - _startFocal);
            });
          },
          child: ClipRect(
            child: Stack(children:[
              // Image (clipped to workspace bounds now)
              CustomPaint(
                size: Size(workspaceW, workspaceH),
                painter: _WorkspacePainter(
                  image: _uiOriginal,
                  scale: _viewScale,
                  rotation: _viewRotation,
                  translation: _viewTranslation,
                ),
              ),
              // Frame overlay
              Positioned(
                left: _frameOrigin.dx,
                top: _frameOrigin.dy,
                width: _frameWidth,
                height: _frameHeight,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black, width: 3),
                    ),
                  ),
                ),
              ),
              // Zoom controls overlay (top-right)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                        onPressed: (){ setState((){ _viewScale = (_viewScale * 1.25).clamp(_minScale, _maxScale); }); },
                        tooltip: 'Zoom In',
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                        onPressed: (){ setState((){ _viewScale = (_viewScale / 1.25).clamp(_minScale, _maxScale); }); },
                        tooltip: 'Zoom Out',
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                        onPressed: _resetView,
                        tooltip: 'Reset View (also double-tap)',
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        );
      }),
    );
  }
}

class _WorkspacePainter extends CustomPainter {
  final ui.Image? image; final double scale; final double rotation; final Offset translation;
  const _WorkspacePainter({required this.image, required this.scale, required this.rotation, required this.translation});
  @override
  void paint(Canvas canvas, Size size) {
    final img = image; if (img==null) { canvas.drawRect(Offset.zero & size, Paint()..color=Colors.black12); return; }
    canvas.save();
    canvas.translate(translation.dx, translation.dy);
    canvas.rotate(rotation);
    canvas.scale(scale, scale);
    paintImage(canvas: canvas, rect: Rect.fromLTWH(0,0,img.width.toDouble(), img.height.toDouble()), image: img, fit: BoxFit.contain, alignment: Alignment.topLeft);
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _WorkspacePainter old)=> old.image!=image || old.scale!=scale || old.rotation!=rotation || old.translation!=translation;
}

// Helper class for color mapping
class ColorMap {
  final int code;
  final Color rgbColor;
  
  const ColorMap(this.code, this.rgbColor);
}
