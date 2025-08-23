import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

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

  // Hardware palette for 6-color e-paper display
  static const List<ColorMap> hwPalette = [
    ColorMap(0x00, Color(0xFF000000)), // Black
    ColorMap(0xFF, Color(0xFFFFFFFF)), // White
    ColorMap(0xFC, Color(0xFFFFFF00)), // Yellow
    ColorMap(0xE0, Color(0xFFD20000)), // Red
    ColorMap(0x03, Color(0xFF0000B4)), // Blue (0, 0, 180)
    ColorMap(0x1C, Color(0xFF009600)), // Green (0, 150, 0)
  ];
  
  // Image processing options
  bool _useFitMode = true;
  bool _useDithering = true;
  double _brightness = 1.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  bool _rotate180 = true;

  // UI State
  File? _originalImage;
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
      });
      
      // Process the image
      _processImage();
    }
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
      
      // Apply brightness, contrast, saturation adjustments
      originalImage = _enhanceImage(originalImage);
      
      // Resize the image according to the fit mode
      img.Image resizedImage;
      if (_useFitMode) {
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

  // Quantize to the 6-color palette
  img.Image _quantizeTo6Colors(img.Image image) {
    // Apply brightness, contrast, saturation adjustments first
    img.Image processed = _enhanceImage(image.clone());
    
    // Create a palette with our 6 specific colors
    final palette = <int>[];
    for (var mapping in hwPalette) {
      final c = mapping.rgbColor;
      palette.addAll([c.red, c.green, c.blue]);
    }
    
    // Add extra padding to fill the palette size to 256 entries (required by image library)
    while (palette.length < 256 * 3) {
      palette.addAll([0, 0, 0]);
    }
    
    // Use quantize with the created palette and the proper dithering setting
    var dithering = _useDithering 
        ? img.DitherKernel.floydSteinberg
        : img.DitherKernel.none;
    
    return img.quantize(
      processed,
      numberOfColors: hwPalette.length,
      method: img.QuantizeMethod.octree,  // Use octree as Flutter doesn't have median cut
      dither: dithering
    );
  }

  // Create raw bytes for BLE transfer - map pixels to palette codes
  Uint8List _createRawBytes(img.Image image) {
    final int pixelCount = image.width * image.height;
    final Uint8List result = Uint8List(pixelCount);
    
    // Map of colors to palette codes
    final Map<int, int> colorToCodeMap = {};
    for (var mapping in hwPalette) {
      final c = mapping.rgbColor;
      // Create a color key based on RGB values (format varies by platform)
      int colorKey = (c.red << 16) | (c.green << 8) | c.blue;
      colorToCodeMap[colorKey] = mapping.code;
    }
    
    // Map each pixel to the closest palette color
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final img.Pixel pixel = image.getPixel(x, y);
        final int r = pixel.r.toInt();
        final int g = pixel.g.toInt();
        final int b = pixel.b.toInt();
        
        // Find the closest color in our hardware palette
        int closestColorIndex = 0;
        double minDistance = double.infinity;
        
        for (int i = 0; i < hwPalette.length; i++) {
          final Color c = hwPalette[i].rgbColor;
          final double dr = (c.red - r).toDouble();
          final double dg = (c.green - g).toDouble();
          final double db = (c.blue - b).toDouble();
          final double distance = dr * dr + dg * dg + db * db;
          
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
              // Image preview section
              Text('Image', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _pickImage,
                      icon: const Icon(Icons.photo_library),
                      label: const Text('Select Image'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_originalImage != null)
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _processImage,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Process Image'),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              
              // Image preview
              if (_originalImage != null || _processedImage != null)
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      // Original image
                      if (_originalImage != null)
                        Expanded(
                          child: Column(
                            children: [
                              const Text('Original'),
                              Expanded(
                                child: Image.file(
                                  _originalImage!,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ],
                          ),
                        ),
                      
                      // Vertical divider
                      if (_originalImage != null && _processedImage != null)
                        const VerticalDivider(),
                      
                      // Processed image
                      if (_processedImage != null)
                        Expanded(
                          child: Column(
                            children: [
                              const Text('Processed'),
                              Expanded(
                                child: Image.memory(
                                  Uint8List.fromList(img.encodePng(_processedImage!)),
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              
              // Image processing options
              if (_originalImage != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Image Settings', style: Theme.of(context).textTheme.titleMedium),
                        
                        // Fit mode
                        Row(
                          children: [
                            const Text('Resize Mode:'),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Fit'),
                              selected: _useFitMode,
                              onSelected: (selected) {
                                setState(() {
                                  _useFitMode = selected;
                                });
                                _processImage();
                              },
                            ),
                            const SizedBox(width: 8),
                            ChoiceChip(
                              label: const Text('Stretch'),
                              selected: !_useFitMode,
                              onSelected: (selected) {
                                setState(() {
                                  _useFitMode = !selected;
                                });
                                _processImage();
                              },
                            ),
                          ],
                        ),
                        
                        // Dithering
                        Row(
                          children: [
                            const Text('Dithering:'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _useDithering,
                              onChanged: (value) {
                                setState(() {
                                  _useDithering = value;
                                });
                                _processImage();
                              },
                            ),
                          ],
                        ),
                        
                        // Brightness slider
                        Row(
                          children: [
                            const Text('Brightness:'),
                            Expanded(
                              child: Slider(
                                value: _brightness,
                                min: 0.5,
                                max: 1.5,
                                divisions: 10,
                                label: _brightness.toStringAsFixed(1),
                                onChanged: (value) {
                                  setState(() {
                                    _brightness = value;
                                  });
                                },
                                onChangeEnd: (value) {
                                  _processImage();
                                },
                              ),
                            ),
                          ],
                        ),
                        
                        // Contrast slider
                        Row(
                          children: [
                            const Text('Contrast:'),
                            Expanded(
                              child: Slider(
                                value: _contrast,
                                min: 0.5,
                                max: 1.5,
                                divisions: 10,
                                label: _contrast.toStringAsFixed(1),
                                onChanged: (value) {
                                  setState(() {
                                    _contrast = value;
                                  });
                                },
                                onChangeEnd: (value) {
                                  _processImage();
                                },
                              ),
                            ),
                          ],
                        ),
                        
                        // Saturation slider
                        Row(
                          children: [
                            const Text('Saturation:'),
                            Expanded(
                              child: Slider(
                                value: _saturation,
                                min: 0.5,
                                max: 1.5,
                                divisions: 10,
                                label: _saturation.toStringAsFixed(1),
                                onChanged: (value) {
                                  setState(() {
                                    _saturation = value;
                                  });
                                },
                                onChangeEnd: (value) {
                                  _processImage();
                                },
                              ),
                            ),
                          ],
                        ),
                        
                        // Rotation
                        Row(
                          children: [
                            const Text('Rotate 180°:'),
                            const SizedBox(width: 8),
                            Switch(
                              value: _rotate180,
                              onChanged: (value) {
                                setState(() {
                                  _rotate180 = value;
                                });
                                _processImage();
                              },
                            ),
                          ],
                        ),
                        
                        // Reset button
                        ElevatedButton(
                          onPressed: () {
                            setState(() {
                              _brightness = 1.0;
                              _contrast = 1.0;
                              _saturation = 1.0;
                              _useFitMode = true;
                              _useDithering = true;
                              _rotate180 = true;
                            });
                            _processImage();
                          },
                          child: const Text('Reset Settings'),
                        ),
                      ],
                    ),
                  ),
                ),
              
              const SizedBox(height: 16),
              
              // BLE section
              Text('BLE Control', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              
              // Scan button
              ElevatedButton.icon(
                onPressed: _isScanning ? null : _scanForDevices,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(_isScanning ? 'Scanning...' : 'Scan for BLE Devices'),
              ),
              const SizedBox(height: 8),
              
              // Device list
              if (_devicesList.isNotEmpty)
                Container(
                  height: 150,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    itemCount: _devicesList.length,
                    itemBuilder: (context, index) {
                      final device = _devicesList[index];
                      final bool isConnected = _connectedDevice?.remoteId == device.remoteId;
                      
                      return ListTile(
                        title: Text(device.advName),
                        subtitle: Text(device.remoteId.str),
                        trailing: isConnected
                            ? const Icon(Icons.bluetooth_connected, color: Colors.green)
                            : const Icon(Icons.bluetooth, color: Colors.blue),
                        onTap: isConnected || _isConnecting ? null : () => _connectToDevice(device),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
              
              // Connect/Disconnect button
              if (_connectedDevice != null)
                ElevatedButton.icon(
                  onPressed: _disconnectDevice,
                  icon: const Icon(Icons.bluetooth_disabled),
                  label: Text('Disconnect from ${_connectedDevice!.advName}'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                ),
              
              const SizedBox(height: 16),
              
              // Send button
              if (_connectedDevice != null && _processedBytes != null)
                ElevatedButton.icon(
                  onPressed: _isSending ? null : _sendImageData,
                  icon: const Icon(Icons.send),
                  label: Text(_isSending ? 'Sending...' : 'Send Image to Device'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
              
              // Progress bar
              if (_isSending)
                Column(
                  children: [
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _transferProgress / 100),
                    Text('$_transferProgress% - ${_transferSpeed.toStringAsFixed(2)} KB/s'),
                  ],
                ),
              
              const SizedBox(height: 16),
              
              // Status section
              Container(
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Helper class for color mapping
class ColorMap {
  final int code;
  final Color rgbColor;
  
  const ColorMap(this.code, this.rgbColor);
}
