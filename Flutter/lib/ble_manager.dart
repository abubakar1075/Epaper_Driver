import 'dart:async';
import 'dart:typed_data';
import 'dart:math';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// Constants for BLE acknowledgements
const int ACK_SIZE_RECEIVED = 0x01;
const int ACK_PROGRESS = 0x02;
const int ACK_COMPLETE = 0x03;
const int ACK_ERROR = 0xFF;
const int ACK_BATTERY = 0xB0; // battery status from device (ignored here)
const int ACK_CHARGING = 0xB1; // charging status from device

// BLE UUIDs - match with Arduino code
const String UART_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
const String UART_RX_CHAR_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // To Arduino
const String UART_TX_CHAR_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // From Arduino

// Transfer parameters
const int BLE_CHUNK_SIZE = 512; // target max; will adapt to MTU at runtime
const int BLE_ACK_THRESHOLD = 200;
const int TRANSFER_TYPE_IMAGE = 0x10; // typed header: image
const int TRANSFER_TYPE_OTA = 0x20;   // typed header: OTA

class BleManager {
  // BLE device and service
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxCharacteristic;
  BluetoothCharacteristic? _txCharacteristic;
  
  // Callbacks
  Function(String message)? onStatusUpdate;
  Function(int progress, double speed)? onProgressUpdate;
  Function()? onTransferComplete;
  Function(String error)? onError;
  
  // Transfer state
  bool _isTransferring = false;
  int _totalSize = 0;
  int _bytesSent = 0;
  int _startTime = 0;
  Timer? _ackTimer;
  static const int _ackTimeoutSeconds = 30; // watchdog to avoid permanent lock
  Completer<void>? _sizeAckCompleter; // completes when device ACKs size/header
  Completer<void>? _completeAckCompleter; // completes on ACK_COMPLETE
  
  // Getters
  BluetoothDevice? get connectedDevice => _device;
  BluetoothCharacteristic? get txCharacteristic => _txCharacteristic;
  bool get isConnected => _device != null && _device!.isConnected;
  bool get isTransferring => _isTransferring;
  
  // Set callbacks
  void setCallbacks({
    Function(String message)? statusCallback,
    Function(int progress, double speed)? progressCallback,
    Function()? completeCallback,
    Function(String error)? errorCallback,
  }) {
    onStatusUpdate = statusCallback;
    onProgressUpdate = progressCallback;
    onTransferComplete = completeCallback;
    onError = errorCallback;
  }
  
