// =============================================================
// EPaper Image Sender (Single-File Learning Version)
// -------------------------------------------------------------
// Features:
// 1. Scan + auto-connect to BLE device (name starts with "EPD").
// 2. Pick an image from gallery.
// 3. Pan / Zoom / Rotate to frame the exact display region (800x480).
// 4. Convert to 6-color hardware palette with optional dithering.
// 5. Process image on demand before sending.
// 6. Save processed images to an in-memory library & resend later.
// 7. Send image over BLE in chunks with progress + speed.
// -------------------------------------------------------------
// Everything is kept here (instead of splitting into many files)
// so a beginner can scroll and read sequentially.
// Look for SECTION headers to navigate.
// =============================================================
//After OTA
import 'dart:async';          // async helpers
import 'dart:io';             // File access for picked images
import 'dart:typed_data';     // Uint8List for raw buffers
import 'dart:convert';        // json encode/decode for library index
import 'dart:ui' as ui;       // Image decoding for CustomPaint
import 'dart:math' as math;   // Trig for rotation + min/max
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tuple/tuple.dart';
import 'package:path_provider/path_provider.dart'; // persistent storage dir
import 'package:http/http.dart' as http;

// Tracks which action the user intended when tapping while disconnected
enum _PendingSend { none, image, ota }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Force the whole app to stay in portrait mode (device rotations won't trigger landscape layouts)
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
  title: 'CanvasBT',
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
  // =============================================================
  // CONSTANTS / STATIC CONFIG
  // =============================================================
  static const int IMAGE_WIDTH = 800;
  static const int IMAGE_HEIGHT = 480;
  static const int BLE_CHUNK_SIZE = 480; // High-speed: near-MTU chunking for faster throughput

  // BLE UUIDs - match with Arduino code
  static const String UART_SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String UART_RX_CHAR_UUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // To Arduino
  static const String UART_TX_CHAR_UUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // From Arduino

  // Acknowledgment types
  static const int ACK_SIZE_RECEIVED = 0x01;
  static const int ACK_PROGRESS = 0x02;
  static const int ACK_COMPLETE = 0x03;
  static const int ACK_ERROR = 0xFF;
  static const int ACK_BATTERY = 0xB0; // Battery percentage notification
  // Transfer-type header values (1 byte)
  static const int TRANSFER_TYPE_IMAGE = 0x10;
  static const int TRANSFER_TYPE_OTA   = 0x20;

  // Hardware palette for 6-color e-paper display - exact RGB values from Python script
  static const List<ColorMap> hwPalette = [
    ColorMap(0x00, Color.fromRGBO(0, 0, 0, 1)),       // Black
    ColorMap(0xFF, Color.fromRGBO(255, 255, 255, 1)), // White
    ColorMap(0xFC, Color.fromRGBO(255, 255, 0, 1)),   // Yellow (255, 255, 0)
    ColorMap(0xE0, Color.fromRGBO(210, 0, 0, 1)),     // Red (210, 0, 0)
    ColorMap(0x03, Color.fromRGBO(0, 0, 180, 1)),     // Blue (0, 0, 180)
    ColorMap(0x1C, Color.fromRGBO(0, 150, 0, 1)),     // Green (0, 150, 0)
  ];
  
  // Image enhancement (values are derived from the single "Color" slider)
  double _brightness = 1.0;
  double _contrast = 1.0;
  double _saturation = 1.0;

  // =============================================================
  // HIGH-LEVEL STATE (image, BLE, processing, library, UI modes)
  // =============================================================
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
  bool _autoConnectTried = false; // ensure single auto-connect attempt per scan
  bool _mtuRequestedForThisConnection = false; // guard to avoid repeated MTU requests per connection
  int? _batteryPercent; // latest battery percent from device
  // Periodic connection status for bottom bar
  Timer? _connectionStatusTimer;
  String _connectionStatusText = 'Not connected';
  // Stay on the second screen even if temporarily disconnected (for background auto-reconnect)
  // First window removed; app always starts on connected UI.
  // Header/logo asset (FramePic/CanvasBT.*) to show in the AppBar
  String? _headerAsset;
  double? _headerAspectRatio; // width / height for dynamic AppBar height

  // =============================================================
  // INTERACTIVE FRAMING (user gestures manipulate these)
  // =============================================================
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
  // Slider-driven tuning
  final double _ditherStrength = 1.0; // 0=off .. 1=full
  final double _strongColorBoost = 1.0; // influences brightness/contrast/saturation mapping (default max)

  // =============================================================
  // IN-MEMORY LIBRARY (session only)
  // =============================================================
  final List<_LibraryEntry> _library = [];
  int? _selectedLibraryIndex; // selected index in library view
  bool _showLibrary = false; // toggle to show library screen when connected
  bool _showOnline = false; // toggle to show online images screen when connected
  Future<List<String>>? _onlineImagesFuture; // cached future for online images
  String? _selectedOnlineImageUrl; // selected online image URL
  bool _isLoadingOnlineImage = false; // loading state for Use in Editor
  Uint8List? _processedPngBytes; // cache processed PNG
  Directory? _libraryDir; // persistent directory
  DateTime _lastStatusUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  // Manual processing triggered by user actions
  int _processGen = 0; // increments each processing request
  // removed _processing boolean; we now process on-demand before send without UI spinner

  // =============================================================
  // UI HELPERS
  // =============================================================
  // Simple on-device "AI Images" generator (prompt -> synthesized PNG)
  bool _showAi = false;
  final TextEditingController _aiPromptController = TextEditingController(text: 'A cozy cabin in snowy mountains at sunset');
  bool _aiIsGenerating = false;
  Uint8List? _aiPngBytes;
  String? _aiError;
  // Auto-send support: when user taps Send while disconnected and the popup is visible,
  // automatically dismiss it and send once the device connects.
  BuildContext? _activeDialogContext;
  // Track which action should auto-resume after connect when the popup was shown
  _PendingSend _pendingSend = _PendingSend.none;

  // =============================================================
  // OTA VERSION CHECKING
  // =============================================================
  String? _deviceFirmwareVersion; // version from ESP32
  String? _otaFileVersion; // version from OTA file (embedded in filename or metadata)
  bool _otaButtonEnabled = false; // enable OTA button only if versions differ
  bool _isCheckingVersion = false; // loading state for version check
  bool _versionCheckCompleted = false; // prevents flickering by tracking completion

  Widget _smallBtn(String label, VoidCallback? onPressed, {IconData? icon, Color? backgroundColor}){
    final bgColor = backgroundColor ?? Colors.blue.shade600;
    final shadowColor = backgroundColor?.withOpacity(0.3) ?? Colors.blue.withOpacity(0.3);
    
    final buttonStyle = ElevatedButton.styleFrom(
      minimumSize: const Size(60,32),
      padding: const EdgeInsets.symmetric(horizontal:8, vertical:4),
      textStyle: const TextStyle(fontSize:15, fontWeight: FontWeight.w600),
      backgroundColor: bgColor,
      foregroundColor: Colors.white,
      elevation: 2,
      shadowColor: shadowColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
    );
    
    if(icon!=null){
      return ElevatedButton(
        style: buttonStyle,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14),
            SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 15)),
          ],
        ),
      );
    }
    return ElevatedButton(
      style: buttonStyle,
      onPressed: onPressed,
      child: Text(label, style: TextStyle(fontSize: 15)),
    );
  }

  Widget _buildOtaButton() {
    // Don't show anything until version check is complete (prevents flickering)
    if (!_versionCheckCompleted) {
      return const SizedBox.shrink();
    }
    
    // Show loading state while checking version
    if (_isCheckingVersion) {
      return Container(
        width: 60,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.grey.shade400,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        ),
      );
    }
    
    // Hide button when no update is available (instead of disabling it)
    if (!_otaButtonEnabled) {
      return const SizedBox.shrink(); // Hidden when up-to-date
    }
    
    // Build tooltip text for available update
    String tooltip = 'OTA Update Available';
    if (_deviceFirmwareVersion != null && _otaFileVersion != null) {
      tooltip = 'Update: v$_deviceFirmwareVersion → v$_otaFileVersion';
    }
    
    // Only show button when update is available - always orange and enabled
    return Tooltip(
      message: tooltip,
      child: _smallBtn(
        'OTA', 
        _sendOtaFile,
        icon: Icons.system_update_alt, 
        backgroundColor: Colors.orange.shade600,
      ),
    );
  }

  // Convert single "Color" slider (0..1) to brightness / contrast / saturation multipliers.
  void _updateEnhancementFromBoost(){
    // Keep ranges modest: extreme pre-enhancement causes harsh palette banding.
    final b = _strongColorBoost;
    _brightness  = 1.0 + b * 0.10; // up to +10%
    _contrast    = 1.0 + b * 0.30; // up to +30%
    _saturation  = 1.0 + b * 0.40; // up to +40%
  }
  
  // For image processing
  final ImagePicker _picker = ImagePicker();
  // Bluetooth state tracking
  StreamSubscription<BluetoothAdapterState>? _btStateSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connStateSub;
  DateTime _lastReconnectAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  // First window removed: no promo strip state
  @override
  void initState(){
    super.initState();
    _checkPermissions();
    // After first frame, initialize Library then load first image (if any)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initPersistentLibrary();
      if(mounted){ await _tryLoadFirstLibraryImageOnStartup(); }
    });
    // Track Bluetooth adapter state
    _btStateSub = FlutterBluePlus.adapterState.listen((s){
      final isOn = (s == BluetoothAdapterState.on);
      // If Bluetooth just turned ON and we are not connected, kick off auto scan/connect
      if(isOn && _connectedDevice==null && !_isScanning){
        _scanForDevices();
      }
    });
    // Prompt user to turn on Bluetooth at app start if needed
    WidgetsBinding.instance.addPostFrameCallback((_) { _ensureBluetoothOnAtLaunch(); });
  // Load header/logo asset named CanvasBT in FramePic/ or SamplePics/
  _loadHeaderAsset();
    // Periodically update connection status text every second
    _connectionStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      String next = 'Not connected';
      try{
        final dev = _connectedDevice;
        if(dev!=null){
          final state = await dev.connectionState.first;
          if(state == BluetoothConnectionState.connected){ next = 'Connected'; }
        }
      }catch(_){ next = 'Not connected'; }
      if(mounted && _connectionStatusText != next){ setState(()=> _connectionStatusText = next); }
      // Auto-reconnect loop while not connected
      if(mounted && next != 'Connected' && !_isScanning && !_isConnecting){
        final now = DateTime.now();
        if(now.difference(_lastReconnectAttempt).inSeconds >= 8){
          _lastReconnectAttempt = now;
          _scanForDevices();
        }
      }
    });
  }

  // On startup, if editor has no image yet, load the first entry from Library to display on first window
  Future<void> _tryLoadFirstLibraryImageOnStartup() async {
    if(_originalImage!=null || _processedPngBytes!=null) return; // something already selected
    if(_library.isEmpty) return;
    final e = _library.first;
    setState((){
      _originalImage = null;
      _uiOriginal = null;
      _processedImage = e.image.clone();
      _processedBytes = Uint8List.fromList(e.rawCodes);
      _processedPngBytes = e.pngBytes;
      _verticalFrame = e.wasVertical; // match orientation same as selected from Library
      _viewInitialized = false;
    });
    // Decode PNG to ui.Image for the crop workspace so it renders in the first window
    try{
      final codec = await ui.instantiateImageCodec(e.pngBytes);
      final frame = await codec.getNextFrame();
      ui.Image decoded = frame.image;
      // If this entry was saved as portrait, rotate the decoded UI image 90° so it displays as portrait in the first window
      if(e.wasVertical){
        decoded = await _rotateUiImage90(decoded, clockwise: false); // -90° to convert 800x480 -> 480x800
      }
      if(mounted){ setState(()=> _uiOriginal = decoded); }
    }catch(_){ /* ignore; PNG fallback remains */ }
  }

  // Rotate a ui.Image by 90 degrees. When clockwise is true, rotate +90°; otherwise rotate -90°.
  Future<ui.Image> _rotateUiImage90(ui.Image src, {bool clockwise = true}) async {
    final int newW = clockwise ? src.height : src.height;
    final int newH = clockwise ? src.width : src.width;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()));
    if(clockwise){
      // Move origin to the right edge, then rotate +90°
      canvas.translate(newW.toDouble(), 0);
      canvas.rotate(math.pi/2);
    }else{
      // Move origin to the bottom edge, then rotate -90°
      canvas.translate(0, newH.toDouble());
      canvas.rotate(-math.pi/2);
    }
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
      image: src,
      fit: BoxFit.contain,
      alignment: Alignment.topLeft,
    );
    final picture = recorder.endRecording();
    final rotated = await picture.toImage(newW, newH);
    return rotated;
  }

  // First window removed: no promo strip loader

  Future<void> _loadHeaderAsset() async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestJson);
  final keys = manifestMap.keys.where((k)=> (k.startsWith('FramePic/') || k.startsWith('SamplePics/')) ).toList();
      String? chosen;
      for(final k in keys){
        final base = k.split('/').last.toLowerCase();
        final nameNoExt = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
  if(nameNoExt == 'canvasbt'){ chosen = k; break; }
  if(chosen==null && nameNoExt.contains('canvasbt')){ chosen = k; }
      }
      if(mounted){
        setState(()=> _headerAsset = chosen);
        if(chosen!=null){ _resolveHeaderAspectRatio(chosen); }
      }
    }catch(_){ /* ignore */ }
  }

  void _resolveHeaderAspectRatio(String asset){
    final imgProv = AssetImage(asset);
    final stream = imgProv.resolve(const ImageConfiguration());
    ImageStreamListener? listener;
    listener = ImageStreamListener((ImageInfo info, bool sync){
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      if(h>0 && mounted){ setState(()=> _headerAspectRatio = w/h); }
      stream.removeListener(listener!);
    }, onError: (dynamic _, __){
      try{ stream.removeListener(listener!); }catch(_){ }
    });
    stream.addListener(listener);
  }

  @override
  void dispose(){
    _btStateSub?.cancel();
    _scanSub?.cancel(); _scanSub = null;
    _connStateSub?.cancel(); _connStateSub = null;
    _connectionStatusTimer?.cancel();
    _aiPromptController.dispose();
    _disconnectDevice();
    super.dispose();
  }

  void _dismissActiveDialog(){
    try{
      final ctx = _activeDialogContext;
      if(ctx!=null){
        Navigator.of(ctx, rootNavigator: true).pop();
      }
    }catch(_){ } finally {
      _activeDialogContext = null;
    }
  }

  // Ensure Bluetooth is on; if not, show a simple prompt to turn it on.
  Future<void> _ensureBluetoothOnAtLaunch() async {
    BluetoothAdapterState state;
    try {
      state = await FlutterBluePlus.adapterState.first;
    } catch (_) {
      // If we can't read state, just return silently
      return;
    }
    if (state == BluetoothAdapterState.on) return;

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx){
        return AlertDialog(
          title: const Text('Please turn on Bluetooth'),
          content: const SizedBox.shrink(),
          actions: [
            TextButton(
              onPressed: (){ Navigator.of(ctx).pop(); },
              child: const Text('Close'),
            ),
            if (Platform.isAndroid) FilledButton(
              onPressed: () async {
                try { await FlutterBluePlus.turnOn(); } catch(_){ }
                // Give the system a moment; when state stream reports ON we auto-scan. Also allow immediate attempt.
                await Future.delayed(const Duration(milliseconds: 300));
                if(mounted && _connectedDevice==null && !_isScanning){ _scanForDevices(); }
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Turn On'),
            ),
          ],
        );
      }
    );
  }

  // Resolve the appropriate finger image for the orientation with robust fallbacks.
  Future<String?> _resolveFingerAssetForOrientation(bool portrait) async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestJson);
      // list of candidate image assets under FramePic/ or SamplePics/
      final keys = manifestMap.keys.where((k){
        if(!(k.startsWith('FramePic/') || k.startsWith('SamplePics/'))) return false;
        final kl = k.toLowerCase();
        return kl.endsWith('.png') || kl.endsWith('.jpg') || kl.endsWith('.jpeg');
      }).toList();
      String targetExact = portrait ? 'framefinger' : 'framefingerh';
      // 1) Exact match first
      for(final k in keys){
        final base = k.split('/').last.toLowerCase();
        final noExt = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
        if(noExt == targetExact){ return k; }
      }
      // 2) Heuristic: prefer names containing 'frame' and 'finger'
      List<String> candidates = keys.where((k){
        final b = k.split('/').last.toLowerCase();
        return b.contains('finger');
      }).toList();
      // Prefer non-H for portrait and H for landscape when available
      List<String> preferred;
      if(portrait){
        final nonH = candidates.where((k){
          final noExt = k.split('/').last.toLowerCase();
          final name = noExt.contains('.') ? noExt.substring(0, noExt.lastIndexOf('.')) : noExt;
          return !name.endsWith('h');
        }).toList();
        preferred = nonH.isNotEmpty ? nonH : candidates;
      }else{
        final onlyH = candidates.where((k){
          final noExt = k.split('/').last.toLowerCase();
          final name = noExt.contains('.') ? noExt.substring(0, noExt.lastIndexOf('.')) : noExt;
          return name.endsWith('h');
        }).toList();
        preferred = onlyH.isNotEmpty ? onlyH : candidates;
      }
      // Score portrait vs landscape by presence of trailing 'h'
      String? best;
      int bestScore = -9999;
      for(final k in preferred){
        final b = k.split('/').last.toLowerCase();
        int score = 0;
        if(b.contains('frame')) score += 3;
        if(b.startsWith('frame')) score += 2;
        if(b.contains('finger')) score += 2;
        final noExt = b.contains('.') ? b.substring(0, b.lastIndexOf('.')) : b;
        final endsWithH = noExt.endsWith('h');
        if(portrait){
          // prefer NOT having trailing 'h' (reserve that for horizontal)
          score += endsWithH ? -3 : 2;
        }else{
          // prefer having trailing 'h' for horizontal
          score += endsWithH ? 3 : -1;
        }
        if(score > bestScore){ bestScore = score; best = k; }
      }
      return best;
    }catch(_){ return null; }
  }

  // Wrapper for triggering rebuild from extension helpers
  void _refresh(){ if(mounted){ setState(()=>{}); } }

  // Top bar visible while connected (image, library, navigation)
  Widget _connectedTopBar(){
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 1),
      child: Row(children:[
        Expanded(
          child: SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: _pickImage,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                backgroundColor: Colors.blue.shade500,
                foregroundColor: Colors.white,
                elevation: 2,
                shadowColor: Colors.blue.withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.photo_library, size: 11),
                  SizedBox(width: 2),
                  Text('Gallery', style: TextStyle(fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: SizedBox(
            height: 32,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _library.isEmpty ? Colors.grey.shade400 : Colors.green.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                elevation: 2,
                shadowColor: (_library.isEmpty ? Colors.grey : Colors.green).withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _library.isEmpty ? null : (){ setState(()=> _showLibrary = true); },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark, size: 11),
                  SizedBox(width: 2),
                  Text('Saved', style: TextStyle(fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: (){ setState((){ _showAi = true; _aiError = null; }); },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                backgroundColor: Colors.purple.shade500,
                foregroundColor: Colors.white,
                elevation: 2,
                shadowColor: Colors.purple.withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 11),
                  SizedBox(width: 2),
                  Text('AI', style: TextStyle(fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: SizedBox(
            height: 32,
            child: ElevatedButton(
              onPressed: (){ setState((){ _showOnline = true; _onlineImagesFuture ??= _fetchGitHubImages(); }); },
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                backgroundColor: Colors.orange.shade500,
                foregroundColor: Colors.white,
                elevation: 2,
                shadowColor: Colors.orange.withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_download, size: 11),
                  SizedBox(width: 2),
                  Text('Library', style: TextStyle(fontSize: 15)),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildConnected(){
    if(_showAi){
      return _buildAiView();
    }
    if(_showLibrary){
      return _buildLibraryView();
    }
    if(_showOnline){
      return _buildOnlineView();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _connectedTopBar(),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Show the crop workspace whenever we have a UI image (including startup from Library)
                if (_uiOriginal != null)
                  _buildCropFrame()
                else
                  Padding(
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      height: 300, // match crop frame height - keep constant to prevent shift
                      child: Center(
                        child: _processedPngBytes != null
                          ? FittedBox(
                              fit: BoxFit.contain,
                              child: _verticalFrame
                                ? RotatedBox(quarterTurns: 3, child: Image.memory(_processedPngBytes!, fit: BoxFit.contain))
                                : Image.memory(_processedPngBytes!, fit: BoxFit.contain),
                            )
                          : Text(
                              'Please select an image from Gallery, Library or Generate an Image from AI',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                _buildActionBar(),
                const SizedBox(height: 10),
                // Reduce available height slightly during sending to avoid overflow of progress bar
                Padding(
                  padding: EdgeInsets.only(bottom: _isSending ? 10 : 0),
                  child: _buildPreviewAndSliders(),
                ),
                if (_isSending) ...[
                  const SizedBox(height: 2),
                  LinearProgressIndicator(value: _transferProgress/100),
                  Text('$_transferProgress%  ${_transferSpeed.toStringAsFixed(1)} KB/s', textAlign: TextAlign.center, style: const TextStyle(fontSize:12)),
                ],
                SizedBox(height: _isSending ? 0 : 4),
                _statusCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // Main action bar (orientation toggle, add to library, process, send, reset)
  Widget _buildActionBar(){
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:8, vertical:2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children:[
        // Left side controls
        Row(children:[
          _smallBtn(
            _verticalFrame ? 'Portrait' : 'Landscape',
            (_uiOriginal != null || _processedPngBytes != null) ? (){
              setState((){
                _verticalFrame = !_verticalFrame;
                _processedImage = null;
                _processedBytes = null;
                // Don't reset _viewInitialized - preserve user's image position/zoom
              });
              _recomputeViewForCurrentFrame(context);
            } : null,
            icon: Icons.screen_rotation,
            backgroundColor: Colors.indigo.shade600,
          ),
          const SizedBox(width:2),
          _smallBtn('Save', _originalImage==null ? null : _addCurrentToLibrary, icon: Icons.library_add, backgroundColor: Colors.green.shade600),
          const SizedBox(width:2),
          _smallBtn('Send', _sendOrProcessThenSend, icon: Icons.send, backgroundColor: Colors.blue.shade600),
        ]),
        const Spacer(),
        // Right side controls
        Row(children:[
          // Only add spacing if OTA button is visible (after version check is complete)
          if (_versionCheckCompleted && (_otaButtonEnabled || _isCheckingVersion)) ...[
            const SizedBox(width:2),
            _buildOtaButton(),
            const SizedBox(width:2),
          ],
          _smallBtn('Exit', _exitApp, icon: Icons.exit_to_app, backgroundColor: Colors.red.shade600),
        ])
      ]),
    );
  }

  // Recompute frame geometry and cover-fit view instantly for current layout sizes
  void _recomputeViewForCurrentFrame(BuildContext context){
    final imgObj = _uiOriginal; if(imgObj==null) return;
    // These match sizes used in crop frame and preview
    final double workspaceW = MediaQuery.of(context).size.width - 24; // body horizontal padding is 12 each side
    final double workspaceH = 300; // crop frame height - keep constant to prevent image shift
    // Compute frame size same as _buildCropFrame
    double frameW = workspaceW * 0.5;
    double frameH;
    if (_verticalFrame) {
      frameH = frameW * (IMAGE_WIDTH / IMAGE_HEIGHT);
    } else {
      frameH = frameW * (IMAGE_HEIGHT / IMAGE_WIDTH);
    }
    if (frameH > workspaceH) {
      frameH = workspaceH * 0.5;
      if (_verticalFrame) {
        frameW = frameH * (IMAGE_HEIGHT / IMAGE_WIDTH);
      } else {
        frameW = frameH * (IMAGE_WIDTH / IMAGE_HEIGHT);
      }
    }
    final Offset origin = Offset((workspaceW - frameW)/2, (workspaceH - frameH)/2);
    // Compute fit scale for min/max scale limits only, don't auto-adjust user's view
    final iw = imgObj.width.toDouble();
    final ih = imgObj.height.toDouble();
    final fitScale = math.min(frameW / iw, frameH / ih);
    setState((){
      _frameWidth = frameW;
      _frameHeight = frameH;
      _frameOrigin = origin;
      // Only set initial view if not yet initialized, otherwise preserve user's adjustments
      if (!_viewInitialized) {
        _viewScale = fitScale;
        _viewRotation = 0.0;
        _viewTranslation = Offset(
          (workspaceW - iw*fitScale)/2,
          (workspaceH - ih*fitScale)/2,
        );
        _viewInitialized = true;
      }
      // Always update scale limits based on new frame size
      _minScale = (fitScale * 0.01).clamp(0.005, double.infinity);
      _maxScale = fitScale * 80;
    });
  }

  // ========================= AI IMAGES VIEW =========================
  Widget _buildAiView(){
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children:[
          // Back first, aligned left
          _smallBtn('Back', (){ setState((){ _showAi = false; }); }, icon: Icons.arrow_back),
          const SizedBox(width: 8),
          // Use in Editor next
          _smallBtn('Use in Editor', (_aiPngBytes==null || _aiIsGenerating) ? null : _useAiImage, icon: Icons.open_in_new),
          const Spacer(),
          // Generate last, with green color, aligned right
          ElevatedButton.icon(
            onPressed: _aiIsGenerating ? null : _generateAiImage,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            icon: const Icon(Icons.auto_awesome, size: 18),
            label: Text(_aiIsGenerating ? 'Generating...' : 'Generate'),
          ),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _aiPromptController,
          decoration: const InputDecoration(
            labelText: 'Describe an image',
            hintText: 'e.g., A serene mountain with sunrise',
            border: OutlineInputBorder(),
          ),
          minLines: 1,
          maxLines: 3,
        ),
        const SizedBox(height: 6),
        const Text(
          'Uses a free online generator and needs internet. Generation may take a few seconds.',
          style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Center(
              child: _aiIsGenerating
                ? const CircularProgressIndicator()
                : (_aiPngBytes==null
                    ? Text(_aiError ?? 'Enter a prompt and tap Generate', style: Theme.of(context).textTheme.titleMedium)
                    : Image.memory(_aiPngBytes!, fit: BoxFit.contain)),
            ),
          ),
        ),
        const SizedBox(height: 6),
        _statusCard(),
      ],
    );
  }

  Future<void> _generateAiImage() async {
    setState((){ _aiIsGenerating = true; _aiError = null; _aiPngBytes = null; });
    final prompt = _aiPromptController.text.trim();
    try{
      // Attempt free text-to-image via Pollinations (no API key) with multiple URL variants.
      const String aiPrefix = 'colourful painiting use solid black,white,red,yellow,blue,green colors, beautiful looking for Spectra 6 for';
      final safePrompt = (aiPrefix + (prompt.isEmpty ? '' : prompt)).trim();
      final encoded = Uri.encodeComponent(safePrompt);
      final seed = (safePrompt.hashCode & 0x7fffffff).toString();
      // Use editor orientation (_verticalFrame) instead of a separate AI toggle
      final genW = _verticalFrame ? IMAGE_HEIGHT : IMAGE_WIDTH;  // 480 if portrait
      final genH = _verticalFrame ? IMAGE_WIDTH : IMAGE_HEIGHT;  // 800 if portrait
      final candidates = <Uri>[
        Uri.parse('https://image.pollinations.ai/prompt/$encoded?width=$genW&height=$genH&seed=$seed&nologo=true'),
        Uri.parse('https://image.pollinations.ai/prompt/$encoded?size=${genW}x$genH&seed=$seed&nologo=true'),
      ];
      for(final url in candidates){
        final ok = await _tryFetchImage(url).timeout(const Duration(seconds: 20), onTimeout: () => false);
        if(ok){ return; }
      }
      // If all remote attempts fail, fall back to local synthesis
      await _generateAiImageLocally(safePrompt);
    } catch (e){
      // Fallback to local synthesis on any error
      const String aiPrefix = 'Paiting colourful (black,white,red,yellow,blue,green) ';
      final fallback = (aiPrefix + (prompt.isEmpty ? '' : prompt)).trim();
      await _generateAiImageLocally(fallback);
    } finally {
      if(mounted){ setState(()=> _aiIsGenerating = false); }
    }
  }

  Future<bool> _tryFetchImage(Uri url) async {
    HttpClient? client;
    try{
      client = HttpClient()
        ..userAgent = 'CanvasBT-app'
        ..badCertificateCallback = (cert, host, port) => false;
      final req = await client.getUrl(url);
      req.followRedirects = true;
      req.headers.set(HttpHeaders.acceptHeader, 'image/*');
      final resp = await req.close();
      if (resp.statusCode != 200) { return false; }
      // Collect bytes
      final bytesBuilder = BytesBuilder();
      await for (final chunk in resp) { bytesBuilder.add(chunk); }
      final bytes = bytesBuilder.takeBytes();
      if (bytes.isEmpty) { return false; }
      // Try decode to verify it's an image
      try{
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      }catch(_){ return false; }
      if(mounted){ setState(()=> _aiPngBytes = bytes); }
      _updateStatus('AI image generated');
      return true;
    } catch(_){
      return false;
    } finally {
      try{ client?.close(force: true); }catch(_){ }
    }
  }

  Future<void> _generateAiImageLocally(String prompt) async {
    try{
      // Ensure the local generator also reflects the requested style prefix if not already present.
      const String aiPrefix = 'Paiting colourful (black,white,red,yellow,blue,green) ';
      if(!prompt.startsWith(aiPrefix)){
        prompt = (aiPrefix + prompt).trim();
      }
      // Use editor orientation for canvas size
      final int w = _verticalFrame ? IMAGE_HEIGHT : IMAGE_WIDTH;
      final int h = _verticalFrame ? IMAGE_WIDTH : IMAGE_HEIGHT;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0,0,w.toDouble(),h.toDouble()));
      final hash = prompt.hashCode;
      Color c1 = HSVColor.fromAHSV(1.0, (hash & 0xFF).toDouble() % 360, 0.5, 0.95).toColor();
      Color c2 = HSVColor.fromAHSV(1.0, ((hash>>8) & 0xFF).toDouble() % 360, 0.7, 0.7).toColor();
      final paint = Paint()
        ..shader = ui.Gradient.linear(const Offset(0,0), Offset(w.toDouble(), h.toDouble()), [c1, c2]);
      canvas.drawRect(Rect.fromLTWH(0,0,w.toDouble(),h.toDouble()), paint);
  final words = prompt.isEmpty ? ['CanvasBT','art'] : prompt.split(RegExp(r'\s+')).take(5).toList();
      final rng = math.Random(hash);
      for(int i=0;i<words.length;i++){
        final px = rng.nextDouble()*w;
        final py = rng.nextDouble()*h;
        final sz = 30.0 + rng.nextDouble()*120.0;
        final p = Paint()..color = HSVColor.fromAHSV(0.8, (rng.nextInt(360)).toDouble(), 0.6, 0.9).toColor();
        canvas.drawCircle(Offset(px,py), sz, p);
      }
      final textPainter = TextPainter(
  text: TextSpan(text: prompt.isEmpty ? 'CanvasBT' : prompt, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      );
      textPainter.layout(maxWidth: w*0.9);
      textPainter.paint(canvas, Offset((w - textPainter.width)/2, (h - textPainter.height)/2));
      final picture = recorder.endRecording();
      final uiImage = await picture.toImage(w, h);
      final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      final png = byteData!.buffer.asUint8List();
      if(mounted){ setState(()=> _aiPngBytes = png); }
      _updateStatus('Generated locally');
    } catch (e) {
      if(mounted){ setState(()=> _aiError = 'Failed to generate: $e'); }
      _updateStatus('AI generation error');
    }
  }

  Future<void> _useAiImage() async {
    if(_aiPngBytes==null) return;
    try{
      // Write PNG to a temp file and use as original image to allow full editing pipeline
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ai_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(_aiPngBytes!);
      setState((){
        _originalImage = file;
        _processedImage = null;
        _processedBytes = null;
        _processedPngBytes = null;
        _uiOriginal = null;
        _viewInitialized = false;
        _showAi = false;
      });
      await _loadUiImage();
      _updateStatus('AI image loaded into editor');
    }catch(_){
      _updateStatus('Failed to load AI image');
    }
  }

  // =============================================================
  // OTA VERSION CHECKING FUNCTIONS
  // =============================================================
  
  Future<void> _checkFirmwareVersion() async {
    if (_connectedDevice == null || _rxCharacteristic == null) return;
    
    setState(() => _isCheckingVersion = true);
    
    try {
      // Query firmware version from ESP32
      String? deviceVersion = await _queryDeviceFirmwareVersion();
      
      // Get OTA file version
      String? otaVersion = await _getOtaFileVersion();
      
      setState(() {
        _deviceFirmwareVersion = deviceVersion;
        _otaFileVersion = otaVersion;
        _otaButtonEnabled = _shouldEnableOtaButton(deviceVersion, otaVersion);
        _isCheckingVersion = false;
        _versionCheckCompleted = true; // Mark as completed to prevent flickering
      });
      
      if (deviceVersion != null && otaVersion != null) {
        if (_otaButtonEnabled) {
          _updateStatus('OTA available: Device v$deviceVersion → v$otaVersion');
        } else {
          _updateStatus('Firmware up-to-date: v$deviceVersion');
        }
      } else {
        _updateStatus('Version check completed');
      }
    } catch (e) {
      setState(() {
        _isCheckingVersion = false;
        _otaButtonEnabled = true; // Enable by default on error
        _versionCheckCompleted = true; // Mark as completed even on error
      });
      _updateStatus('Version check failed: $e');
    }
  }
  
  Future<String?> _queryDeviceFirmwareVersion() async {
    if (_connectedDevice == null || _rxCharacteristic == null) return null;
    
    try {
      // Create a completer to wait for the version response
      Completer<String?> versionCompleter = Completer<String?>();
      
      // Set up a temporary listener for version response
      late StreamSubscription subscription;
      subscription = _connectedDevice!.connectionState.listen((_) {});
      
      // Listen for version response on TX characteristic
      BluetoothCharacteristic? txChar;
      
      List<BluetoothService> services = await _connectedDevice!.discoverServices();
      for (BluetoothService service in services) {
        if (service.uuid.toString().toUpperCase() == UART_SERVICE_UUID.toUpperCase()) {
          for (BluetoothCharacteristic characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() == UART_TX_CHAR_UUID.toUpperCase()) {
              txChar = characteristic;
              break;
            }
          }
          break;
        }
      }
      
      if (txChar == null) throw Exception("TX characteristic not found");
      
      // Set up version response listener
      subscription = txChar.onValueReceived.listen((value) {
        if (value.isNotEmpty && value[0] == 0x30) {
          // Version response received
          String version = String.fromCharCodes(value.sublist(1));
          if (!versionCompleter.isCompleted) {
            versionCompleter.complete(version.trim());
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
      
      return version;
    } catch (e) {
      print('Error querying device version: $e');
      return null;
    }
  }
  
  Future<String?> _getOtaFileVersion() async {
    try {
      // Try to read version from OTA filename or embedded metadata
      // For now, we'll check if the file exists and extract version from filename
      final otaPath = 'OTAFile/Spectra6.ino.bin';
      
      // Load the asset to check if it exists
      try {
        await rootBundle.load(otaPath);
        // If we can load it, it exists
        
        // For now, extract version from filename or use a default
        // You can modify this to embed version in the binary or filename
        String filename = otaPath.split('/').last;
        
        // Check if filename contains version pattern like "v1.0.0" or "1.0.0"
        RegExp versionRegex = RegExp(r'v?(\d+\.\d+\.\d+)');
        Match? match = versionRegex.firstMatch(filename);
        
        if (match != null) {
          return match.group(1); // Return version without 'v' prefix
        }
        
        // If no version in filename, you could read it from binary metadata
        // For now, return a default version that you should update manually
        return "1.2.0"; // Update this when you create new OTA files
        
      } catch (e) {
        print('OTA file not found: $e');
        return null;
      }
    } catch (e) {
      print('Error getting OTA file version: $e');
      return null;
    }
  }
  
  bool _shouldEnableOtaButton(String? deviceVersion, String? otaVersion) {
    if (deviceVersion == null || otaVersion == null) {
      return true; // Enable by default if we can't determine versions
    }
    
    // Compare versions
    return _compareVersions(deviceVersion, otaVersion) < 0; // Device version < OTA version
  }
  
  int _compareVersions(String version1, String version2) {
    List<int> v1Parts = version1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    List<int> v2Parts = version2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    
    // Pad with zeros if needed
    while (v1Parts.length < 3) v1Parts.add(0);
    while (v2Parts.length < 3) v2Parts.add(0);
    
    for (int i = 0; i < 3; i++) {
      if (v1Parts[i] < v2Parts[i]) return -1;
      if (v1Parts[i] > v2Parts[i]) return 1;
    }
    return 0; // Equal
  }

  // Select an online image (just track selection, don't download yet)
  void _selectOnlineImage(String imageUrl) {
    if (_selectedOnlineImageUrl == imageUrl) {
      // If already selected, deselect
      setState(() {
        _selectedOnlineImageUrl = null;
        _isLoadingOnlineImage = false;
      });
      return;
    }

    setState(() {
      _selectedOnlineImageUrl = imageUrl;
      _isLoadingOnlineImage = false; // Reset loading state when selecting new image
    });
    
    _updateStatus('Image selected - press "Use in Editor" to load');
  }

  // Use the selected online image in the editor (download and load)
  Future<void> _useSelectedOnlineImage() async {
    if (_selectedOnlineImageUrl == null) return;
    
    setState(() {
      _isLoadingOnlineImage = true;
    });
    
    try {
      _updateStatus('Downloading image...');
      
      // Convert thumbnail URL to full-resolution download URL
      String fullResUrl = _selectedOnlineImageUrl!;
      if (_selectedOnlineImageUrl!.contains('thumbnail?id=')) {
        final fileId = _selectedOnlineImageUrl!.split('id=')[1].split('&')[0];
        fullResUrl = 'https://drive.google.com/uc?export=download&id=$fileId';
      }
      
      final response = await http.get(Uri.parse(fullResUrl));
      if (response.statusCode != 200) {
        _updateStatus('Failed to download image (HTTP ${response.statusCode})');
        setState(() {
          _isLoadingOnlineImage = false;
        });
        return;
      }
      
      // Create a temporary file
      final tempDir = await getTemporaryDirectory();
      String fileName = 'image';
      try {
        fileName = _selectedOnlineImageUrl!.split('/').last;
        if (fileName.isEmpty || !fileName.contains('.')) {
          fileName = 'online_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
        }
      } catch (_) {
        fileName = 'online_image_${DateTime.now().millisecondsSinceEpoch}.jpg';
      }
      
      final tempFile = File('${tempDir.path}/online_${DateTime.now().millisecondsSinceEpoch}_$fileName');
      await tempFile.writeAsBytes(response.bodyBytes);
      
      // Set as current image
      setState(() {
        _originalImage = tempFile;
        _uiOriginal = null;
        _processedImage = null;
        _processedBytes = null;
        _processedPngBytes = null;
        _showOnline = false; // Return to main view
        _viewInitialized = false; // Force frame recompute
        _selectedOnlineImageUrl = null; // Clear selection
      });
      
      await _loadUiImage();
      _updateStatus('Online image loaded into editor');
    } catch (e) {
      _updateStatus('Failed to load online image: $e');
    } finally {
      setState(() {
        _isLoadingOnlineImage = false;
      });
    }
  }

  // Save the currently processed frame into the in-memory library (PNG cached for fast thumbnails)
  Future<void> _addCurrentToLibrary() async {
    // Process on-demand if not already processed
    if(_originalImage==null){ return; }
  if(_processedBytes==null){ await _processImage(); }
    if(_processedBytes==null || _processedImage==null){ return; }
    // Reuse cached PNG when available
  final png = _processedPngBytes ?? Uint8List.fromList(img.encodePng(_processedImage!));
  final entry = _LibraryEntry(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    image: _processedImage!.clone(),
    rawCodes: Uint8List.fromList(_processedBytes!),
    pngBytes: png,
    created: DateTime.now(),
    wasVertical: _verticalFrame,
    isDefaultAsset: false,
  title: 'Saved',
  );
    setState((){ _library.insert(0, entry); });
    _updateStatus('Added to library (total ${_library.length})');
    _persistLibraryEntry(entry);
  }

  // If not processed yet, process with current framing, then send
  Future<void> _sendOrProcessThenSend() async {
    if(_isSending){
      if(!await _isReallyConnected()){
        setState((){ _isSending = false; });
      } else {
        return;
      }
    }
    // First, ensure Bluetooth adapter is ON; if OFF, show the same turn-on dialog used at launch
    try{
      final adapterState = await FlutterBluePlus.adapterState.first;
      if(adapterState != BluetoothAdapterState.on){
        await _ensureBluetoothOnAtLaunch();
      }
    }catch(_){ /* ignore; continue to disconnected handling */ }
    // If disconnected, show message and exit
    if(!await _isReallyConnected()){
      setState((){ _connectedDevice = null; _rxCharacteristic = null; });
      if(!mounted) return;
      // Pick the correct finger image based on current orientation
      final String? fingerAsset = await _resolveFingerAssetForOrientation(_verticalFrame);
      _pendingSend = _PendingSend.image; // remember user's intent
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx){
          _activeDialogContext = ctx;
          return AlertDialog(
            title: const Text('Please Touch the frame'),
            content: fingerAsset==null
              ? const SizedBox.shrink()
              : SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: 16/9,
                        child: Image.asset(fingerAsset, fit: BoxFit.contain),
                      ),
                    ],
                  ),
                ),
            actions: [
              TextButton(onPressed: (){ Navigator.of(ctx).pop(); }, child: const Text('Close')),
            ],
          );
        }
      );
      // Dialog closed; clear handle if still set
      _activeDialogContext = null;
      // If still disconnected, user likely dismissed the dialog -> clear intent.
      // If we connected and closed programmatically, keep intent for auto-resume in _connectToDevice.
      final stillDisconnected = (_connectedDevice == null || _rxCharacteristic == null);
      if (stillDisconnected) {
        _pendingSend = _PendingSend.none;
      }
      return;
    }
    // Connected path: ensure we don't mistakenly treat as pending
    _activeDialogContext = null;
    // If we already have processed bytes, send directly
    if(_processedBytes!=null){ await _sendImageData(); return; }
    // If we have an original image selected, process then send
    if(_originalImage!=null){
      await _processImage();
      if(_processedBytes!=null){ await _sendImageData(); return; }
    }
    // If we have a processed PNG preview, derive raw codes and send
    if(_processedPngBytes!=null){
      final decoded = img.decodeImage(_processedPngBytes!);
      if(decoded!=null){
        final q = _quantizeTo6ColorAndCreateRawBytes(decoded);
        setState((){ _processedImage = q.item1; _processedBytes = Uint8List.fromList(q.item2); });
        await _sendImageData();
        return;
      }
    }
    // As a last resort, use the first library item if available
    if(_library.isNotEmpty){
      final e = _library.first;
      setState((){
        _processedImage = e.image.clone();
        _processedBytes = Uint8List.fromList(e.rawCodes);
        _processedPngBytes = e.pngBytes;
        _verticalFrame = e.wasVertical;
        _viewInitialized = false;
      });
      await _sendImageData();
      return;
    }
    _updateStatus('No image to send. Pick, generate, or use Library.');
  }

  // Grid of saved processed images (tap to select, then Send / Delete)
  Widget _buildLibraryView(){
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children:[
          _smallBtn('Back', ()=> setState(()=> _showLibrary=false), icon: Icons.arrow_back, backgroundColor: Colors.grey.shade600),
          const SizedBox(width:6),
          _smallBtn('Delete', _selectedLibraryIndex==null ? null : _deleteSelectedLibraryItem, icon: Icons.delete, backgroundColor: Colors.red.shade600),
          const SizedBox(width:6),
          _smallBtn(_isSending? 'Sending' : 'Send', _selectedLibraryIndex==null ? null : _sendSelectedLibraryItem, icon: Icons.send, backgroundColor: Colors.blue.shade600),
        ]),
        const SizedBox(height:8),
        Expanded(
          child: _library.isEmpty ? Center(child: Text('No images saved', style: Theme.of(context).textTheme.titleMedium))
          : GridView.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
              itemCount: _library.length,
              itemBuilder: (c,i){
                final e = _library[i];
                final selected = i==_selectedLibraryIndex;
                return GestureDetector(
                  onTap: ()=> setState(()=> _selectedLibraryIndex = i),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: selected? Theme.of(context).colorScheme.primary : Colors.grey.shade400, width: selected? 3:1),
                      borderRadius: BorderRadius.circular(6),
                      color: Colors.white,
                    ),
                    child: Stack(children:[
                      Positioned.fill(child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: e.wasVertical
                            ? RotatedBox(quarterTurns: 3, child: Image.memory(e.pngBytes, fit: BoxFit.cover))
                            : Image.memory(e.pngBytes, fit: BoxFit.cover),
                      )),
                      Positioned(
                        left:4, top:4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal:4, vertical:2),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                          child: Text(e.wasVertical? 'Portrait' : 'Landscape', style: const TextStyle(color: Colors.white, fontSize:9, fontWeight: FontWeight.w500)),
                        ),
                      ),
                      Positioned(
                        right:4, bottom:4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal:4, vertical:2),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                          child: Text('${e.created.hour.toString().padLeft(2,'0')}:${e.created.minute.toString().padLeft(2,'0')}', style: const TextStyle(color: Colors.white,fontSize:10)),
                        ),
                      ),
                    ]),
                  ),
                );
              },
            ),
        ),
        if(_selectedLibraryIndex!=null) ...[
          const SizedBox(height:6),
          _statusCard(),
        ] else ...[
          const SizedBox(height:6),
          _statusCard(),
        ]
      ],
    );
  }

  void _sendSelectedLibraryItem(){
    final idx = _selectedLibraryIndex; if(idx==null) return;
    final entry = _library[idx];
    setState((){
      // Clear any previously selected gallery image to prefer the library image on the main screen
      _originalImage = null;
      _uiOriginal = null;
      _processedImage = entry.image.clone();
      _processedBytes = Uint8List.fromList(entry.rawCodes); // raw codes length w*h
      _showLibrary = false; // return to main view for progress indicators
      _processedPngBytes = entry.pngBytes;
      _verticalFrame = entry.wasVertical;
      _viewInitialized = false; // force frame recompute next build
    });
    _sendImageData();
  }

  void _deleteSelectedLibraryItem(){
    final idx = _selectedLibraryIndex; if(idx==null) return;
    final entry = _library[idx];
    setState((){
      _library.removeAt(idx);
      _selectedLibraryIndex = null;
    });
    _updateStatus('Deleted. ${_library.length} remaining');
    _deleteLibraryEntryFiles(entry);
  }

  // Online images view - shows images from Google Drive folder
  Widget _buildOnlineView(){
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          color: Colors.blue.shade50,
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: (){ setState(()=> _showOnline = false); },
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const Expanded(
                    child: Text('Online Images', 
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  IconButton(
                    onPressed: (){ setState((){ _onlineImagesFuture = _fetchGitHubImages(); }); },
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh images',
                  ),
                ],
              ),
              // Action buttons row - always show Use in Editor button
              const SizedBox(height: 8),
              Row(
                children: [
                  _smallBtn('Use in Editor', 
                    (_selectedOnlineImageUrl != null && !_isLoadingOnlineImage) ? _useSelectedOnlineImage : null, 
                    icon: Icons.open_in_new, backgroundColor: Colors.green.shade600),
                  const Spacer(),
                  if (_isLoadingOnlineImage)
                    const Text('Loading...', 
                      style: TextStyle(fontSize: 12))
                  else if (_selectedOnlineImageUrl != null)
                    const Text('Selected - press button to download and load', 
                      style: TextStyle(fontSize: 12))
                  else
                    const Text('Select an image to use in editor', 
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<List<String>>(
            future: _onlineImagesFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, size: 64, color: Colors.red),
                      const SizedBox(height: 16),
                      Text('Error loading images: ${snapshot.error}'),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => setState(() {}),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }
              
              final imageUrls = snapshot.data ?? [];
              if (imageUrls.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder_open, size: 64, color: Colors.orange),
                        const SizedBox(height: 16),
                        const Text(
                          'Individual File Sharing Required',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Your folder is public, but individual files need sharing:\n\n'
                          '1. Go to your Google Drive folder\n'
                          '2. Select each image file\n'
                          '3. Right-click → Share → "Anyone with the link"\n'
                          '4. Refresh this page\n\n'
                          'Or try uploading new images (they inherit folder permissions)',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => setState(() => _onlineImagesFuture = _fetchGitHubImages()),
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try Again'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              
              // Ultra-aggressive preloading - preload first 15 images in parallel
              _preloadImages(imageUrls.take(15).toList());
              
              // Continue preloading remaining images in background
              if (imageUrls.length > 15) {
                Future.delayed(const Duration(milliseconds: 500), () {
                  _preloadImages(imageUrls.skip(15).toList());
                });
              }
              
              return GridView.builder(
                padding: const EdgeInsets.all(6),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4, // 4 columns for more images and faster scrolling
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                  childAspectRatio: 1.0,
                ),
                // Performance optimizations
                cacheExtent: 1000, // Cache more items for smoother scrolling
                physics: const BouncingScrollPhysics(), // Faster scroll physics
                itemCount: imageUrls.length,
                itemBuilder: (context, index) {
                  final imageUrl = imageUrls[index];
                  final isSelected = _selectedOnlineImageUrl == imageUrl;
                  return GestureDetector(
                    onTap: () => _selectOnlineImage(imageUrl),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: isSelected ? Colors.blue.shade600 : Colors.grey.shade400, 
                          width: isSelected ? 3.0 : 0.5
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: _buildImageWithRetry(imageUrl),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // Fetch images from your public Google Drive folder  
  Future<List<String>> _fetchGitHubImages() async {
    try {
      debugPrint('Loading images from your public Google Drive folder...');
      
      const folderId = '1KX35Io5MsDq4AnsZFM1HSdZH7HY3fBS-';
      
      // Since your folder is already public, let's use a direct approach
      
      // Method 1: Try to access folder contents via web scraping
      final folderUrl = 'https://drive.google.com/drive/folders/$folderId';
      
      try {
        final response = await http.get(Uri.parse(folderUrl));
        
        if (response.statusCode == 200) {
          final htmlContent = response.body;
          final imageUrls = <String>[];
          
          // Look for file patterns in the HTML that indicate images
          // Google Drive exposes file information in the page source
          final filePattern = RegExp(r'"([a-zA-Z0-9_-]{25,})"[^"]*"([^"]*\.(?:jpg|jpeg|png|gif|webp))"', caseSensitive: false);
          final matches = filePattern.allMatches(htmlContent);
          
          for (final match in matches) {
            final fileId = match.group(1);
            final fileName = match.group(2);
            
            if (fileId != null && fileName != null && _isValidImageFile(fileName)) {
              debugPrint('Found valid image: $fileName with ID: $fileId');
              // Use ultra-fast small thumbnail format
              imageUrls.add('https://drive.google.com/thumbnail?id=$fileId&sz=w200-h200');
            }
          }
          
          // Alternative pattern - be more selective about file IDs
          if (imageUrls.isEmpty) {
            // Look for specific patterns that indicate image files in Google Drive
            final patterns = [
              // Pattern 1: Look for file IDs near image-related terms
              RegExp(r'"([a-zA-Z0-9_-]{28,})"[^"]{0,100}(?:jpg|jpeg|png|gif|webp)', caseSensitive: false),
              // Pattern 2: Look for file IDs in image context
              RegExp(r'(?:jpg|jpeg|png|gif|webp)[^"]{0,50}"([a-zA-Z0-9_-]{28,})"', caseSensitive: false),
            ];
            
            final seenIds = <String>{};
            
            for (final pattern in patterns) {
              final matches = pattern.allMatches(htmlContent);
              for (final match in matches) {
                final fileId = match.group(1);
                if (fileId != null && 
                    fileId.length >= 28 && 
                    fileId.length <= 50 && 
                    !seenIds.contains(fileId) &&
                    !fileId.contains('folder') && // Exclude folder IDs
                    !fileId.startsWith('0B')) { // Exclude old format IDs
                  seenIds.add(fileId);
                  // Use ultra-fast small thumbnail format for quicker loading
                  imageUrls.add('https://drive.google.com/thumbnail?id=$fileId&sz=w200-h200');
                }
              }
            }
            
            debugPrint('Found ${imageUrls.length} carefully filtered image URLs');
          }
          
          if (imageUrls.isNotEmpty) {
            // Filter out duplicate URLs and very short IDs
            final filteredUrls = imageUrls.toSet().where((url) {
              final id = url.split('id=').last;
              return id.length >= 25; // Google Drive file IDs are at least 25 characters
            }).toList();
            
            // Return all discovered images from your Google Drive folder
            debugPrint('Discovered ${filteredUrls.length} image URLs from your Google Drive');
            return filteredUrls; // Show ALL images from your folder
          }
        }
      } catch (e) {
        debugPrint('Web scraping failed: $e');
      }
      
      // Method 2: Fallback to known working approach
      return _getKnownPublicImages();
      
    } catch (e) {
      debugPrint('Error auto-discovering images: $e');
      return _getKnownPublicImages();
    }
  }
  
  // Access your public Google Drive folder directly
  Future<List<String>> _getKnownPublicImages() async {
    try {
      debugPrint('Accessing your public Google Drive folder directly...');
      
      const folderId = '1KX35Io5MsDq4AnsZFM1HSdZH7HY3fBS-';
      
      // For public folders, try to get the files using the folder's export URL
      final exportUrl = 'https://drive.google.com/drive/folders/$folderId?usp=sharing';
      
      try {
        final response = await http.get(Uri.parse(exportUrl));
        debugPrint('Public folder access status: ${response.statusCode}');
        
        if (response.statusCode == 200) {
          // Parse HTML to find actual file IDs
          final htmlContent = response.body;
          final imageUrls = <String>[];
          
          // Look for patterns like: "1ABC...XYZ"
          final fileIdPattern = RegExp(r'"(1[a-zA-Z0-9_-]{32,42})"');
          final matches = fileIdPattern.allMatches(htmlContent);
          final seenIds = <String>{};
          
          for (final match in matches) {
            final fileId = match.group(1);
            if (fileId != null && 
                fileId != folderId && 
                fileId.length >= 33 && 
                fileId.length <= 44 &&
                !seenIds.contains(fileId)) {
              
              seenIds.add(fileId);
              debugPrint('Found potential file: $fileId');
              
              // Use ultra-fast tiny thumbnail URL format for instant loading
              imageUrls.add('https://drive.google.com/thumbnail?id=$fileId&sz=w200-h200');
            }
          }
          
          if (imageUrls.isNotEmpty) {
            debugPrint('Found ${imageUrls.length} files in your public folder');
            return imageUrls;
          }
        }
      } catch (e) {
        debugPrint('Direct folder access failed: $e');
      }
      
      // If auto-discovery fails, provide manual setup instructions
      debugPrint('Auto-discovery failed - folder may need individual file sharing');
      return [];
      
    } catch (e) {
      debugPrint('Error accessing public folder: $e');
      return [];
    }
  }
  
  // Helper method to check if a filename is a valid image file
  bool _isValidImageFile(String fileName) {
    final lowerName = fileName.toLowerCase();
    return lowerName.endsWith('.jpg') || 
           lowerName.endsWith('.jpeg') || 
           lowerName.endsWith('.png') || 
           lowerName.endsWith('.gif') || 
           lowerName.endsWith('.webp');
  }
  
  // Ultra-fast preloading with memory optimization
  void _preloadImages(List<String> imageUrls) {
    // Preload in batches to avoid memory issues
    for (int i = 0; i < imageUrls.length; i++) {
      final url = imageUrls[i];
      try {
        // Use optimized network image with small cache
        final imageProvider = NetworkImage(
          url,
          headers: const {
            'User-Agent': 'Mozilla/5.0 (compatible)',
            'Accept': 'image/*',
            'Cache-Control': 'max-age=3600', // 1 hour cache
          },
        );
        precacheImage(imageProvider, context);
        
        // Small delay between preloads to avoid overwhelming the network
        if (i % 3 == 0 && i > 0) {
          Future.delayed(const Duration(milliseconds: 50));
        }
      } catch (e) {
        debugPrint('Failed to preload image: $url');
      }
    }
  }
  
  // Build image widget with faster loading and caching
  Widget _buildImageWithRetry(String imageUrl) {
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      // Ultra-aggressive performance optimizations
      cacheWidth: 150, // Even smaller cache for lightning speed
      cacheHeight: 150,
      filterQuality: FilterQuality.none, // Fastest possible decoding
      gaplessPlayback: true, // Smooth transitions
      // Ultra-optimized headers for maximum speed
      headers: const {
        'User-Agent': 'Mozilla/5.0 (Mobile; compatible)',
        'Accept': 'image/webp,image/jpeg,image/png,image/*;q=0.8',
        'Accept-Encoding': 'gzip, deflate',
        'Cache-Control': 'max-age=3600',
        'Connection': 'keep-alive',
      },
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          color: Colors.grey.shade100,
          child: Center(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Colors.blue.shade300,
                // Remove progress calculation for faster rendering
              ),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        debugPrint('Image load failed: $imageUrl');
        
        // Try alternative faster URL formats for Google Drive
        final fileId = imageUrl.contains('id=') 
            ? imageUrl.split('id=').last.split('&').first
            : imageUrl.split('thumbnail?id=').last.split('&').first;
        final alternativeUrl = 'https://drive.google.com/uc?export=view&id=$fileId';
        
        return Image.network(
          alternativeUrl,
          fit: BoxFit.cover,
          errorBuilder: (context, error2, stackTrace2) {
            debugPrint('Both URLs failed for file ID: $fileId');
            return Container(
              color: Colors.grey.shade100,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.image_not_supported, color: Colors.grey, size: 32),
                  const SizedBox(height: 4),
                  Text(
                    'Not accessible',
                    style: TextStyle(fontSize: 9, color: Colors.grey.shade600),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
  

  // Load an online image and set it as the current image
  // Preview: show only "In Frame" (left); processing happens on Send
  Widget _buildPreviewAndSliders(){
    return SizedBox(
      height: _isSending ? 190 : 210,
      child: Row(children:[
  if (_uiOriginal != null)
    Expanded(
      child: Builder(
        builder: (context){
          // Compute the same frame geometry used by the crop workspace so the preview updates instantly
          final double workspaceW = MediaQuery.of(context).size.width - 24; // body padding is 12 on both sides
          final double workspaceH = 300; // same as _buildCropFrame height - keep constant
          double frameW = workspaceW * 0.5;
          double frameH;
          if (_verticalFrame) {
            frameH = frameW * (IMAGE_WIDTH / IMAGE_HEIGHT);
          } else {
            frameH = frameW * (IMAGE_HEIGHT / IMAGE_WIDTH);
          }
          if (frameH > workspaceH) {
            frameH = workspaceH * 0.5;
            if (_verticalFrame) {
              frameW = frameH * (IMAGE_HEIGHT / IMAGE_WIDTH);
            } else {
              frameW = frameH * (IMAGE_WIDTH / IMAGE_HEIGHT);
            }
          }
          _frameOrigin = Offset(
            (workspaceW - frameW)/2,
            (workspaceH - frameH)/2,
          );
          return _previewPanel('In Frame', _croppedOriginalPreviewSized(frameW, frameH, _frameOrigin));
        },
      ),
    ),
      ]),
    );
  }

  // Build a preview representing only the area inside the back square (frame)
  Widget _croppedOriginalPreviewSized(double frameW, double frameH, Offset frameOrigin){
    // Render immediately; avoid showing any placeholder during quick orientation toggles.
    // Frame dimensions are recomputed in _buildCropFrame on every build.
    if (_uiOriginal == null || frameW==0 || frameH==0) {
      return const SizedBox.shrink();
    }
    // Draw the same transformed image, clipped to the frame area for smooth, GPU-accelerated preview
    return FittedBox(
      fit: BoxFit.contain,
      child: Builder(builder: (context){
        const double blackBorder = 12; // slightly thicker border
        const double whiteBorder = blackBorder * 2; // twice the black border
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.black, width: blackBorder),
          ),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.transparent, width: whiteBorder),
            ),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey, width: 1),
              ),
              child: SizedBox(
                width: frameW,
                height: frameH,
                child: CustomPaint(
                  painter: _CroppedPreviewPainter(
                    image: _uiOriginal!,
                    scale: _viewScale,
                    rotation: _viewRotation,
                    translation: _viewTranslation,
                    frameOrigin: frameOrigin,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  // Reusable titled preview container (adds spinner for processing state)
  Widget _previewPanel(String title, Widget child){
    return Column(children:[
      // Remove header row to eliminate vertical gap; overlay controls on the image instead
      Expanded(child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned.fill(child: child),
              // Small title badge top-left
              Positioned(
                top: 4,
                left: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ),
              // Battery status bottom-left inside the "In Frame" panel (no separate bar)
              if (title == 'In Frame' && _batteryPercent != null)
                Positioned(
                  left: 4,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.battery_full, color: Colors.white, size: 14),
                        const SizedBox(width: 4),
                        Text('$_batteryPercent%', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              // Refresh button top-right
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  onPressed: _resetView,
                  tooltip: 'Reset View',
                  icon: const Icon(Icons.refresh, size: 18),
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minHeight: 28, minWidth: 28),
                ),
              ),
            ],
          ),
        ),
      )),
    ]);
  }

  // Tuning sliders removed from connected view (Dithering/Color)


  

  // Reset pan/zoom/rotation to initial cover fit
  void _resetView(){
    if(_uiOriginal==null){ return; }
    setState((){
      _viewInitialized = false; // recompute cover scale next build
      _viewRotation = 0.0;
      // changing view invalidates processed cache
      _processedImage = null; _processedBytes = null; _processedPngBytes = null;
    });
  // auto disabled
  }

  Future<void> _exitApp() async {
    try{
      if(_isSending){ /* cannot easily cancel mid-chunks here; rely on disconnect */ }
      await _disconnectDevice();
    } catch(_){ }
    if(mounted){
      // Close the app (works on Android); on iOS this is discouraged
      SystemNavigator.pop();
    }
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
  void _updateStatus(String message, {bool force = false}) {
    final now = DateTime.now();
    if(_isSending && !force && now.difference(_lastStatusUpdate).inMilliseconds < 350 && !message.startsWith('Progress')){ return; }
    _lastStatusUpdate = now;
    if(mounted){ setState(()=> _statusMessage = message); }
  }

  // Verify actual BLE connection state; fields may be stale during reconnects
  Future<bool> _isReallyConnected() async {
    try {
      final dev = _connectedDevice;
      if (dev == null) return false;
      final state = await dev.connectionState.first;
      return state == BluetoothConnectionState.connected;
    } catch (_) {
      return false;
    }
  }

  // Pick an image from gallery and clear prior processed state
  Future<void> _pickImage() async {
    final XFile? pickedFile = await _picker.pickImage(source: ImageSource.gallery);
    
    if (pickedFile != null) {
  setState(() { _originalImage = File(pickedFile.path); _processedImage = null; _processedBytes = null; _processedPngBytes=null; _transferProgress = 0; _uiOriginal = null; _viewInitialized = false; });
    await _loadUiImage();
    // After selecting, adjust view then press Send
    }
  }

  Future<void> _loadUiImage() async {
    if (_originalImage == null) return;
    final bytes = await _originalImage!.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    setState(() { _uiOriginal = frame.image; });
  }

  // Process the selected image with current settings (generation-aware to avoid stale updates)
  // =============================================================
  // IMAGE PROCESSING PIPELINE (manual trigger) steps:
  // 1. Decode original file
  // 2. Sample into framed 800x480 (respect orientation & transforms)
  // 3. Apply enhancements (brightness/contrast/sat from Color slider)
  // 4. Quantize + optional Floyd–Steinberg dithering to 6-color palette
  // 5. Cache processed image + raw palette codes + PNG preview
  // Generation guard prevents stale results if user clicks multiple times.
  // =============================================================
  Future<void> _processImage() async {
    if (_originalImage == null) return;
    final int myGen = ++_processGen;
    _updateStatus("Processing image...");
    try {
      // Load the original image
      final Uint8List imageBytes = await _originalImage!.readAsBytes();
      img.Image? originalImage = img.decodeImage(imageBytes);
      if (originalImage == null) {
        _updateStatus("Failed to decode image");
        return;
      }
  // Build 800x480 from interactive frame (pan/zoom/rotate)
      img.Image resizedImage = _generateCroppedBaseImage(originalImage);
      if(mounted){ setState(()=> _processedPngBytes = null); } // clear cache to force rebuild
  // Quantize + create raw codes (one per pixel, to be packed later)
      Tuple2<img.Image, Uint8List> result = _quantizeTo6ColorAndCreateRawBytes(resizedImage);
      img.Image convertedImage = result.item1; // 800x480 (landscape)
      Uint8List processedBytes = result.item2;  // raw color codes length = 800*480
      // (Do not rotate here; rotation applied before packing when sending)
      if(myGen == _processGen){
        if(mounted){ setState(() {
          _processedImage = convertedImage;
          _processedBytes = processedBytes;
          _processedPngBytes = Uint8List.fromList(img.encodePng(convertedImage));
        }); }
        _updateStatus("Image processed successfully (${processedBytes.length} bytes)");
      }
    } catch (e) {
      _updateStatus("Error processing image: $e");
    }
  }

  // Sample original image into working 800x480 (or 480x800) using inverse transform (bilinear sampling)
  // rotatePortrait: when true (default), portrait crops are rotated to landscape (used for processing/sending)
  // when false, portrait crops are kept as portrait (used for UI preview)
  img.Image _generateCroppedBaseImage(img.Image source, {bool rotatePortrait = true}) {
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
      return rotatePortrait ? img.copyRotate(working, angle: 90) : working;
    }
    return working;
  }

  // Apply image enhancements (brightness, contrast, saturation)
  // Apply brightness / contrast / saturation boosts + simple color nudges toward hardware primaries.
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
  // Map each pixel to nearest of 6 hardware colors with optional Floyd–Steinberg dithering.
  // Returns display image (already palette colors) + raw per-pixel 8-bit code list.
  Tuple2<img.Image, Uint8List> _quantizeTo6ColorAndCreateRawBytes(img.Image image) {
  _updateEnhancementFromBoost();
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
        .map((m) => [(m.rgbColor.r * 255.0).round() & 0xff, (m.rgbColor.g * 255.0).round() & 0xff, (m.rgbColor.b * 255.0).round() & 0xff])
        .toList(growable: false);

    final Uint8List rawCodes = Uint8List(w * h);
    final img.Image displayImage = img.Image(width: w, height: h, format: img.Format.uint8);

    // Floyd–Steinberg weights
    const double w1 = 7 / 16, w2 = 3 / 16, w3 = 5 / 16, w4 = 1 / 16;
  final bool useDither = _ditherStrength > 0.01;

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
          final double strength = _ditherStrength.clamp(0.0,1.0);
          final double errR = (r - nr) * strength;
          final double errG = (g - ng) * strength;
          final double errB = (b - nb) * strength;
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
  // Convert raw 1-pixel-per-byte color codes into packed 2-pixels-per-byte (4 bits each) for BLE efficiency.
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
  _autoConnectTried = false;
    });
  _updateStatus("finding CanvasBT");
    
    try {
      // Check if Bluetooth is on
      var adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        _updateStatus("Bluetooth is turned off");
        setState(() {
          _isScanning = false;
        });
        return;
      }
      
      // Start scanning
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      
      // Listen for scan results
      // Cancel any previous listener to avoid duplicates
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          final advName = result.advertisementData.advName;
          final devName = result.device.advName;
          final name = advName.isNotEmpty ? advName : devName;
          if (name.isNotEmpty && !_devicesList.contains(result.device)) {
            setState(() { _devicesList.add(result.device); });
          }
          // Immediate auto-connect to first device whose name starts with EPD
          if(!_autoConnectTried && _connectedDevice==null && !_isConnecting) {
            final upper = name.toUpperCase();
            if(upper.startsWith('EPD')){
              _autoConnectTried = true;
              _updateStatus("Auto-connecting to $name");
              // Stop further scanning to speed up connect
              try { FlutterBluePlus.stopScan(); } catch(_){ }
              _connectToDevice(result.device);
              break; // exit loop
            }
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
      await _scanSub?.cancel(); _scanSub = null;
      
      if (_devicesList.isEmpty) {
        _updateStatus("No BLE devices found");
      } else {
        _updateStatus("Found ${_devicesList.length} BLE devices");
        // Find devices whose name begins with 'EPD'
        final epdDevices = _devicesList.where((d)=> d.advName.toUpperCase().startsWith('EPD')).toList();
        if(epdDevices.length == 1 && _connectedDevice==null && !_isConnecting){
          final target = epdDevices.first;
          _updateStatus("Auto-connecting to ${target.advName}");
          _connectToDevice(target);
        }
      }
    } catch (e) {
      _updateStatus("Error scanning: $e");
      setState(() {
        _isScanning = false;
      });
      await _scanSub?.cancel(); _scanSub = null;
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
      
      // Request MTU increase once per connection (no user-facing success message)
      if (!_mtuRequestedForThisConnection) {
        try {
          await device.requestMtu(512);
          _mtuRequestedForThisConnection = true;
        } catch (e) {
          _updateStatus("Could not negotiate MTU: $e");
          // Continue anyway with smaller chunks
        }
      }
      
      // Discover services with timeout to prevent hanging
      _updateStatus("Discovering services...");
      List<BluetoothService> services;
      try {
        services = await device.discoverServices().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw Exception("Service discovery timed out after 5 seconds");
          },
        );
      } catch (e) {
        // If service discovery fails, try reconnecting once
        _updateStatus("Service discovery failed, retrying connection...");
        await device.disconnect();
        await Future.delayed(const Duration(milliseconds: 500));
        await device.connect();
        services = await device.discoverServices().timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            throw Exception("Service discovery timed out on retry");
          },
        );
      }
      
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
  // Remain on the connected UI; first window was removed
      });
      // If the popup was visible (user tapped while disconnected), close it
      if(_activeDialogContext != null){
        _dismissActiveDialog();
        await Future.delayed(const Duration(milliseconds: 100));
      }
      // Resume the intended action if one is pending (even if dialog was already closed)
      if (_pendingSend != _PendingSend.none) {
        final intent = _pendingSend;
        _pendingSend = _PendingSend.none;
        if (intent == _PendingSend.ota) {
          unawaited(_sendOtaFile());
        } else if (intent == _PendingSend.image) {
          unawaited(_sendOrProcessThenSend());
        }
      }
      // Listen for future connection state changes and auto-reconnect
      await _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((s) async {
        if(s == BluetoothConnectionState.disconnected){
          if(mounted){
            setState((){
              _connectedDevice = null;
              _rxCharacteristic = null;
              // Reset version check state to avoid flickering on reconnect
              _versionCheckCompleted = false;
              _isCheckingVersion = false;
              _otaButtonEnabled = false;
              // Keep showing the second screen UI; auto-reconnect runs in background
            });
            _updateStatus('Device disconnected. Reconnecting...');
          }
          _mtuRequestedForThisConnection = false; // reset for next connection
          // Keep pending send true so it resumes on reconnect
          if(!_isScanning && !_isConnecting){ _scanForDevices(); }
        }
      });
      
      _updateStatus("Connected to ${device.advName}");
      
      // Check firmware version after successful connection
      _checkFirmwareVersion();
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

    // First, try to decode as UTF-8 text message before treating as binary ACK.
    // This handles ASCII status messages like "Touch(15) = 69  Battery=82%"  
    // where the first byte (T=84) would otherwise be treated as unknown ACK.
    bool handled = false;
    try {
      final String msg = utf8.decode(data).trim();
      // Check if the decoded string contains mostly printable characters
      if (msg.isNotEmpty && msg.length >= 3) {
        bool isPrintable = true;
        for (int rune in msg.runes) {
          if (rune < 32 || rune > 126) {
            // Allow common whitespace chars but reject control chars
            if (rune != 9 && rune != 10 && rune != 13) {
              isPrintable = false;
              break;
            }
          }
        }
        
        if (isPrintable) {
          // Update battery if the message contains a "Battery=" token
          final battMatch = RegExp(r'Battery\s*=\s*(\d{1,3})').firstMatch(msg);
          if (battMatch != null) {
            final int batt = int.parse(battMatch.group(1)!).clamp(0, 100);
            setState((){ _batteryPercent = batt; });
            _updateStatus('$msg');
          } else {
            _updateStatus(msg);
          }
          handled = true;
        }
      }
    } catch (_) {
      // UTF-8 decode failed, treat as binary data
      handled = false;
    }

    if (handled) return;

    switch (ackType) {
      case ACK_BATTERY:
        if (data.length >= 2) {
          final int batt = data[1].clamp(0, 100);
          setState((){ _batteryPercent = batt; });
          _updateStatus("Battery = $batt%");
        }
        break;
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
      
      final Uint8List src = _processedBytes!; // raw codes length w*h
      Uint8List toSend;
      
      // Apply appropriate rotation based on orientation mode
      // Hardware displays require specific rotation for correct rendering
      if (_verticalFrame) {
        // PORTRAIT MODE: Apply standard 180° rotation
        toSend = _applyPortraitModeRotation(src);
        _updateStatus("Applied portrait mode rotation (180°)");
      } else {
        // LANDSCAPE MODE: Apply special landscape rotation
        toSend = _applyLandscapeModeRotation(src);
        _updateStatus("Applied landscape mode rotation");
      }
      
      // Pack the rotated image data for efficient BLE transfer (2 pixels per byte)
      Uint8List packedData = _packPixels(toSend);
      _updateStatus("Packed data size: ${packedData.length} bytes", force: true);
      
      // First send a 1-byte type + 4-byte little-endian size header
      int totalSize = packedData.length;
      final header = Uint8List(5);
      header[0] = TRANSFER_TYPE_IMAGE;
      final bd = ByteData.view(header.buffer);
      bd.setUint32(1, totalSize, Endian.little);
      // Send the header
      await _rxCharacteristic!.write(header);
      _updateStatus("Sent image header: $totalSize bytes", force: true);
      
      // Short delay to ensure Arduino processes the header
      await Future.delayed(const Duration(milliseconds: 12));
      
      // Start the transfer timer
      int startTime = DateTime.now().millisecondsSinceEpoch;
      int bytesSent = 0;
      
      // Stream chunks without allocating new lists (zero-copy views)
      int dynamicChunk = BLE_CHUNK_SIZE;
      final int totalChunks = (packedData.length + dynamicChunk - 1) ~/ dynamicChunk;
      _updateStatus("Sending $totalChunks chunks...", force: true);
      for (int i = 0; i < packedData.length;) {
        // Bound chunk by remaining bytes and current dynamic chunk size
        final int end = math.min(i + dynamicChunk, packedData.length);
        final Uint8List view = Uint8List.sublistView(packedData, i, end);
        // Only show status updates occasionally to reduce overhead
        final int chunkIndex = (i ~/ (dynamicChunk == 0 ? 1 : dynamicChunk));
        if (chunkIndex % 20 == 0 || end == packedData.length) {
          _updateStatus("Sending chunk ${chunkIndex+1}/$totalChunks", force: true);
        }
        
        try {
          await _rxCharacteristic!.write(view, withoutResponse: true);
          bytesSent += view.length;
          // Very small pacing prevents peripheral overflow while keeping speed high
          await Future.delayed(const Duration(milliseconds: 1));
          // Advance only on success
          i = end;
        } catch (e) {
          _updateStatus("Error sending chunk at $i (size ${view.length}): $e", force: true);
          // Adaptive fallback: reduce dynamic chunk size and retry same offset
          dynamicChunk = math.max(20, dynamicChunk ~/ 2);
          await Future.delayed(const Duration(milliseconds: 25));
          if (dynamicChunk <= 20 && view.length <= 20) {
            // Even the smallest failed; abort
            throw Exception("BLE data transfer failed at offset $i: $e");
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
      
      _updateStatus("Data transfer complete: $totalSize bytes in ${totalTime.toStringAsFixed(2)} seconds", force: true);
      _updateStatus("Average speed: ${avgSpeed.toStringAsFixed(2)} KB/s", force: true);
      
      // We don't set _isSending to false here - wait for ACK_COMPLETE
    } catch (e) {
  _updateStatus("Error sending data: $e", force: true);
      setState(() {
        _isSending = false;
      });
    }
  }

  // =====================================================================
  // IMAGE ROTATION HELPERS
  // =====================================================================
  // These methods handle the hardware-specific rotation requirements for
  // the e-paper display. The display hardware expects images in specific
  // orientations depending on the display mode.
  // =====================================================================

  /// Applies rotation for PORTRAIT mode images
  /// Portrait images need a standard 180° rotation to display correctly
  /// on the e-paper hardware.
  /// 
  /// The 180° rotation is achieved by:
  /// 1. Vertical flip (mirror along horizontal axis)
  /// 2. Horizontal flip (mirror along vertical axis)
  /// 
  /// @param src The source image data as raw color codes (800x480 pixels)
  /// @return Rotated image data ready for display
  Uint8List _applyPortraitModeRotation(Uint8List src) {
    const int imageWidth = IMAGE_WIDTH;   // 800 pixels
    const int imageHeight = IMAGE_HEIGHT; // 480 pixels
    
    // Step 1: Vertical flip - flip the image upside down
    // This mirrors the image along the horizontal axis
    final Uint8List verticallyFlipped = _flipImageVertically(src, imageWidth, imageHeight);
    
    // Step 2: Horizontal flip - flip the image left to right
    // This mirrors the image along the vertical axis
    // Combined with vertical flip, this achieves 180° rotation
    final Uint8List fullyRotated = _flipImageHorizontally(verticallyFlipped, imageWidth, imageHeight);
    
    return fullyRotated;
  }

  /// Applies rotation for LANDSCAPE mode images
  /// Landscape images may need different rotation based on hardware requirements.
  /// 
  /// Current implementation applies double 180° rotation (360° total) which
  /// effectively results in no rotation. This can be modified based on
  /// specific hardware display requirements.
  /// 
  /// @param src The source image data as raw color codes (800x480 pixels)
  /// @return Rotated image data ready for display
  Uint8List _applyLandscapeModeRotation(Uint8List src) {
    const int imageWidth = IMAGE_WIDTH;   // 800 pixels
    const int imageHeight = IMAGE_HEIGHT; // 480 pixels
    
    // For landscape mode, we apply double rotation (360° total)
    // This can be modified to apply single 180° rotation if needed
    
    // First 180° rotation
    Uint8List rotated180 = _rotate180Degrees(src, imageWidth, imageHeight);
    
    // Second 180° rotation (total 360°)
    // Comment out the next line if you want only 180° rotation for landscape
    Uint8List rotated360 = _rotate180Degrees(rotated180, imageWidth, imageHeight);
    
    return rotated360;
  }

  /// Performs a complete 180° rotation on image data
  /// Combines vertical and horizontal flips to achieve rotation
  /// 
  /// @param src Source image data
  /// @param width Image width in pixels
  /// @param height Image height in pixels
  /// @return 180° rotated image
  Uint8List _rotate180Degrees(Uint8List src, int width, int height) {
    // First flip vertically
    Uint8List verticallyFlipped = _flipImageVertically(src, width, height);
    // Then flip horizontally to complete 180° rotation
    return _flipImageHorizontally(verticallyFlipped, width, height);
  }

  /// Flips an image vertically (upside down)
  /// Mirrors the image along the horizontal axis
  /// 
  /// @param src Source image data
  /// @param width Image width in pixels  
  /// @param height Image height in pixels
  /// @return Vertically flipped image
  Uint8List _flipImageVertically(Uint8List src, int width, int height) {
    final Uint8List result = Uint8List(src.length);
    
    // Swap rows: first row becomes last, second becomes second-to-last, etc.
    for (int y = 0; y < height; y++) {
      final int sourceRowStart = y * width;
      final int targetRowStart = (height - 1 - y) * width;
      
      // Copy entire row from source position to target position
      result.setRange(targetRowStart, targetRowStart + width, src, sourceRowStart);
    }
    
    return result;
  }

  /// Flips an image horizontally (left to right)
  /// Mirrors the image along the vertical axis
  /// 
  /// @param src Source image data
  /// @param width Image width in pixels
  /// @param height Image height in pixels  
  /// @return Horizontally flipped image
  Uint8List _flipImageHorizontally(Uint8List src, int width, int height) {
    final Uint8List result = Uint8List(src.length);
    
    // For each row, reverse the order of pixels
    for (int y = 0; y < height; y++) {
      final int rowStart = y * width;
      
      // Swap pixels within the row: first becomes last, etc.
      for (int x = 0; x < width; x++) {
        result[rowStart + (width - 1 - x)] = src[rowStart + x];
      }
    }
    
    return result;
  }

  // =====================================================================
  // END OF IMAGE ROTATION HELPERS
  // =====================================================================

  Future<void> _sendOtaFile() async {
    if (!await _isReallyConnected()) {
      setState((){ _connectedDevice = null; _rxCharacteristic = null; });
      _updateStatus("Not connected. Trying to connect...");
      // Reuse the same UX pattern as _sendOrProcessThenSend when disconnected
      if(!mounted) return;
      final String? fingerAsset = await _resolveFingerAssetForOrientation(_verticalFrame);
      _pendingSend = _PendingSend.ota; // remember user's intent
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx){
          _activeDialogContext = ctx;
          return AlertDialog(
            title: const Text('Please Touch the frame'),
            content: fingerAsset==null
              ? const SizedBox.shrink()
              : SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: 16/9,
                        child: Image.asset(fingerAsset, fit: BoxFit.contain),
                      ),
                    ],
                  ),
                ),
            actions: [
              TextButton(onPressed: (){ Navigator.of(ctx).pop(); }, child: const Text('Close')),
            ],
          );
        }
      );
      _activeDialogContext = null;
      // Only clear intent if still disconnected (manual dismiss). If connected, keep for auto-resume.
      final stillDisconnected = (_connectedDevice == null || _rxCharacteristic == null);
      if (stillDisconnected) {
        _pendingSend = _PendingSend.none;
      }
      return;
    }
    if (_isSending) {
      _updateStatus("Another transfer is in progress");
      return;
    }

    try {
      // Load first available bin from assets/OTAFile
      Uint8List? otaBytes;
      final candidates = [
        'OTAFile/firmware.bin',
        'OTAFile/ota.bin',
        'OTAFile/update.bin',
        'OTAFile/Spectra6.ino.bin',
      ];
      for (final path in candidates) {
        try {
          final bd = await rootBundle.load(path);
          otaBytes = bd.buffer.asUint8List();
          _updateStatus("Loaded OTA: ${path.split('/').last} (${otaBytes.length} bytes)");
          break;
        } catch (_) {}
      }
      if (otaBytes == null || otaBytes.isEmpty) {
        _updateStatus("No OTA .bin found in assets/OTAFile");
        return;
      }

      setState(() {
        _isSending = true;
        _transferProgress = 0;
        _transferSpeed = 0;
      });

      // Protocol: send 1-byte type (OTA) + 4-byte LE size then raw chunks
      final totalSize = otaBytes.length;
      final header = Uint8List(5);
      header[0] = TRANSFER_TYPE_OTA;
      final bd = ByteData.view(header.buffer);
      bd.setUint32(1, totalSize, Endian.little);
      await _rxCharacteristic!.write(header);
  await Future.delayed(const Duration(milliseconds: 10));

      final start = DateTime.now().millisecondsSinceEpoch;
      int sent = 0;
      int dynamicChunkOta = BLE_CHUNK_SIZE;
      for (int i = 0; i < otaBytes.length;) {
        final end = (i + dynamicChunkOta > otaBytes.length) ? otaBytes.length : i + dynamicChunkOta;
        final view = Uint8List.sublistView(otaBytes, i, end);
        try {
          await _rxCharacteristic!.write(view, withoutResponse: true);
          sent = end;
          i = end;
        } catch (e) {
          _updateStatus("OTA: error at $i (size ${view.length}): $e", force: true);
          dynamicChunkOta = math.max(20, dynamicChunkOta ~/ 2);
          await Future.delayed(const Duration(milliseconds: 25));
          if (dynamicChunkOta <= 20 && view.length <= 20) {
            throw Exception("OTA failed at offset $i: $e");
          }
          continue;
        }

        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsed = (now - start) / 1000.0;
        final speed = elapsed > 0 ? (sent / 1024.0) / elapsed : 0.0;
        final progress = (sent * 100 ~/ totalSize);
        setState(() { _transferSpeed = speed; _transferProgress = progress; });

        if (i % (BLE_CHUNK_SIZE * 20) == 0) {
          _updateStatus("OTA $progress% - ${speed.toStringAsFixed(1)} KB/s");
        }
        await Future.delayed(const Duration(milliseconds: 1));
      }

      final end = DateTime.now().millisecondsSinceEpoch;
      final totalSec = (end - start) / 1000.0;
      final avg = (totalSize / 1024.0) / totalSec;
      _updateStatus("OTA data sent: $totalSize bytes in ${totalSec.toStringAsFixed(2)}s, ${avg.toStringAsFixed(1)} KB/s");
      // keep _isSending true until ACK_COMPLETE from device
    } catch (e) {
      _updateStatus("OTA send failed: $e");
      setState(() { _isSending = false; });
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      image: DecorationImage(
        image: AssetImage('FramePic/backgroundImage.png'),
        fit: BoxFit.cover,
        alignment: Alignment.center,
      ),
    ),
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const SizedBox.shrink(),
        toolbarHeight: _headerAspectRatio!=null ? MediaQuery.of(context).size.width / _headerAspectRatio! : 88,
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: (_headerAsset!=null)
            ? SafeArea(
                bottom: false,
                child: SizedBox.expand(
                  child: Image.asset(
                    _headerAsset!,
                    fit: BoxFit.fitWidth,
                    alignment: Alignment.center,
                  ),
                ),
              )
            : null,
      ),
      body: Padding(padding: const EdgeInsets.all(12), child: _buildConnected()),
    ),
  );

  // First window removed; no _buildDisconnected() screen.

  Widget _statusCard() => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Status: ',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        Expanded(
          child: Text(
            _statusMessage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );

  Widget _buildCropFrame() {
    return SizedBox(
      height: 300, // keep constant to prevent image shift during sending
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
          _frameHeight = workspaceH * 0.5;
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
          // scale so entire image fits within frame and center translation
          final fitScale = math.min(_frameWidth / iw, _frameHeight / ih);
          _viewScale = fitScale;
          // Allow zooming out to a small fraction of fit scale, in, to large magnification
          _minScale = fitScale * 0.01; // 1% of fit size (very far zoom out)
          if (_minScale < 0.005) _minScale = 0.005;
          _maxScale = fitScale * 80; // very deep zoom possible
          // center image in workspace and ensure no rotation
          _viewRotation = 0.0;
          _viewTranslation = Offset(
            (workspaceW - iw*fitScale)/2,
            (workspaceH - ih*fitScale)/2,
          );
          _viewInitialized = true;
          // Cropped preview now paints directly; no PNG cache needed
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
              // any crop change invalidates processed cache
              _processedImage=null; _processedBytes=null; _processedPngBytes=null;
            });
            // Cropped preview now uses GPU painter; no heavy work here
          },
          onScaleEnd: (d){},
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
              // Frame overlay (border only)
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
                    color: Colors.black.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                        onPressed: (){ setState((){ _viewScale = (_viewScale * 1.25).clamp(_minScale, _maxScale); _processedImage=null; _processedBytes=null; _processedPngBytes=null; }); },
                        tooltip: 'Zoom In',
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove, color: Colors.white, size: 20),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minHeight: 36, minWidth: 36),
                        onPressed: (){ setState((){ _viewScale = (_viewScale / 1.25).clamp(_minScale, _maxScale); _processedImage=null; _processedBytes=null; _processedPngBytes=null; }); },
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
    paintImage(canvas: canvas, rect: Rect.fromLTWH(0,0,img.width.toDouble(), img.height.toDouble()), image: img, fit: BoxFit.fill, alignment: Alignment.center);
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _WorkspacePainter old)=> old.image!=image || old.scale!=scale || old.rotation!=rotation || old.translation!=translation;
}

