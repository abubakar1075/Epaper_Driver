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

// BLE UUIDs - match with Arduino code
const String UART_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
const String UART_RX_CHAR_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // To Arduino
const String UART_TX_CHAR_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // From Arduino

// Transfer parameters
const int BLE_CHUNK_SIZE = 512;
const int BLE_ACK_THRESHOLD = 200;

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
    
    try {
      _notifyStatus("Preparing to send ${data.length} bytes...");
      
      // First send the total size as a 4-byte value
      Uint8List sizeBytes = Uint8List(4);
      sizeBytes[0] = _totalSize & 0xFF;
      sizeBytes[1] = (_totalSize >> 8) & 0xFF;
      sizeBytes[2] = (_totalSize >> 16) & 0xFF;
      sizeBytes[3] = (_totalSize >> 24) & 0xFF;
      
      // Send the size
      await _rxCharacteristic!.write(sizeBytes);
      _notifyStatus("Sent size: $_totalSize bytes");
      
      // Small delay to ensure Arduino processes the size
      await Future.delayed(const Duration(milliseconds: 50));
      
      // Split data into chunks and send
      List<Uint8List> chunks = [];
      for (int i = 0; i < data.length; i += BLE_CHUNK_SIZE) {
        int end = min(i + BLE_CHUNK_SIZE, data.length);
        chunks.add(Uint8List.fromList(data.sublist(i, end)));
      }
      
      _notifyStatus("Sending ${chunks.length} chunks...");
      
      for (int i = 0; i < chunks.length; i++) {
        // Only show status updates occasionally to reduce overhead
        if (i % 20 == 0 || i == chunks.length - 1) {
          _notifyStatus("Sending chunk ${i+1}/${chunks.length}");
        }
        
        await _rxCharacteristic!.write(chunks[i]);
        _bytesSent += chunks[i].length;
        
        // Calculate and update progress
        _updateProgress();
      }
      
      // We don't set _isTransferring to false here - wait for ACK_COMPLETE
      // Start ACK watchdog: if ACK_COMPLETE isn't received within timeout,
      // clear transfer state so the UI remains responsive.
      _startAckWatchdog();
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
        
        if (onTransferComplete != null) {
          onTransferComplete!();
        }
  break;
        
      case ACK_ERROR:
        _isTransferring = false;
        _notifyError("Error reported by device");
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