  // Scan for BLE devices
  Future<List<BluetoothDevice>> scanForDevices(Duration timeout) async {
    List<BluetoothDevice> devices = [];
    
    try {
      // Check if Bluetooth is on
      var adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _notifyError("Bluetooth is turned off");
        return devices;
      }
      
      // Start scanning
      FlutterBluePlus.startScan(timeout: timeout);
      
      // Listen for scan results
      FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.advName.isNotEmpty && !devices.contains(result.device)) {
            devices.add(result.device);
          }
        }
      }, onError: (e) {
        _notifyError("Scan error: $e");
      });
      
      // Wait for scan to complete
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      
      _notifyStatus("Found ${devices.length} BLE devices");
      return devices;
    } catch (e) {
      _notifyError("Error scanning: $e");
      return devices;
    }
  }
  
  // Connect to a device
  Future<bool> connectToDevice(BluetoothDevice device) async {
    try {
      _notifyStatus("Connecting to ${device.advName}...");
      
      // Connect to the device
      await device.connect();
      
      // Try to negotiate a larger MTU for faster transfers (Android only; iOS ignores)
      try {
        await device.requestMtu(512);
        _notifyStatus("Requested MTU 512");
      } catch (_) {
        // Not supported or failed; we'll adapt chunk size dynamically later
      }

      // Discover services
      _notifyStatus("Discovering services...");
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
      
      // Store the device and service
      _device = device;
      _rxCharacteristic = rxChar;
      _txCharacteristic = txChar;
      
      _notifyStatus("Connected to ${device.advName}");
      return true;
    } catch (e) {
      _notifyError("Connection failed: $e");
      return false;
    }
  }
  
  // Disconnect from device
  Future<void> disconnect() async {
    if (_device == null) return;
    
    try {
      await _device!.disconnect();
      _device = null;
      _rxCharacteristic = null;
      _txCharacteristic = null;
      _notifyStatus("Disconnected");
    } catch (e) {
      _notifyError("Error disconnecting: $e");
    }
  }
  
  // Query firmware version from ESP32
  Future<String?> queryFirmwareVersion() async {
    if (_device == null || !_device!.isConnected || _rxCharacteristic == null) {
      _notifyError("Not connected to a device");
      return null;
    }
    
    try {
      _notifyStatus("Querying firmware version...");
      
      // Create a completer to wait for the version response
      Completer<String?> versionCompleter = Completer<String?>();
      
      // Set up a temporary listener for version response
      late StreamSubscription subscription;
      subscription = _txCharacteristic!.onValueReceived.listen((value) {
        if (value.isNotEmpty && value[0] == 0x30) {
          // Version response received
          String version = String.fromCharCodes(value.sublist(1));
          if (!versionCompleter.isCompleted) {
            versionCompleter.complete(version);
          }
          subscription.cancel();
        }
      });
      
      // Send version query command (0x30)
      await _rxCharacteristic!.write(Uint8List.fromList([0x30]));
      
      // Wait for response with timeout
      String? version = await versionCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          subscription.cancel();
          return null;
        },
      );
      
      if (version != null) {
        _notifyStatus("Firmware version: $version");
        return version.trim();
      } else {
        _notifyError("Version query timeout");
        return null;
      }
    } catch (e) {
      _notifyError("Error querying version: $e");
      return null;
    }
  }
  
  // Send image data to the device
  Future<bool> sendImageData(Uint8List data) async {
    if (_device == null || !_device!.isConnected || _rxCharacteristic == null) {
      _notifyError("Not connected to a device");
      return false;
    }
    
    if (_isTransferring) {
      _notifyError("Transfer already in progress");
      return false;
    }
    
    _isTransferring = true;
    _totalSize = data.length;
    _bytesSent = 0;
    _startTime = DateTime.now().millisecondsSinceEpoch;
    _sizeAckCompleter = Completer<void>();
    _completeAckCompleter = Completer<void>();
    
    try {
      _notifyStatus("Preparing to send ${data.length} bytes...");

      // Build typed header: [type=0x10 image, little-endian size (4 bytes)]
      final header = Uint8List(5);
      header[0] = TRANSFER_TYPE_IMAGE;
      header[1] = _totalSize & 0xFF;
      header[2] = (_totalSize >> 8) & 0xFF;
      header[3] = (_totalSize >> 16) & 0xFF;
      header[4] = (_totalSize >> 24) & 0xFF;

      // Send header WITH response for reliability
      await _rxCharacteristic!.write(header, withoutResponse: false);
      _notifyStatus("Sent header (type 0x10) with size: $_totalSize bytes");

      // Wait for ACK_SIZE_RECEIVED or timeout
      try {
        await _sizeAckCompleter!.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        throw Exception("Timeout waiting for device to ACK size");
      }

      // Try to use a large MTU; if not available, adapt chunk size dynamically
      int negotiatedMtu = 23; // default
      // We can't reliably query current MTU on all platforms via API here; assume desired if no error earlier
      negotiatedMtu = 512; // optimistic; chunk sizing will still be guarded and retried
      int maxPayload = max(20, min(BLE_CHUNK_SIZE, negotiatedMtu - 3));
      
      _notifyStatus("Starting transfer with chunk payload up to $maxPayload bytes");

      // Send data in adaptive chunks with retries and light throttling
      int offset = 0;
      int chunkIndex = 0;
      int throttleCounter = 0;
      while (offset < data.length) {
        final int remaining = data.length - offset;
        int sendLen = min(maxPayload, remaining);

        // Retry strategy for this chunk size
        int attempts = 0;
        while (true) {
          try {
            // Only show status updates occasionally to reduce overhead
            if (chunkIndex % 20 == 0 || (offset + sendLen) >= data.length) {
              final totalChunks = (data.length + maxPayload - 1) ~/ maxPayload;
              _notifyStatus("Sending chunk ${chunkIndex + 1}/$totalChunks (len=$sendLen)");
            }
            await _rxCharacteristic!.write(
              Uint8List.sublistView(data, offset, offset + sendLen),
              withoutResponse: true,
            );
            break; // success
          } catch (e) {
            attempts++;
            // Reduce payload and retry a few times before failing hard
            if (sendLen > 20) {
              sendLen = max(20, sendLen ~/ 2);
            }
            // Also reduce maxPayload so subsequent chunks adapt
            maxPayload = max(20, sendLen);
            if (attempts >= 3) {
              throw Exception("BLE write failed after retries: $e");
            }
            // tiny backoff
            await Future.delayed(const Duration(milliseconds: 10));
            continue;
          }
        }

        offset += sendLen;
        chunkIndex++;
        throttleCounter++;
        _bytesSent += sendLen;
        _updateProgress();

        // Light throttling to avoid flooding some stacks
        if (throttleCounter >= 32) {
          throttleCounter = 0;
          await Future.delayed(const Duration(milliseconds: 2));
        }
      }

      // Wait for completion ACK with watchdog running
      _startAckWatchdog();
      // Optionally await completion to surface errors earlier
      unawaited(() async {
        try {
          await _completeAckCompleter!.future.timeout(Duration(seconds: _ackTimeoutSeconds));
        } catch (_) {
          // handled by watchdog / error callbacks
        }
      }());
      return true;
    } catch (e) {
      _notifyError("Error sending data: $e");
      _isTransferring = false;
      return false;
    }
  }
  
  // Handle notifications from the device
  void _handleNotification(List<int> data) {
    if (data.isEmpty) return;
    
    // Parse the acknowledgment type
    int ackType = data[0];
    
    switch (ackType) {
      case ACK_SIZE_RECEIVED:
        _notifyStatus("Size received by device");
        if (_sizeAckCompleter != null && !_sizeAckCompleter!.isCompleted) {
          _sizeAckCompleter!.complete();
        }
        break;
        
      case ACK_PROGRESS:
        if (data.length >= 2) {
          int progress = data[1];
          _notifyStatus("Device reports progress: $progress%");
          
          if (onProgressUpdate != null) {
            double speed = _calculateSpeed();
            onProgressUpdate!(progress, speed);
          }
        }
        break;
        
      case ACK_COMPLETE:
        _cancelAckWatchdog();
        _isTransferring = false;
        _notifyStatus("Transfer completed successfully");
        if (_completeAckCompleter != null && !_completeAckCompleter!.isCompleted) {
          _completeAckCompleter!.complete();
        }
        
        if (onTransferComplete != null) {
          onTransferComplete!();
        }
  break;
        
      case ACK_ERROR:
        _isTransferring = false;
        _notifyError("Error reported by device");
        if (_completeAckCompleter != null && !_completeAckCompleter!.isCompleted) {
          _completeAckCompleter!.completeError(Exception('Device reported error'));
        }
        break;
        
      default:
        // Some firmware sends human-readable ASCII status messages (e.g. "Touch(15) = 69...")
        // In that case the first byte will be an ASCII character (like 'T' == 84).
        // Try to decode printable ASCII/UTF-8 and surface as status; otherwise log unknown ack.
        try {
          String msg = utf8.decode(data);
          // If decoded string contains printable characters, treat as status
          bool printable = msg.runes.every((r) => (r >= 32 && r <= 126) || r == 10 || r == 13);
          if (printable && msg.trim().isNotEmpty) {
            _notifyStatus(msg.trim());
            break;
          }
        } catch (_) {
          // ignore decode errors
        }
        _notifyStatus("Unknown acknowledgment type: $ackType");
    }
  }

  void _startAckWatchdog() {
    _cancelAckWatchdog();
    _ackTimer = Timer(Duration(seconds: _ackTimeoutSeconds), () {
      if (_isTransferring) {
        _isTransferring = false;
        _notifyStatus('ACK timeout: transfer reset after ${_ackTimeoutSeconds}s');
        _notifyError('No completion ACK received from device');
      }
    });
  }

  void _cancelAckWatchdog() {
    if (_ackTimer != null) {
      _ackTimer!.cancel();
      _ackTimer = null;
    }
  }
  
  // Calculate and update transfer progress
  void _updateProgress() {
    if (_totalSize <= 0) return;
    
    int progress = (_bytesSent * 100) ~/ _totalSize;
    double speed = _calculateSpeed();
    
    if (onProgressUpdate != null) {
      onProgressUpdate!(progress, speed);
    }
  }
  
  // Calculate transfer speed in KB/s
  double _calculateSpeed() {
    int now = DateTime.now().millisecondsSinceEpoch;
    int elapsed = now - _startTime;
    
    if (elapsed <= 0) return 0.0;
    
    return (_bytesSent / 1024) / (elapsed / 1000);
  }
  
  // Helper methods for callbacks
  void _notifyStatus(String message) {
    if (onStatusUpdate != null) {
      onStatusUpdate!(message);
    }
  }
  
  void _notifyError(String error) {
    if (onError != null) {
      onError!(error);
    }
  }
}