// Cropped preview painter: draws the transformed image clipped to the frame rectangle
class _CroppedPreviewPainter extends CustomPainter {
  final ui.Image image; final double scale; final double rotation; final Offset translation; final Offset frameOrigin;
  const _CroppedPreviewPainter({required this.image, required this.scale, required this.rotation, required this.translation, required this.frameOrigin});
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Clip to the preview canvas (which we sized to frameWidth x frameHeight)
    canvas.clipRect(Offset.zero & size);
    // Apply inverse of frame origin to align with workspace coords
    canvas.translate(-frameOrigin.dx, -frameOrigin.dy);
    // Apply same transforms as workspace painter
    canvas.translate(translation.dx, translation.dy);
    canvas.rotate(rotation);
    canvas.scale(scale, scale);
    paintImage(canvas: canvas, rect: Rect.fromLTWH(0,0,image.width.toDouble(), image.height.toDouble()), image: image, fit: BoxFit.fill, alignment: Alignment.center);
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant _CroppedPreviewPainter old)=> old.image!=image || old.scale!=scale || old.rotation!=rotation || old.translation!=translation || old.frameOrigin!=frameOrigin;
}

// Helper class for color mapping
class ColorMap {
  final int code;
  final Color rgbColor;
  
  const ColorMap(this.code, this.rgbColor);
}

class _LibraryEntry {
  final String id; // unique id or asset id
  final img.Image image; // 800x480 processed 6-color image
  final Uint8List rawCodes; // raw color codes (one per pixel)
  final Uint8List pngBytes; // cached PNG for thumbnail
  final DateTime created;
  final bool wasVertical; // orientation when saved
  final bool isDefaultAsset; // true if from bundled assets
  final String title; // display name
  const _LibraryEntry({required this.id, required this.image, required this.rawCodes, required this.pngBytes, required this.created, required this.wasVertical, required this.isDefaultAsset, required this.title});
}

// Default asset list (landscape). Updated to new "Cat" and "Leaves" images under SamplePics.
const List<String> kDefaultAssetImages = [
  'SamplePics/Cat.png',
  'SamplePics/Leaves.png',
];

extension _LibraryPersistence on _EPaperImageSenderState {
  Future<void> _initPersistentLibrary() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _libraryDir = Directory('${dir.path}/library');
      if(!await _libraryDir!.exists()){
        await _libraryDir!.create(recursive: true);
      }
      final indexFile = File('${_libraryDir!.path}/index.json');
      final firstLaunch = !await indexFile.exists();
      if(!firstLaunch){
        await _loadLibraryIndex(indexFile);
        await _removeObsoletePortraitAssets(); // drop old lion/umbrella portrait defaults
        await _ensureDefaultAssetsPresent(); // add new cat/leaves if missing
      }
      if(firstLaunch){
        final defaults = await _resolveDefaultAssetList();
        for(final assetPath in defaults){
          try{
            final data = await rootBundle.load(assetPath);
            final bytes = data.buffer.asUint8List();
            final decoded = img.decodeImage(bytes);
            if(decoded==null) continue;
            final fitted = _fitImage(decoded);
            final result = _quantizeTo6ColorAndCreateRawBytes(fitted);
            final display = result.item1;
            final raw = result.item2;
            final png = Uint8List.fromList(img.encodePng(display));
            final baseName = assetPath.split('/').last.toLowerCase();
            final entry = _LibraryEntry(
              id: 'asset_${assetPath.split('/').last}',
              image: display.clone(),
              rawCodes: raw,
              pngBytes: png,
              created: DateTime.now(),
              wasVertical: _isPortraitAsset(baseName),
              isDefaultAsset: true,
              title: 'Saved',
            );
            _library.add(entry);
            await _persistLibraryEntry(entry, writeIndex:false);
          }catch(_){ }
        }
        await _writeLibraryIndex();
      }
  _refresh();
    } catch (e) {
      _updateStatus('Library init error: $e');
    }
  }

  Future<void> _loadLibraryIndex(File indexFile) async {
    try{
      final text = await indexFile.readAsString();
      final data = jsonDecode(text);
      if(data is! List) return;
      for(final item in data){
        if(item is! Map) continue;
        final id = item['id'] as String?; if(id==null) continue;
        final wasVertical = item['wasVertical'] == true;
        final createdMs = item['created'] as int? ?? DateTime.now().millisecondsSinceEpoch;
        final rawFile = File('${_libraryDir!.path}/$id.raw');
        final pngFile = File('${_libraryDir!.path}/$id.png');
        if(await rawFile.exists() && await pngFile.exists()){
          try{
            final rawCodes = await rawFile.readAsBytes();
            final pngBytes = await pngFile.readAsBytes();
            final decoded = img.decodeImage(pngBytes);
            if(decoded==null) continue;
            final isAsset = id.startsWith('asset_');
            final baseName = isAsset ? id.replaceFirst('asset_','').toLowerCase() : id.toLowerCase();
            final title = (item['title'] as String?) ?? (isAsset ? _deriveAssetTitle(baseName) : 'Saved');
            final correctedPortrait = isAsset ? _isPortraitAsset(baseName) : wasVertical;
            _library.add(_LibraryEntry(
              id: id,
              image: decoded.clone(),
              rawCodes: Uint8List.fromList(rawCodes),
              pngBytes: pngBytes,
              created: DateTime.fromMillisecondsSinceEpoch(createdMs),
              wasVertical: correctedPortrait,
              isDefaultAsset: isAsset,
              title: title,
            ));
          }catch(_){ }
        }
      }
    }catch(e){ _updateStatus('Load library error: $e'); }
  }

  Future<void> _persistLibraryEntry(_LibraryEntry entry, {bool writeIndex = true}) async {
    try{
      if(_libraryDir==null) return;
      final rawFile = File('${_libraryDir!.path}/${entry.id}.raw');
      final pngFile = File('${_libraryDir!.path}/${entry.id}.png');
      await rawFile.writeAsBytes(entry.rawCodes, flush: true);
      await pngFile.writeAsBytes(entry.pngBytes, flush: true);
      if(writeIndex){ await _writeLibraryIndex(); }
    }catch(e){ _updateStatus('Persist error: $e'); }
  }

  Future<void> _writeLibraryIndex() async {
    try{
      if(_libraryDir==null) return;
      final indexFile = File('${_libraryDir!.path}/index.json');
      final list = _library.map((e)=>{
        'id': e.id,
        'created': e.created.millisecondsSinceEpoch,
        'wasVertical': e.wasVertical,
      }).toList();
      await indexFile.writeAsString(jsonEncode(list), flush: true);
    }catch(e){ _updateStatus('Index write error: $e'); }
  }

  Future<void> _deleteLibraryEntryFiles(_LibraryEntry entry) async {
    try{
      if(_libraryDir==null) return;
      final rawFile = File('${_libraryDir!.path}/${entry.id}.raw');
      final pngFile = File('${_libraryDir!.path}/${entry.id}.png');
      if(await rawFile.exists()) { await rawFile.delete(); }
      if(await pngFile.exists()) { await pngFile.delete(); }
      await _writeLibraryIndex();
    }catch(e){ _updateStatus('Delete file error: $e'); }
  }

  // Discover asset images under SamplePics/ by reading the AssetManifest (handles arbitrary filenames)
  Future<List<String>> _discoverAssetManifestImages() async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = jsonDecode(manifestJson);
      final list = manifestMap.keys.where((k)=> k.startsWith('SamplePics/') && (k.endsWith('.png')||k.endsWith('.jpg')||k.endsWith('.jpeg'))).toList();
      list.sort();
      return list;
    }catch(_){ return const []; }
  }

  // Merge explicit list + discovered list (avoid duplicates)
  Future<List<String>> _resolveDefaultAssetList() async {
    final discovered = await _discoverAssetManifestImages();
    final set = <String>{};
    for(final p in kDefaultAssetImages){ set.add(p); }
    for(final p in discovered){ set.add(p); }
    return set.where((p)=> p.startsWith('SamplePics/')).toList();
  }

  // Add any missing default assets not already in library (id uses filename)
  Future<void> _ensureDefaultAssetsPresent() async {
    final defaults = await _resolveDefaultAssetList();
    final existingIds = _library.map((e)=> e.id).toSet();
    bool added = false;
    for(final assetPath in defaults){
      final assetId = 'asset_${assetPath.split('/').last}';
      if(existingIds.contains(assetId)) continue;
      try{
        final data = await rootBundle.load(assetPath);
        final bytes = data.buffer.asUint8List();
        final decoded = img.decodeImage(bytes);
        if(decoded==null) continue;
        final fitted = _fitImage(decoded);
        final result = _quantizeTo6ColorAndCreateRawBytes(fitted);
        final display = result.item1;
        final raw = result.item2;
        final png = Uint8List.fromList(img.encodePng(display));
        final baseName = assetPath.split('/').last.toLowerCase();
        final entry = _LibraryEntry(
          id: assetId,
          image: display.clone(),
          rawCodes: raw,
          pngBytes: png,
          created: DateTime.now(),
          wasVertical: _isPortraitAsset(baseName),
          isDefaultAsset: true,
          title: _deriveAssetTitle(baseName),
        );
        _library.add(entry);
        await _persistLibraryEntry(entry, writeIndex:false);
        added = true;
      }catch(_){ }
    }
    if(added){ await _writeLibraryIndex(); _refresh(); }
  }

  // Remove obsolete default portrait assets (lion / umbrella) that previously caused rotation issues.
  Future<void> _removeObsoletePortraitAssets() async {
  final obsolete = _library.where((e)=> e.isDefaultAsset && (e.id.contains('lion') || e.id.contains('umbrella'))).toList();
    if(obsolete.isEmpty) return;
    for(final e in obsolete){
      _library.remove(e);
      try{ await _deleteLibraryEntryFiles(e); }catch(_){ }
    }
    await _writeLibraryIndex();
    _refresh();
  }
}

// ===== Asset naming & orientation helpers (global) =====
String _deriveAssetTitle(String lowerName){
  if(lowerName.contains('cat')) return 'Cat';
  if(lowerName.contains('leaves') || lowerName.contains('leaf')) return 'Leaves';
  if(lowerName.contains('eye')) return 'Eye';
  if(lowerName.contains('lips')) return 'Lips';
  return lowerName.split('.').first;
}
bool _isPortraitAsset(String lowerName){
  // All new default assets (cat, leaves) are landscape -> always false here.
  return false;
}
