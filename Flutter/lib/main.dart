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
      // Keep UI consistent across devices by capping text scaling
      builder: (context, child){
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: const TextScaler.linear(1.0)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const EPaperImageSender(),
    );
  }
}

class EPaperImageSender extends StatefulWidget {
  const EPaperImageSender({super.key});

  @override
  State<EPaperImageSender> createState() => _EPaperImageSenderState();
}

class _EPaperImageSenderState extends State<EPaperImageSender> with SingleTickerProviderStateMixin {
  // GlobalKey for accessing scaffold context in async methods
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
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
  static const int ACK_CHARGING = 0xB1; // Charging status notification
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
  bool _isCharging = false; // charging status from device
  // Periodic connection status for bottom bar
  Timer? _connectionStatusTimer;
  Timer? _batteryStatusTimer; // Poll battery while charging
  Timer? _statusMessageTimer; // Clear status message after 3 seconds
  String _connectionStatusText = 'Not connected';
  // Stay on the second screen even if temporarily disconnected (for background auto-reconnect)
  // First window removed; app always starts on connected UI.
  // Header/logo asset (FramePic/CanvasBT.*) to show in the AppBar
  String? _headerAsset;
  double? _headerAspectRatio; // width / height for dynamic AppBar height
  // Splash intro state
  bool _showIntro = true;
  late final AnimationController _introCtrl;
  late final Animation<double> _introScale;
  late final Animation<double> _introOpacity;

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
  bool _needsRecenteringOnce = false; // request recenter after next frame recompute
  bool _isPortrait = false; // portrait orientation toggle
  Color _frameBorderColor = Colors.black; // dynamically adjusted for contrast
  // Slider-driven tuning
  final double _ditherStrength = 1.0; // 0=off .. 1=full
  final double _strongColorBoost = 1.0; // influences brightness/contrast/saturation mapping (default max)

  // =============================================================
  // IN-MEMORY SAVED IMAGES (session only)
  // =============================================================
  final List<_LibraryEntry> _library = [];
  int? _selectedLibraryIndex; // selected index in saved images view
  bool _showLibrary = false; // toggle to show SAVED IMAGES window when connected
  bool _showOnline = false; // toggle to show LIBRARY (Pixabay online images) window when connected
  // Pixabay state (Library window with online images)
  static const String _pixabayApiKey = '53177368-45f6645edfdd15979265678fc';
  final TextEditingController _pixabaySearchController = TextEditingController();
  List<_PixabayImage> _pixabayResults = [];
  int? _selectedPixabayIndex;
  bool _isPixabaySearching = false;
  bool _isPixabayImporting = false;
  String? _pixabayError;
  // Pixabay categories
  static const List<String> _pixabayCategories = [
    'all','backgrounds','fashion','nature','science','education','feelings','health','people','religion','places','animals','industry','computer','food','sports','transportation','travel','buildings','business','music'
  ];
  String _selectedPixabayCategory = 'all';
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
    // Initialize animated splash
    _introCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _introScale = CurvedAnimation(parent: _introCtrl, curve: Curves.easeOutBack);
    _introOpacity = CurvedAnimation(parent: _introCtrl, curve: Curves.easeIn);
  _introCtrl.forward();
  Future.delayed(const Duration(milliseconds: 1800), (){ if(mounted){ setState(()=> _showIntro = false); } });
    
    // Track Bluetooth adapter state
    _btStateSub = FlutterBluePlus.adapterState.listen((s){
      final isOn = (s == BluetoothAdapterState.on);
      // If Bluetooth just turned ON and we are not connected, kick off auto scan/connect
      if(isOn && _connectedDevice==null && !_isScanning){
        _scanForDevices();
      }
    });
    
    // Initialize app after first frame with proper sequencing
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Step 1: Request permissions
      await _checkPermissions();
      
      // Step 2: Initialize Library and load first image
      await _initPersistentLibrary();
      if(mounted){ await _tryLoadFirstLibraryImageOnStartup(); }
      
      // Step 3: Ensure Bluetooth is ON (prompt user if needed)
      await _ensureBluetoothOnAtLaunch();
      
      // Step 4: If Bluetooth is already ON, start initial scan
      if(mounted){
        try {
          final state = await FlutterBluePlus.adapterState.first;
          print('Initial Bluetooth state: $state');
          if(state == BluetoothAdapterState.on && _connectedDevice == null && !_isScanning){
            print('Starting initial BLE scan after app launch...');
            // Add small delay to ensure permissions are fully processed
            await Future.delayed(const Duration(milliseconds: 500));
            if(mounted && _connectedDevice == null && !_isScanning){
              _scanForDevices();
            }
          } else {
            print('Skipping initial scan - BT off or already connected/scanning');
          }
        } catch(e){
          print('Error checking initial Bluetooth state: $e');
        }
      }
    });
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
      // Keep current orientation - don't restore saved orientation
      _viewInitialized = false;
    });
    // Decode PNG to ui.Image for the crop workspace so it renders in the first window
    try{
      final codec = await ui.instantiateImageCodec(e.pngBytes);
      final frame = await codec.getNextFrame();
      final ui.Image decoded = frame.image; // Load exactly as stored - no automatic rotation
      if(mounted){ setState(()=> _uiOriginal = decoded); }
    }catch(_){ /* ignore; PNG fallback remains */ }
  }

  // Removed auto-rotation helper to enforce strict no-auto-rotation behavior

  // First window removed: no promo strip loader

  Future<void> _loadHeaderAsset() async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestJson);
  // Use lowercase directory name 'Framepic/' matching pubspec to ensure assets appear in release APK.
  final keys = manifestMap.keys.where((k)=> (k.startsWith('Framepic/') || k.startsWith('SamplePics/')) ).toList();
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
    if(_showIntro){
      // If splash still showing, stop animation controller safely
      try{ _introCtrl.stop(); }catch(_){ }
    }
    try{ _introCtrl.dispose(); }catch(_){ }
    _btStateSub?.cancel();
    _scanSub?.cancel(); _scanSub = null;
    _connStateSub?.cancel(); _connStateSub = null;
    _connectionStatusTimer?.cancel();
    _batteryStatusTimer?.cancel();
    _statusMessageTimer?.cancel();
    _aiPromptController.dispose();
    _pixabaySearchController.dispose();
    _disconnectDevice();
    super.dispose();
  }

  void _dismissActiveDialog(){
    try{
      final ctx = _activeDialogContext;
      if(ctx!=null && ctx.mounted){
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
      // list of candidate image assets under Framepic/ or SamplePics/
      final keys = manifestMap.keys.where((k){
        if(!(k.startsWith('Framepic/') || k.startsWith('SamplePics/'))) return false;
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

  // Calculate average brightness of image area behind the frame for contrast adjustment
  void _updateFrameBorderColor() {
    // Use _processedImage if available since it's img.Image with pixel access
    final imgObj = _processedImage;
    if (imgObj == null) {
      _frameBorderColor = Colors.black;
      return;
    }

    // Sample a grid of points to calculate average brightness
    int sampleCount = 0;
    int totalBrightness = 0;
    const int samplesPerAxis = 10; // 10x10 grid = 100 samples

    for (int sy = 0; sy < samplesPerAxis; sy++) {
      for (int sx = 0; sx < samplesPerAxis; sx++) {
        // Sample uniformly across the image
        final imageX = ((sx + 0.5) * imgObj.width / samplesPerAxis).floor();
        final imageY = ((sy + 0.5) * imgObj.height / samplesPerAxis).floor();
        
        // Check if within image bounds
        if (imageX >= 0 && imageX < imgObj.width && imageY >= 0 && imageY < imgObj.height) {
          final pixel = imgObj.getPixel(imageX, imageY);
          // Calculate perceived brightness (weighted RGB)
          final brightness = (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b).round();
          totalBrightness += brightness;
          sampleCount++;
        }
      }
    }

    if (sampleCount > 0) {
      final avgBrightness = totalBrightness / sampleCount;
      // If image is dark (< 128), use light border; if bright, use dark border
      _frameBorderColor = avgBrightness < 128 ? Colors.white : Colors.black;
    } else {
      _frameBorderColor = Colors.black;
    }
  }

  // Wrapper for triggering rebuild from extension helpers
  void _refresh(){ if(mounted){ setState(()=>{}); } }

  // Open Saved window (no auto-seed here to respect user deletions)
  Future<void> _openSavedWindow() async {
    if(mounted){ setState(()=> _showLibrary = true); }
  }

  // ========================= TOP BAR NAVIGATION BUTTONS =========================
  // Three main windows when connected:
  // 1. "Saved" button -> Opens SAVED IMAGES window (_showLibrary=true, shows _buildLibraryView)
  // 2. "Library" button -> Opens LIBRARY window with Pixabay (_showOnline=true, shows _buildOnlineView)
  // 3. "AI" button -> Opens AI generation window (_showAi=true, shows _buildAiView)
  Widget _connectedTopBar(){
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 1),
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
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                elevation: 2,
                shadowColor: Colors.green.withOpacity(0.3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _openSavedWindow,
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
              onPressed: (){ setState((){ _showOnline = true; _pixabayError = null; }); },
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

  // Main connected view router
  // Navigation: _showLibrary = SAVED IMAGES window, _showOnline = LIBRARY (Pixabay) window, _showAi = AI window
  Widget _buildConnected(){
    if(_showAi){
      return _buildAiView();
    }
    if(_showLibrary){  // SAVED IMAGES window
      return _buildLibraryView();
    }
    if(_showOnline){  // LIBRARY window (Pixabay)
      return _buildOnlineView();
    }
    // Adaptive, constraint-driven layout: guarantees everything fits without vertical scroll.
    return LayoutBuilder(builder: (context, constraints){
      final maxH = constraints.maxHeight;
      // Fixed element heights
      const double topBarH = 32.0; // button row height
      const double spacingBelowTopBar = 4.0;
      const double actionBarH = 40.0;
      const double spacingBelowAction = 4.0; // gap before action bar
      const double gapActionToPreview = 4.0; // gap after action bar
      const double statusH = 46.0;
      const double progressH = 30.0; // Always reserve space to prevent layout shift
      const double bottomSpacing = 4.0; // gap before status

      // Remaining for (crop frame) + (preview/sliders)
  double remaining = maxH - topBarH - spacingBelowTopBar - actionBarH - spacingBelowAction - gapActionToPreview - statusH - progressH - bottomSpacing;
      if(remaining < 160) remaining = 160; // enforce a sane minimum

      // Allocate proportions: 58% for frame (with clamp), rest for preview section
      double frameAreaH = (remaining * 0.58).clamp(200.0, 360.0);
      double previewAreaH = remaining - frameAreaH;
      // Ensure preview area not too small; if so, borrow from frame
      const double minPreview = 140.0;
      if(previewAreaH < minPreview){
        final deficit = minPreview - previewAreaH;
        final reducible = frameAreaH - 200.0; // don't go below 200 for frame
        final take = deficit.clamp(0, reducible);
        frameAreaH -= take;
        previewAreaH += take;
      }
      // Keep layout stable - don't adjust when sending

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(height: topBarH, child: _connectedTopBar()),
          SizedBox(height: spacingBelowTopBar),
          // Frame / main workspace
          SizedBox(
            height: frameAreaH,
            // Crop frame: the black rectangle area the user fits the image into
            child: _uiOriginal!=null ? _buildCropFrame() : Center(
              child: _processedPngBytes!=null ? FittedBox(
                fit: BoxFit.contain,
                child: Image.memory(_processedPngBytes!, fit: BoxFit.contain, filterQuality: FilterQuality.high),
              ) : Text('Select or generate an image', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          SizedBox(height: spacingBelowAction),
          SizedBox(height: actionBarH, child: _buildActionBar()),
          SizedBox(height: gapActionToPreview),
          SizedBox(
            height: previewAreaH,
            child: _buildPreviewAndSliders(),
          ),
          if(_isSending)
            SizedBox(
              height: progressH,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  LinearProgressIndicator(value: _transferProgress/100),
                  const SizedBox(height: 2),
                  Text('$_transferProgress%  ${_transferSpeed.toStringAsFixed(1)} KB/s', textAlign: TextAlign.center, style: const TextStyle(fontSize:12)),
                ],
              ),
            ),
          const SizedBox(height:4),
          SizedBox(height: statusH, child: _statusCard()),
        ],
      );
    });
  }

  // Main action bar (orientation toggle, add to library, process, send, reset)
  Widget _buildActionBar(){
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:6, vertical:2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children:[
        // Left side controls
        Row(children:[
          _smallBtn(
            _isPortrait ? 'Portrait' : 'Landscape',
            (_uiOriginal != null || _processedPngBytes != null) ? (){
              setState((){
                _isPortrait = !_isPortrait;
                _processedImage = null;
                _processedBytes = null;
                // Don't reset _viewInitialized - preserve user's image position/zoom
              });
              _recomputeViewForCurrentFrame(context);
              // Update frame border color after orientation change
              setState(() => _updateFrameBorderColor());
            } : null,
            icon: Icons.screen_rotation,
            backgroundColor: Colors.indigo.shade600,
          ),
          const SizedBox(width:1),
          _smallBtn('Save', _originalImage==null ? null : _addCurrentToLibrary, icon: Icons.library_add, backgroundColor: Colors.green.shade600),
          const SizedBox(width:1),
          _smallBtn('Send', _sendOrProcessThenSend, icon: Icons.send, backgroundColor: Colors.blue.shade600),
        ]),
        const Spacer(),
        // Right side controls
        Row(children:[
          // Only add spacing if OTA button is visible (after version check is complete)
          if (_versionCheckCompleted && (_otaButtonEnabled || _isCheckingVersion)) ...[
            const SizedBox(width:1),
            _buildOtaButton(),
            const SizedBox(width:1),
          ],
          _smallBtn('Exit', _exitApp, icon: Icons.exit_to_app, backgroundColor: Colors.red.shade600),
        ])
      ]),
    );
  }

  // Recompute frame geometry and cover-fit view instantly for current layout sizes
  void _recomputeViewForCurrentFrame(BuildContext context){
    final imgObj = _uiOriginal; if(imgObj==null) return;
    // Workspace size (match crop frame widget)
    final double workspaceW = MediaQuery.of(context).size.width - 24; // body horizontal padding is 12 each side
    final double workspaceH = 300; // crop frame height - keep constant to prevent image shift

    // Compute crop frame size using only hardware aspect (no image-based resizing)
    const double margin = 0.9; // leave a bit of breathing room
    final double maxW = workspaceW * margin;
    final double maxH = workspaceH * margin;
    double aspect = _isPortrait ? (IMAGE_HEIGHT / IMAGE_WIDTH) : (IMAGE_WIDTH / IMAGE_HEIGHT); // width/height
    double frameW = 0, frameH = 0;
    if (maxW / maxH > aspect) {
      // height-limited
      frameH = maxH;
      frameW = frameH * aspect;
    } else {
      // width-limited
      frameW = maxW;
      frameH = frameW / aspect;
    }
    // No portrait-specific shrink; maintain exact hardware aspect ratio
    Offset origin = Offset((workspaceW - frameW)/2, (workspaceH - frameH)/2);
    origin = _snapOffset(origin);
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
        _viewRotation = 0.0;
        _centerViewOnFrame(fitScale);
        _viewInitialized = true;
      }
      // Always update scale limits based on new frame size
      _minScale = (fitScale * 0.01).clamp(0.005, double.infinity);
      _maxScale = fitScale * 80;
    });
  }

  // Center the image so its center aligns with the crop frame center
  void _centerViewOnFrame(double scale){
    final img = _uiOriginal; if(img==null) return;
    final iw = img.width.toDouble();
    final ih = img.height.toDouble();
    _viewScale = scale;
    double tx = _frameOrigin.dx + _frameWidth/2 - iw*scale/2;
    double ty = _frameOrigin.dy + _frameHeight/2 - ih*scale/2;
    // Snap to device pixels to avoid half-pixel visual bias on high-DPI screens
    try{
      final dpr = ui.window.devicePixelRatio;
      tx = (tx * dpr).roundToDouble() / dpr;
      ty = (ty * dpr).roundToDouble() / dpr;
    } catch(_) {}
    _viewTranslation = Offset(tx, ty);
  }

  Offset _snapOffset(Offset o){
    try{
      final dpr = ui.window.devicePixelRatio;
      return Offset(
        (o.dx * dpr).roundToDouble() / dpr,
        (o.dy * dpr).roundToDouble() / dpr,
      );
    } catch(_){
      return o;
    }
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
                    : Image.memory(_aiPngBytes!, fit: BoxFit.contain, filterQuality: FilterQuality.high)),
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
      // Use editor orientation (_isPortrait) instead of a separate AI toggle
      final genW = _isPortrait ? IMAGE_HEIGHT : IMAGE_WIDTH;  // 480 if portrait
      final genH = _isPortrait ? IMAGE_WIDTH : IMAGE_HEIGHT;  // 800 if portrait
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
      final int w = _isPortrait ? IMAGE_HEIGHT : IMAGE_WIDTH;
      final int h = _isPortrait ? IMAGE_WIDTH : IMAGE_HEIGHT;
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
    }
  }

  Future<void> _useAiImage() async {
    if(_aiPngBytes==null) return;
    try{
      // Write PNG to a temp file
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ai_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(_aiPngBytes!);
      
      // Load UI image before setState to prevent flicker
      final codec = await ui.instantiateImageCodec(_aiPngBytes!);
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;
      
      // Single setState with everything ready
      if (mounted) {
        setState((){
          _originalImage = file;
          _processedImage = null;
          _processedBytes = null;
          _processedPngBytes = null;
          _uiOriginal = uiImage;
          _viewInitialized = false;
          _showAi = false;
          // Keep current orientation - don't auto-change
        });
        
        // Calculate frame dimensions after first render
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _recomputeViewForCurrentFrame(context);
          }
        });
      }
      _updateStatus('AI image loaded into editor');
    }catch(_){
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
      
      if (mounted) {
        setState(() {
          _deviceFirmwareVersion = deviceVersion;
          _otaFileVersion = otaVersion;
          _otaButtonEnabled = _shouldEnableOtaButton(deviceVersion, otaVersion);
          _isCheckingVersion = false;
          _versionCheckCompleted = true; // Mark as completed to prevent flickering
        });
      }
      
      if (deviceVersion != null && otaVersion != null) {
        if (_otaButtonEnabled) {
          _updateStatus('OTA available: Device v$deviceVersion → v$otaVersion');
        } else {
          _updateStatus('Firmware up-to-date: v$deviceVersion');
        }
      } else {
        _updateStatus('Ready to Send', persist: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingVersion = false;
          _otaButtonEnabled = true; // Enable by default on error
          _versionCheckCompleted = true; // Mark as completed even on error
        });
      }
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

  /// Send calibration command to Arduino via BLE
  Future<void> _sendCalibrationCommand() async {
    if (_connectedDevice == null || _rxCharacteristic == null) {
      _showErrorDialog(
        'Device Not Connected',
        'Please connect to your e-paper frame before attempting calibration. Touch the frame to wake it up and establish a connection.',
      );
      return;
    }

    try {
      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('Calibrating sensor...'),
            ],
          ),
        ),
      );

      // Create a completer to wait for calibration acknowledgment
      Completer<bool> calibrationCompleter = Completer<bool>();
      
      // Listen for calibration acknowledgment on TX characteristic
      BluetoothCharacteristic? txChar;
      for (var service in await _connectedDevice!.discoverServices()) {
        for (var char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == '6e400003-b5a3-f393-e0a9-e50e24dcca9e') {
            txChar = char;
            break;
          }
        }
      }

      late StreamSubscription subscription;
      if (txChar != null) {
        await txChar.setNotifyValue(true);
        subscription = txChar.lastValueStream.listen((value) {
          if (value.isNotEmpty && value[0] == 0xC1) {
            // Calibration acknowledgment received (0xC1)
            if (!calibrationCompleter.isCompleted) {
              calibrationCompleter.complete(true);
            }
            subscription.cancel();
          }
        });
      }

      // Send calibration command (0xC0)
      await _rxCharacteristic!.write(Uint8List.fromList([0xC0]));
      print('Calibration command sent (0xC0)');

      // Wait for acknowledgment with timeout
      bool success = await calibrationCompleter.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          subscription.cancel();
          return false;
        },
      );

      // Close loading dialog
      Navigator.of(context).pop();

      // Show result
      if (success) {
        _showSuccessDialog(
          'Calibration Complete! ✅',
          'The capacitive touch sensor has been successfully calibrated. The frame\'s LED should have flashed 3 times to confirm. Your frame is now ready to use with optimal touch sensitivity.',
        );
      } else {
        _showErrorDialog(
          'Calibration Timeout',
          'The frame did not respond to the calibration command. Please ensure:\n\n• The frame is powered on\n• Bluetooth connection is stable\n• Your finger is NOT touching the sensor during calibration\n\nTry again or use the physical boot button on the frame.',
        );
      }
    } catch (e) {
      // Close loading dialog if still open
      Navigator.of(context).pop();
      
      print('Error sending calibration command: $e');
      _showErrorDialog(
        'Calibration Failed',
        'An error occurred while sending the calibration command: $e\n\nPlease check your Bluetooth connection and try again.',
      );
    }
  }

  void _showSuccessDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade600, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: Colors.green.shade700, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 15, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red.shade600, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: Colors.red.shade700, fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 15, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
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
        return "1.37.0"; // Update this when you create new OTA files
        
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

  // Pixabay search
  Future<void> _searchPixabayImages() async {
    FocusScope.of(context).unfocus();
    final q = _pixabaySearchController.text.trim();
    if(q.isEmpty){ setState(()=> _pixabayError='Enter a search term'); return; }
    
    // Add "abstract" to the search query (hidden from user)
    final searchQuery = 'abstract $q';
    
    setState((){ _isPixabaySearching=true; _pixabayError=null; _pixabayResults=[]; _selectedPixabayIndex=null; });
    _updateStatus('Searching "$q" on Pixabay...');
    try{
      final params = <String,String>{
        'key': _pixabayApiKey,
        'q': searchQuery,  // Use modified query with "abstract"
        'image_type':'photo',
        'safesearch':'true',
        'order':'popular',
        'per_page':'200',
      };
      if(_selectedPixabayCategory != 'all'){
        params['category'] = _selectedPixabayCategory;
      }
      final uri = Uri.https('pixabay.com','/api/', params);
      final resp = await http.get(uri, headers:{
        HttpHeaders.acceptHeader:'application/json',
        HttpHeaders.userAgentHeader:'CanvasBT'
      });
      if(resp.statusCode!=200) throw HttpException('HTTP ${resp.statusCode}');
      final data = json.decode(resp.body) as Map<String,dynamic>;
      final hits = data['hits'] as List<dynamic>? ?? const [];
      final out = <_PixabayImage>[];
      for(final h in hits){
        if(h is! Map) continue;
        final preview = (h['previewURL'] as String? ?? h['webformatURL'] as String? ?? '').trim();
        final full = (h['largeImageURL'] as String? ?? h['webformatURL'] as String? ?? '').trim();
        if(preview.isEmpty || full.isEmpty) continue;
        final w = h['imageWidth'];
        final ht = h['imageHeight'];
        
        final width = w is int ? w : int.tryParse('$w') ?? 0;
        final height = ht is int ? ht : int.tryParse('$ht') ?? 0;
        
        out.add(_PixabayImage(
          id: '${h['id'] ?? ''}',
          previewUrl: preview,
            fullUrl: full,
          width: width,
          height: height,
          author: (h['user'] as String? ?? 'Pixabay User').trim(),
        ));
      }
      if(mounted){ setState((){ _pixabayResults=out; if(out.isEmpty) _pixabayError='No results'; }); }
      _updateStatus(out.isEmpty ? 'No results for "$q"' : 'Found ${out.length} images');
    }catch(e){ if(mounted){ setState(()=> _pixabayError='Search failed: $e'); } }
    finally{ if(mounted){ setState(()=> _isPixabaySearching=false); } }
  }

  void _selectPixabayImage(int i){
    if(i<0 || i>=_pixabayResults.length) return;
    setState((){ _selectedPixabayIndex = (_selectedPixabayIndex==i) ? null : i; });
    if(_selectedPixabayIndex!=null){ _updateStatus('Selected Pixabay image'); }
  }

  // Search using only the selected category (independent of the text query)
  Future<void> _searchPixabayByCategory(String category) async {
    final cat = (category.isEmpty) ? 'all' : category;
    setState((){ _isPixabaySearching=true; _pixabayError=null; _pixabayResults=[]; _selectedPixabayIndex=null; });
    _updateStatus('Browsing $cat images on Pixabay...');
    try{
      // Add "abstract" to category search query (hidden from user)
      final baseQuery = cat == 'all' ? 'popular' : cat;
      final searchQuery = 'abstract $baseQuery';
      
      final params = <String,String>{
        'key': _pixabayApiKey,
        'q': searchQuery, // Use modified query with "abstract"
        'image_type':'photo',
        'safesearch':'true',
        'order':'popular',
        'per_page':'200',
      };
      if(cat != 'all') params['category'] = cat;
      final uri = Uri.https('pixabay.com','/api/', params);
      final resp = await http.get(uri, headers:{
        HttpHeaders.acceptHeader:'application/json',
        HttpHeaders.userAgentHeader:'CanvasBT'
      });
      if(resp.statusCode!=200) throw HttpException('HTTP ${resp.statusCode}');
      final data = json.decode(resp.body) as Map<String,dynamic>;
      final hits = data['hits'] as List<dynamic>? ?? const [];
      final out = <_PixabayImage>[];
      for(final h in hits){
        if(h is! Map) continue;
        final preview = (h['previewURL'] as String? ?? h['webformatURL'] as String? ?? '').trim();
        final full = (h['largeImageURL'] as String? ?? h['webformatURL'] as String? ?? '').trim();
        if(preview.isEmpty || full.isEmpty) continue;
        final w = h['imageWidth'];
        final ht = h['imageHeight'];
        
        final width = w is int ? w : int.tryParse('$w') ?? 0;
        final height = ht is int ? ht : int.tryParse('$ht') ?? 0;
        
        out.add(_PixabayImage(
          id: '${h['id'] ?? ''}',
          previewUrl: preview,
          fullUrl: full,
          width: width,
          height: height,
          author: (h['user'] as String? ?? 'Pixabay User').trim(),
        ));
      }
      if(mounted){ setState((){ _pixabayResults=out; _pixabayError = out.isEmpty ? 'No results' : null; }); }
      _updateStatus(out.isEmpty ? 'No results' : 'Found ${out.length} images');
    }catch(e){ if(mounted){ setState(()=> _pixabayError='Search failed: $e'); } }
    finally{ if(mounted){ setState(()=> _isPixabaySearching=false); } }
  }

  Future<void> _useSelectedPixabayImage() async {
    final idx = _selectedPixabayIndex; if(idx==null) return;
    final chosen = _pixabayResults[idx];
    setState(()=> _isPixabayImporting=true);
    _updateStatus('Downloading Pixabay image...');
    try{
      final resp = await http.get(Uri.parse(chosen.fullUrl), headers:{
        HttpHeaders.userAgentHeader:'CanvasBT-app',
        HttpHeaders.acceptHeader:'image/*'
      });
      if(resp.statusCode!=200) throw HttpException('HTTP ${resp.statusCode}');
      final bytes = resp.bodyBytes; if(bytes.isEmpty) throw const FormatException('Empty image');
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/pixabay_${chosen.id}_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(bytes);
      final codec = await ui.instantiateImageCodec(bytes); final frame = await codec.getNextFrame(); final uiImg = frame.image;
      if(!mounted) return;
      setState((){
        _originalImage = file;
        _uiOriginal = uiImg;
        _processedImage = null; _processedBytes=null; _processedPngBytes=null;
        _showOnline = false; _viewInitialized=false; _selectedPixabayIndex=null;
        // Keep current orientation - don't auto-change
      });
      WidgetsBinding.instance.addPostFrameCallback((_){ if(mounted) _recomputeViewForCurrentFrame(context); });
      _updateStatus('Loaded Pixabay image by ${chosen.author}');
    }catch(e){ if(mounted){ setState(()=> _pixabayError='Import failed: $e'); } }
    finally{ if(mounted){ setState(()=> _isPixabayImporting=false); } }
  }

  // Save the currently processed frame into the in-memory library (PNG cached for fast thumbnails)
  Future<void> _addCurrentToLibrary() async {
    // Save the cropped area from the ORIGINAL high-quality image
    if(_originalImage==null){ return; }
    
    // 1) Crop from ORIGINAL image to get high-quality PNG
    final Uint8List bytes = await _originalImage!.readAsBytes();
    final img.Image? original = img.decodeImage(bytes);
    if(original == null) return;
    final img.Image croppedOriginal = _generateCroppedBaseImage(original);
    
    // 2) Store the cropped area in the orientation it's displayed
    img.Image pngImage = croppedOriginal;
    if(_isPortrait){
      // Portrait frame: rotate -90 so PNG is portrait (width<height)
      pngImage = img.copyRotate(pngImage, angle: -90);
    }
    final Uint8List png = Uint8List.fromList(img.encodePng(pngImage));
    
    // 3) Generate 6-color quantized version ONLY for the raw codes (for sending)
    final Tuple2<img.Image, Uint8List> q = _quantizeTo6ColorAndCreateRawBytes(croppedOriginal);
    final img.Image processedDisplay = q.item1;
    final Uint8List processedRaw = q.item2;
    
    final entry = _LibraryEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      image: processedDisplay.clone(),     // 6-color version for quick preview
      rawCodes: Uint8List.fromList(processedRaw), // raw codes ready for send
      pngBytes: png,                        // HIGH-QUALITY original PNG for editor
      created: DateTime.now(),
      wasPortrait: _isPortrait,
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
      final String? fingerAsset = await _resolveFingerAssetForOrientation(_isPortrait);
      _pendingSend = _PendingSend.image; // remember user's intent
      if (!mounted) return;
      
      // Use scaffold context for reliable dialog display
      final dialogContext = _scaffoldKey.currentContext ?? context;
      await showDialog(
        context: dialogContext,
        barrierDismissible: false,
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
                        child: Image.asset(fingerAsset, fit: BoxFit.contain, filterQuality: FilterQuality.high),
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
        // Keep current orientation - don't restore saved orientation
        _viewInitialized = false;
      });
      await _sendImageData();
      return;
    }
    _updateStatus('No image to send. Pick, generate, or use Library.');
  }

  // ========================= SAVED IMAGES WINDOW =========================
  // Grid of saved processed images (tap to select, then Use in Editor / Delete)
  Widget _buildLibraryView(){
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children:[
          _smallBtn('Back', ()=> setState(()=> _showLibrary=false), icon: Icons.arrow_back, backgroundColor: Colors.grey.shade600),
          const SizedBox(width:6),
          _smallBtn('Delete', _selectedLibraryIndex==null ? null : _deleteSelectedLibraryItem, icon: Icons.delete, backgroundColor: Colors.red.shade600),
          const SizedBox(width:6),
          _smallBtn('Use in Editor', _selectedLibraryIndex==null ? null : _useSelectedLibraryItem, icon: Icons.open_in_new, backgroundColor: Colors.teal.shade600),
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
                        child: Image.memory(e.pngBytes, fit: BoxFit.cover, filterQuality: FilterQuality.high),
                      )),
                      Positioned(
                        left:4, top:4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal:4, vertical:2),
                          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                          child: Text(e.wasPortrait? 'Portrait' : 'Landscape', style: const TextStyle(color: Colors.white, fontSize:9, fontWeight: FontWeight.w500)),
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

  Future<void> _useSelectedLibraryItem() async {
    final idx = _selectedLibraryIndex; if(idx==null) return;
    final entry = _library[idx];
    try{
      // All saved images are stored as 800x480 (landscape) in library
      // Load exactly as stored; no rotation is applied automatically
      
      // Write PNG to a temp file
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/library_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(entry.pngBytes);
      
      // Load UI image before setState
      final codec = await ui.instantiateImageCodec(entry.pngBytes);
      final frame = await codec.getNextFrame();
      ui.Image uiImage = frame.image;
      
      // Load image exactly as stored - NO automatic rotation
      // User will manually rotate with gestures if needed
      
      // Calculate workspace dimensions (same as in _recomputeViewForCurrentFrame)
      final double workspaceW = MediaQuery.of(context).size.width - 24;
      final double workspaceH = 300;
      
      // Calculate crop frame dimensions for CURRENT orientation (hardware aspect only)
      const double margin = 0.9; // must match _buildCropFrame
      final double maxW = (MediaQuery.of(context).size.width - 24) * margin;
      final double maxH = 300 * margin;
      double aspect = _isPortrait ? (IMAGE_HEIGHT / IMAGE_WIDTH) : (IMAGE_WIDTH / IMAGE_HEIGHT); // width/height
      double frameW, frameH;
      if (maxW / maxH > aspect) {
        // height-limited
        frameH = maxH;
        frameW = frameH * aspect;
      } else {
        // width-limited
        frameW = maxW;
        frameH = frameW / aspect;
      }
      // No portrait-specific shrink; maintain exact hardware aspect ratio
      // Frame origin centered in workspace (exact aspect, no portrait skew)
      Offset frameOrigin = Offset((workspaceW - frameW)/2, (workspaceH - frameH)/2);
      
      // Determine if current orientation matches the saved image orientation (not used for placement)

      // Fit calculations
      final iw = uiImage.width.toDouble();
      final ih = uiImage.height.toDouble(); // kept for clarity; used for exactScale equivalence and future logic
      
      // DEBUG: Print dimensions
      print('═════════════════════════════════════════');
      print('📸 LOADED IMAGE FROM SAVED');
      print('Real image (hardware):  ${iw.toInt()}px × ${ih.toInt()}px');
      print('Crop frame (preview):   ${frameW.toStringAsFixed(1)}px × ${frameH.toStringAsFixed(1)}px');
      print('Saved orientation: ${entry.wasPortrait ? "Portrait" : "Landscape"}');
      print('Current frame mode: ${_isPortrait ? "Portrait" : "Landscape"}');
      print('Orientation match: ${entry.wasPortrait == _isPortrait}');
      
      // No pre-scaling here; scale will be chosen per-case below
      
      // Single setState with everything ready
      if (mounted) {
        setState((){
          _originalImage = file;
          _processedImage = null;
          _processedBytes = null;
          _processedPngBytes = null;
          _uiOriginal = uiImage;
          // Keep current orientation - don't auto-change (only via Portrait/Landscape button)
          _frameWidth = frameW;
          _frameHeight = frameH;
          _frameOrigin = frameOrigin;
          
          // Calculate exact fit scale for saved images
          final double fitScale = math.min(frameW / iw, frameH / ih);
          
          print('Calculated fitScale: ${fitScale.toStringAsFixed(6)}');
          print('  Width ratio:  ${frameW.toStringAsFixed(2)} / ${iw.toInt()} = ${(frameW / iw).toStringAsFixed(6)}');
          print('  Height ratio: ${frameH.toStringAsFixed(2)} / ${ih.toInt()} = ${(frameH / ih).toStringAsFixed(6)}');
          print('  Using min: ${fitScale.toStringAsFixed(6)}');
          
          // For saved images, use exact fitScale for perfect fit (don't use old _viewScale)
          _viewScale = fitScale;
          _viewRotation = 0.0;
          
          print('Before _centerViewOnFrame:');
          print('  _viewScale: ${_viewScale.toStringAsFixed(6)}');
          print('  _viewTranslation: ${_viewTranslation.dx.toStringAsFixed(2)}, ${_viewTranslation.dy.toStringAsFixed(2)}');
          
          _centerViewOnFrame(fitScale);
          
          print('After _centerViewOnFrame:');
          print('  _viewScale: ${_viewScale.toStringAsFixed(6)}');
          print('  _viewTranslation: ${_viewTranslation.dx.toStringAsFixed(2)}, ${_viewTranslation.dy.toStringAsFixed(2)}');
          print('  Scaled image size: ${(iw * _viewScale).toStringAsFixed(2)}px × ${(ih * _viewScale).toStringAsFixed(2)}px');
          
          // Mark as initialized so _buildCropFrame won't recalculate
          _viewInitialized = true;
          _minScale = (fitScale * 0.01).clamp(0.005, double.infinity);
          _maxScale = fitScale * 80;
          // No need to recenter - we've set it correctly
          _needsRecenteringOnce = false;
          
          print('Final state:');
          print('  _viewInitialized: true');
          print('  _needsRecenteringOnce: false');
          print('═════════════════════════════════════════');
          
          _showLibrary = false;
        });
        // Call _resetView after frame is built to ensure perfect centering
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if(mounted) { 
            print('🔄 Auto-calling _resetView() for perfect centering...');
            _resetView();
            print('✅ Image centered and fitted');
          }
        });
      }
    }catch(e){ }
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

  // ========================= LIBRARY WINDOW (Pixabay online images) =========================
  Widget _buildOnlineView(){
    final String status;
    if(_pixabayError!=null){ status = _pixabayError!; }
    else if(_selectedPixabayIndex!=null){ final d=_pixabayResults[_selectedPixabayIndex!]; status='Selected • ${d.author}'; }
    else if(_pixabayResults.isNotEmpty){ status='Tap a thumbnail to select'; }
    else { status='Search Pixabay for images'; }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children:[
      Row(crossAxisAlignment: CrossAxisAlignment.center, children:[
        _smallBtn('Back', ()=> setState(()=> _showOnline=false), icon: Icons.arrow_back, backgroundColor: Colors.grey.shade600),
        const SizedBox(width:8),
        _smallBtn(_isPixabayImporting? 'Importing' : 'Use in Editor', (_selectedPixabayIndex==null || _isPixabayImporting)? null : _useSelectedPixabayImage, icon: Icons.cloud_download, backgroundColor: Colors.teal.shade600),
        const SizedBox(width:8),
        Expanded(child: Text('Library', textAlign: TextAlign.center, style: const TextStyle(fontSize:16, fontWeight: FontWeight.w600))),
        IconButton(onPressed: (_isPixabaySearching || _pixabaySearchController.text.trim().isEmpty)? null : _searchPixabayImages, icon: const Icon(Icons.refresh)),
      ]),
      const SizedBox(height:4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
      ),
      const SizedBox(height:6),
      _buildPixabaySearchRow(),
      const SizedBox(height:8),
      Expanded(child: _buildPixabayResultsSection()),
      const SizedBox(height:6),
      _statusCard(),
    ]);
  }

  Widget _buildPixabaySearchRow(){
    String _titleCase(String s){ if(s.isEmpty) return s; return s[0].toUpperCase()+s.substring(1); }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children:[
      Row(children:[
        Expanded(child: TextField(
          controller: _pixabaySearchController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_)=> _searchPixabayImages(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search (e.g. sunset)',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal:12, vertical:10),
          ),
        )),
        const SizedBox(width:8),
        SizedBox(height:44, child: ElevatedButton.icon(
          onPressed: _isPixabaySearching? null : _searchPixabayImages,
          icon: const Icon(Icons.search, size:18),
          label: Text(_isPixabaySearching? 'Searching...' : 'Search'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal.shade600, foregroundColor: Colors.white, textStyle: const TextStyle(fontWeight: FontWeight.w600)),
        )),
      ]),
      const SizedBox(height:8),
      // Swipeable horizontal list of category buttons
      SizedBox(
        height: 40,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              const Padding(
                padding: EdgeInsets.only(right: 8.0),
                child: Text('Categories:', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
              ..._pixabayCategories.map((c){
                final selected = _selectedPixabayCategory == c;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: ChoiceChip(
                    label: Text(_titleCase(c)),
                    selected: selected,
                    selectedColor: Colors.teal.shade600,
                    labelStyle: TextStyle(color: selected ? Colors.white : Colors.black87, fontSize: 12),
                    onSelected: (_){
                      setState(()=> _selectedPixabayCategory = c);
                      // Category triggers its own search independent of text field
                      if(!_isPixabaySearching){ _searchPixabayByCategory(c); }
                    },
                  ),
                );
              }).toList(),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _buildPixabayResultsSection(){
    if(_isPixabaySearching){ return const Center(child: CircularProgressIndicator()); }
    if(_pixabayResults.isEmpty){ return Center(child: Text(_pixabayError??'Enter a search term above')); }
    return GridView.builder(
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemCount: _pixabayResults.length,
      itemBuilder: (context, index){
        final d = _pixabayResults[index]; final sel = index==_selectedPixabayIndex;
        return GestureDetector(onTap: ()=> _selectPixabayImage(index), child: AnimatedContainer(
          duration: const Duration(milliseconds:180),
          decoration: BoxDecoration(
            border: Border.all(color: sel? Colors.teal.shade600 : Colors.grey.shade400, width: sel? 3:0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Stack(children:[
            Positioned.fill(child: Image.network(d.previewUrl, fit: BoxFit.cover, headers: const { HttpHeaders.userAgentHeader:'CanvasBT-app' })),
          ])),
        ));
      },
    );
  }
  

  // Load an online image and set it as the current image
  // Preview: show only "Frame" (left); processing happens on Send
  Widget _buildPreviewAndSliders(){
    return SizedBox(
      height: _isSending ? 190 : 210,
      child: Row(children:[
  if (_uiOriginal != null)
    Expanded(
      child: Builder(
        builder: (context){
          // Always recalculate to ensure preview is in sync, especially after loading from library
          // Use the state variables if they're valid, otherwise calculate fresh
          double frameW = _frameWidth;
          double frameH = _frameHeight;
          Offset frameOrigin = _frameOrigin;
          
          // If frame dimensions are not initialized, calculate them
          if (frameW == 0 || frameH == 0) {
            final double workspaceW = MediaQuery.of(context).size.width - 24;
            final double workspaceH = 300;
            frameW = workspaceW * 0.5;
            if (_isPortrait) {
              frameH = frameW * (IMAGE_WIDTH / IMAGE_HEIGHT);
            } else {
              frameH = frameW * (IMAGE_HEIGHT / IMAGE_WIDTH);
            }
            if (frameH > workspaceH) {
              frameH = workspaceH * 0.5;
              if (_isPortrait) {
                frameW = frameH * (IMAGE_HEIGHT / IMAGE_WIDTH);
              } else {
                frameW = frameH * (IMAGE_WIDTH / IMAGE_HEIGHT);
              }
            }
            frameOrigin = Offset(
              (workspaceW - frameW)/2,
              (workspaceH - frameH)/2,
            );
          }
          
          // Lower-half preview is called the "Frame"
          return _previewPanel('Frame', _croppedOriginalPreviewSized(frameW, frameH, frameOrigin));
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
              // Battery status bottom-left inside the "Frame" panel (no separate bar)
              if (title == 'Frame' && (_batteryPercent != null || _isCharging))
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
                        Icon(
                          _isCharging ? Icons.battery_charging_full : Icons.battery_full, 
                          color: _isCharging ? Colors.green : Colors.white, 
                          size: 14
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _isCharging ? 'Charging' : '$_batteryPercent%', 
                          style: TextStyle(
                            color: _isCharging ? Colors.green : Colors.white, 
                            fontSize: 11, 
                            fontWeight: FontWeight.w600
                          )
                        ),
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


  

  // Reset pan/zoom/rotation and recenter using current frame rules
  void _resetView(){
    final img = _uiOriginal; if(img==null) return;
    final double workspaceW = MediaQuery.of(context).size.width - 24;
    final double workspaceH = 300;
    const double margin = 0.9;
    final double maxW = workspaceW * margin;
    final double maxH = workspaceH * margin;
    double aspect = _isPortrait ? (IMAGE_HEIGHT / IMAGE_WIDTH) : (IMAGE_WIDTH / IMAGE_HEIGHT);
    double frameW = 0, frameH = 0;
    if (maxW / maxH > aspect) {
      frameH = maxH;
      frameW = frameH * aspect;
    } else {
      frameW = maxW;
      frameH = frameW / aspect;
    }
    // Apply portrait-only shrink (5%) and extra 1% height reduction to match editor behavior
    if (_isPortrait) {
      const double frameScale = 0.95; // 5% uniform shrink
      frameW *= frameScale;
      frameH *= frameScale;
      frameH *= 0.99; // 1% height-only reduction
    }
    Offset origin = Offset((workspaceW - frameW)/2, (workspaceH - frameH)/2);
    origin = _snapOffset(origin);
    final double fitScale = math.min(frameW / img.width, frameH / img.height);
    setState((){
      _frameWidth = frameW;
      _frameHeight = frameH;
      _frameOrigin = origin;
      _viewRotation = 0.0;
      _centerViewOnFrame(fitScale);
      _viewInitialized = true;
      _minScale = (fitScale * 0.01).clamp(0.005, double.infinity);
      _maxScale = fitScale * 80;
      _processedImage = null; _processedBytes = null; _processedPngBytes = null;
      _updateFrameBorderColor();
    });
    _needsRecenteringOnce = true;
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
  void _updateStatus(String message, {bool force = false, bool persist = false}) {
    final now = DateTime.now();
    if(_isSending && !force && now.difference(_lastStatusUpdate).inMilliseconds < 350 && !message.startsWith('Progress')){ return; }
    _lastStatusUpdate = now;
    
    // Filter out errors, percentages, and data rates
    final lowerMsg = message.toLowerCase();
    if (lowerMsg.contains('error') || 
        lowerMsg.contains('%') || 
        lowerMsg.contains('kb/s') ||
        lowerMsg.contains('progress:') ||
        lowerMsg.contains('speed:') ||
        lowerMsg.contains('battery =')) {
      return; // Don't show these messages
    }
    
    if(mounted){ 
      setState(()=> _statusMessage = message); 
      
      // Cancel existing timer
      _statusMessageTimer?.cancel();
      
      // Only start auto-clear timer if message is not persistent
      if (!persist) {
        _statusMessageTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() => _statusMessage = '');
          }
        });
      }
    }
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
      // Load and process everything BEFORE setState to prevent flicker
      final file = File(pickedFile.path);
      final bytes = await file.readAsBytes();
      
      // Load UI image
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final uiImage = frame.image;
      
      // Now do a single setState with everything ready
      if (mounted) {
        setState(() { 
          _originalImage = file; 
          _processedImage = null; 
          _processedBytes = null; 
          _processedPngBytes = null; 
          _transferProgress = 0; 
          _uiOriginal = uiImage;
          _viewInitialized = false;
          // Keep current orientation - don't auto-change
        });
        
        // Calculate frame dimensions after first render
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _recomputeViewForCurrentFrame(context);
          }
        });
      }
    }
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
        _updateStatus("Image ready");
      }
    } catch (e) {
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
    final int targetW = _isPortrait ? IMAGE_HEIGHT : IMAGE_WIDTH; // 480 if portrait
    final int targetH = _isPortrait ? IMAGE_WIDTH : IMAGE_HEIGHT; // 800 if portrait
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
    if (_isPortrait) {
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
    
    if (!mounted) return;
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
        if (mounted) {
          setState(() {
            _isScanning = false;
          });
        }
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
            if (mounted) setState(() { _devicesList.add(result.device); });
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
      });
      
      // When scan completes
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
      
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
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
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
      await _scanSub?.cancel(); _scanSub = null;
    }
  }

  // Connect to a selected device
  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_isConnecting) return;
    
    if (!mounted) return;
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
          // Continue anyway with smaller chunks
        }
      }
      
      // Discover services with timeout to prevent hanging
      _updateStatus("Setting up connection...");
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
        _updateStatus("Retrying connection...");
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
      
      if (mounted) {
        setState(() {
          _connectedDevice = device;
          _rxCharacteristic = rxChar;
          _isConnecting = false;
    // Remain on the connected UI; first window was removed
        });
      }
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
      
      // Show Ready to Send after a brief delay (let firmware check display first)
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _connectedDevice != null) {
          _updateStatus('Ready to Send', persist: true);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
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
            if (mounted) {
              setState(() {
                _batteryPercent = batt;
                _isCharging = false; // Text battery update means not charging (charger removed)
              });
            }
            // Show battery when charger removed
            _updateStatus('Battery: $batt%');
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
          print('🔋 Battery status received: $batt%');
          if (mounted) {
            setState(() {
              _batteryPercent = batt;
              _isCharging = false; // Battery percentage means not charging
            });
          }
          _updateStatus("Battery: $batt%");
          
          // Stop polling timer when battery received (charger unplugged)
          _batteryStatusTimer?.cancel();
        }
        break;
      case ACK_CHARGING:
        // Charging status received - always show immediately
        print('🔌 Charging status received');
        if (mounted) {
          setState(() {
            _batteryPercent = null; // Clear percentage when charging
            _isCharging = true;
          });
        }
        _updateStatus("Charger connected");
        
        // Start polling battery status every second while charging
        _batteryStatusTimer?.cancel();
        _batteryStatusTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (_isCharging && mounted) {
            _updateStatus("Charging...");
          }
        });
        break;
      case ACK_SIZE_RECEIVED:
        break;
        
      case ACK_PROGRESS:
        if (data.length >= 2) {
          int progress = data[1];
          setState(() {
            _transferProgress = progress;
          });
        }
        break;
        
      case ACK_COMPLETE:
        if (mounted) {
          setState(() {
            _isSending = false;
            _transferProgress = 100;
          });
        }
        _updateStatus("Transfer completed successfully");
        break;
        
      case ACK_ERROR:
        if (mounted) {
          setState(() {
            _isSending = false;
          });
        }
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
      if (_isPortrait) {
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
      
      // First send a 1-byte type + 4-byte little-endian size header
      int totalSize = packedData.length;
      final header = Uint8List(5);
      header[0] = TRANSFER_TYPE_IMAGE;
      final bd = ByteData.view(header.buffer);
      bd.setUint32(1, totalSize, Endian.little);
      // Send the header
      await _rxCharacteristic!.write(header);
      _updateStatus("Starting image transfer...", force: true);
      
      // Short delay to ensure Arduino processes the header
      await Future.delayed(const Duration(milliseconds: 12));
      
      // Start the transfer timer
      int startTime = DateTime.now().millisecondsSinceEpoch;
      int bytesSent = 0;
      
      // Stream chunks without allocating new lists (zero-copy views)
      int dynamicChunk = BLE_CHUNK_SIZE;
      _updateStatus("Sending image...", force: true);
      for (int i = 0; i < packedData.length;) {
        // Bound chunk by remaining bytes and current dynamic chunk size
        final int end = math.min(i + dynamicChunk, packedData.length);
        final Uint8List view = Uint8List.sublistView(packedData, i, end);
        
        try {
          await _rxCharacteristic!.write(view, withoutResponse: true);
          bytesSent += view.length;
          // Very small pacing prevents peripheral overflow while keeping speed high
          await Future.delayed(const Duration(milliseconds: 1));
          // Advance only on success
          i = end;
        } catch (e) {
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
          
          if (mounted) {
            setState(() {
              _transferProgress = progress;
              _transferSpeed = speedKBps;
            });
          }
        }
      }
      
      // Final transfer statistics
      int endTime = DateTime.now().millisecondsSinceEpoch;
      double totalTime = (endTime - startTime) / 1000;
      
      _updateStatus("Image sent successfully in ${totalTime.toStringAsFixed(1)} seconds", force: true);
      
      // We don't set _isSending to false here - wait for ACK_COMPLETE
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
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
      final String? fingerAsset = await _resolveFingerAssetForOrientation(_isPortrait);
      _pendingSend = _PendingSend.ota; // remember user's intent
      if (!mounted) return;
      
      // Use scaffold context for reliable dialog display
      final dialogContext = _scaffoldKey.currentContext ?? context;
      await showDialog(
        context: dialogContext,
        barrierDismissible: false,
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
                        child: Image.asset(fingerAsset, fit: BoxFit.contain, filterQuality: FilterQuality.high),
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
          _updateStatus("Firmware file loaded");
          break;
        } catch (_) {}
      }
      if (otaBytes == null || otaBytes.isEmpty) {
        _updateStatus("Firmware file not found");
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
          _updateStatus("Transfer error, retrying...", force: true);
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

        await Future.delayed(const Duration(milliseconds: 1));
      }

      final end = DateTime.now().millisecondsSinceEpoch;
      final totalSec = (end - start) / 1000.0;
      _updateStatus("Firmware sent successfully in ${totalSec.toStringAsFixed(1)} seconds");
      // keep _isSending true until ACK_COMPLETE from device
    } catch (e) {
      setState(() { _isSending = false; });
    }
  }

  // ========================= DRAWER MENU =========================
  Widget _buildDrawer() {
    return Drawer(
      child: Container(
        color: Colors.grey.shade50,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.blue.shade700, Colors.blue.shade500],
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'Logo/Applogo.jpg',
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        return const Icon(Icons.image, size: 64, color: Colors.white);
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'CanvasBT',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'E-Paper Image Transfer',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.help_outline, color: Colors.blue, size: 28),
              title: const Text('How to Use', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
              onTap: () {
                Navigator.pop(context);
                _showHowToUseDialog();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.tune, color: Colors.orange, size: 28),
              title: const Text('Calibrate Sensor', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
              onTap: () {
                Navigator.pop(context);
                _showCalibrateSensorDialog();
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.policy_outlined, color: Colors.green, size: 28),
              title: const Text('Policies', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
              onTap: () {
                Navigator.pop(context);
                _showPoliciesDialog();
              },
            ),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }

  void _showHowToUseDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade600, Colors.blue.shade400],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.help_outline, color: Colors.white, size: 32),
                    SizedBox(width: 12),
                    Text(
                      'How to Use CanvasBT',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Step 1: Select Your Image
                      const Text(
                        'Step 1: Select Your Image',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Choose an image from any of these sources:',
                        style: TextStyle(fontSize: 14, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Gallery - Browse your phone\'s photo collection'),
                      _buildBulletPoint('Library - Discover beautiful images from Pixabay online'),
                      _buildBulletPoint('AI - Create unique artwork with text prompts'),
                      _buildBulletPoint('Saved - Access images you\'ve previously edited'),
                      const SizedBox(height: 20),
                      
                      // Step 2: Perfect Your Frame
                      const Text(
                        'Step 2: Perfect Your Frame',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Once your image loads in the editor:',
                        style: TextStyle(fontSize: 14, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Orientation - Tap Portrait/Landscape to match your display'),
                      _buildBulletPoint('Position - Drag with one finger to move the image'),
                      _buildBulletPoint('Zoom - Pinch with two fingers to zoom in or out'),
                      _buildBulletPoint('Rotate - Twist with two fingers to adjust the angle'),
                      _buildBulletPoint('Reset - Double-tap anytime to start fresh'),
                      _buildBulletPoint('Info - Tap the ⓘ icon for quick gesture reminders'),
                      const SizedBox(height: 20),
                      
                      // Step 3: Send to Display
                      const Text(
                        'Step 3: Send to Display',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Ready to transfer? It\'s automatic!',
                        style: TextStyle(fontSize: 14, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Tap the blue Send button'),
                      _buildBulletPoint('Touch your e-paper frame - it wakes up instantly'),
                      _buildBulletPoint('Watch the progress bar as your image transfers'),
                      _buildBulletPoint('Your display refreshes automatically when complete'),
                      const SizedBox(height: 20),
                      
                      // Step 4: Save Your Creations
                      const Text(
                        'Step 4: Save Your Creations',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Love what you made?',
                        style: TextStyle(fontSize: 14, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Tap Save to store your edited image'),
                      _buildBulletPoint('Find it anytime in the Saved section'),
                      _buildBulletPoint('Each save remembers your exact framing and settings'),
                      const SizedBox(height: 20),
                      
                      // Pro Tips
                      const Text(
                        'Pro Tips',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Battery Status - Check your frame\'s battery in the preview corner'),
                      _buildBulletPoint('USB Charging - Frame stays awake and shows breathing LED when charging'),
                      _buildBulletPoint('Auto-Connect - App remembers and reconnects to your frame automatically'),
                      _buildBulletPoint('OTA Updates - Orange OTA button appears when firmware updates are available'),
                      _buildBulletPoint('Smart Search - Library filters images by your current orientation (Portrait/Landscape)'),
                      const SizedBox(height: 20),
                      
                      // Quick Features
                      const Text(
                        'Quick Features',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('No Setup Required - Bluetooth connects automatically when you touch the frame'),
                      _buildBulletPoint('Fast Transfer - Optimized BLE protocol sends images in seconds'),
                      _buildBulletPoint('Offline Ready - All image processing happens on your phone'),
                      _buildBulletPoint('5-Day Refresh - Frame automatically refreshes display to prevent ghosting'),
                      const SizedBox(height: 20),
                      
                      // Troubleshooting
                      const Text(
                        'Troubleshooting',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Can\'t connect? Make sure Bluetooth is on and touch the frame to wake it'),
                      _buildBulletPoint('Frame not responding? Hold the boot button 5 seconds for factory reset'),
                      _buildBulletPoint('Low battery? Connect USB cable - frame shows charging status to the app'),
                    ],
                  ),
                ),
              ),
              // Footer
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Got it!', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBulletPoint(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontSize: 16, color: Colors.blue, fontWeight: FontWeight.bold)),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 14, height: 1.4, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  void _showCalibrateSensorDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 650),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.orange.shade600, Colors.orange.shade400],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.tune, color: Colors.white, size: 32),
                    SizedBox(width: 12),
                    Text(
                      'Calibrate Touch Sensor',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // What is Calibration
                      const Text(
                        'What is Sensor Calibration?',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'The e-paper frame uses a capacitive touch sensor to detect your finger touch. Calibration adjusts the sensor\'s sensitivity to ensure reliable touch detection in different environmental conditions.',
                        style: TextStyle(fontSize: 14, color: Colors.black87, height: 1.4),
                      ),
                      const SizedBox(height: 20),
                      
                      // When to Calibrate
                      const Text(
                        'When Should You Calibrate?',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('Touch sensor not responding to your finger'),
                      _buildBulletPoint('Frame waking up randomly without touch'),
                      _buildBulletPoint('After changing environmental conditions (temperature/humidity)'),
                      _buildBulletPoint('After installing frame in a new location'),
                      const SizedBox(height: 20),
                      
                      // How to Calibrate
                      const Text(
                        'How to Calibrate',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Follow these simple steps:',
                        style: TextStyle(fontSize: 14, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildNumberedPoint('1', 'Make sure your frame is powered on and connected via Bluetooth'),
                      _buildNumberedPoint('2', 'Do NOT touch the sensor area during calibration'),
                      _buildNumberedPoint('3', 'Tap the "Calibrate Now" button below'),
                      _buildNumberedPoint('4', 'Wait for the frame\'s LED to flash 3 times confirming success'),
                      const SizedBox(height: 20),
                      
                      // Important Notes
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.info_outline, color: Colors.orange.shade700, size: 20),
                                const SizedBox(width: 8),
                                Text(
                                  'Important',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orange.shade700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '• Keep your finger AWAY from the sensor during calibration\n'
                              '• The calibration measures the baseline "no-touch" state\n'
                              '• You can also press the physical boot button (GPIO0) on the back to calibrate',
                              style: TextStyle(fontSize: 13, color: Colors.black87, height: 1.5),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      
                      // Pro Tip
                      const Text(
                        'Pro Tip',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
                      const SizedBox(height: 8),
                      _buildBulletPoint('If touch still doesn\'t work after calibration, try cleaning the sensor area with a soft cloth'),
                      _buildBulletPoint('Metal objects near the sensor can interfere - ensure proper mounting'),
                      _buildBulletPoint('Extreme temperatures may require recalibration'),
                    ],
                  ),
                ),
              ),
              // Footer with Calibrate Button
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _sendCalibrationCommand();
                        },
                        icon: const Icon(Icons.settings_remote, size: 20),
                        label: const Text('Calibrate Now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.orange.shade600,
                          side: BorderSide(color: Colors.orange.shade600),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNumberedPoint(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                number,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.orange.shade700,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                style: const TextStyle(fontSize: 14, height: 1.4, color: Colors.black87),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPoliciesDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.green.shade600, Colors.green.shade400],
                  ),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.policy_outlined, color: Colors.white, size: 32),
                    SizedBox(width: 12),
                    Text(
                      'Privacy & Policies',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              // Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildPolicySection(
                        title: 'Data Privacy',
                        icon: Icons.security,
                        content: 'CanvasBT processes all images locally on your device. Your photos never leave your phone except when you explicitly send them to your e-paper display via Bluetooth.',
                      ),
                      const SizedBox(height: 20),
                      _buildPolicySection(
                        title: 'Bluetooth Connection',
                        icon: Icons.bluetooth_connected,
                        content: 'The app requires Bluetooth permission to communicate with your e-paper display. Connection is direct and secure between your phone and display only.',
                      ),
                      const SizedBox(height: 20),
                      _buildPolicySection(
                        title: 'Image Sources',
                        icon: Icons.photo_library,
                        content: 'When using Gallery, you access your own photos. Pixabay integration provides free stock images. AI generation uses OpenAI\'s DALL·E API with your provided key.',
                      ),
                      const SizedBox(height: 20),
                      _buildPolicySection(
                        title: 'Storage',
                        icon: Icons.storage,
                        content: 'The app stores your processed images and settings locally on your device for quick access. You can clear this data anytime from your device settings.',
                      ),
                      const SizedBox(height: 20),
                      _buildPolicySection(
                        title: 'Third-Party Services',
                        icon: Icons.cloud_outlined,
                        content: 'Pixabay API is used for image search. OpenAI API is used for AI generation (requires your API key). No personal data is shared with these services.',
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.verified_user, color: Colors.green.shade700, size: 24),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'Your privacy matters! We don\'t collect, store, or share your personal information.',
                                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black87),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Footer
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text('Close', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPolicySection({required String title, required IconData icon, required String content}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.green.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: Colors.green.shade700, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.only(left: 50),
          child: Text(
            content,
            style: const TextStyle(fontSize: 14, height: 1.6, color: Colors.black87),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight((_headerAspectRatio!=null ? MediaQuery.of(context).size.width / _headerAspectRatio! : 88) - 24),
        child: (_headerAsset!=null)
            ? Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 0, bottom: 0),
                    child: Image.asset(
                      _headerAsset!,
                      fit: BoxFit.fitWidth,
                      filterQuality: FilterQuality.high,
                      alignment: Alignment.topCenter,
                    ),
                  ),
                  Positioned(
                    top: 3,
                    left: 18,
                    child: SafeArea(
                      child: GestureDetector(
                        onTap: () => _scaffoldKey.currentState?.openDrawer(),
                        child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.9),
                              borderRadius: BorderRadius.circular(4),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            padding: const EdgeInsets.all(4),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(height: 4, width: 28, color: Colors.black87),
                                const SizedBox(height: 4),
                                Container(height: 4, width: 28, color: Colors.black87),
                                const SizedBox(height: 4),
                                Container(height: 4, width: 28, color: Colors.black87),
                              ],
                            ),
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : const SizedBox.shrink(),
      ),
      drawer: _buildDrawer(),
  body: Stack(
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(12,5,12,8), child: _buildConnected()),
          if(_showIntro)
            Positioned.fill(
              child: Container(
                color: Colors.white,
                child: Center(
                  child: FadeTransition(
                    opacity: _introOpacity,
                    child: ScaleTransition(
                      scale: _introScale,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: MediaQuery.of(context).size.width*0.55,
                            height: MediaQuery.of(context).size.width*0.55,
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 24, offset: Offset(0,10))]),
                            clipBehavior: Clip.antiAlias,
                            child: Image.asset('Logo/Applogo.jpg', fit: BoxFit.cover, filterQuality: FilterQuality.high),
                          ),
                          const SizedBox(height: 18),
                          const SizedBox(width: 46, child: LinearProgressIndicator(minHeight: 4)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
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

  // Crop frame builder: constructs the black rectangle ("crop frame") shown in the editor's first window.
  // The crop frame is the area the user fits the image into; it changes orientation with the Portrait/Landscape button.
  Widget _buildCropFrame() {
    return SizedBox(
      height: 300, // keep constant to prevent image shift during sending
      child: LayoutBuilder(builder: (context, constraints) {
        final workspaceW = constraints.maxWidth;
        final workspaceH = constraints.maxHeight;
        
        print('🖼️ _buildCropFrame() called:');
        print('  _viewInitialized: $_viewInitialized');
        print('  _viewScale: ${_viewScale.toStringAsFixed(6)}');
        print('  Current frame: ${_frameWidth.toStringAsFixed(2)}px × ${_frameHeight.toStringAsFixed(2)}px');
        
        // Only recalculate frame if not already initialized
        // When loading saved images, frame is pre-calculated and should not be changed
        if (!_viewInitialized || _frameWidth == 0 || _frameHeight == 0) {
          print('  Recalculating frame dimensions...');
          // Calculate crop frame dimensions using hardware aspect only (no image-based resizing)
          const double margin = 0.9;
          final double maxW = workspaceW * margin;
          final double maxH = workspaceH * margin;
          double aspect = _isPortrait ? (IMAGE_HEIGHT / IMAGE_WIDTH) : (IMAGE_WIDTH / IMAGE_HEIGHT); // width/height
          if (maxW / maxH > aspect) {
            // height-limited
            _frameHeight = maxH;
            _frameWidth = _frameHeight * aspect;
          } else {
            // width-limited
            _frameWidth = maxW;
            _frameHeight = _frameWidth / aspect;
          }
          
          print('  New frame: ${_frameWidth.toStringAsFixed(2)}px × ${_frameHeight.toStringAsFixed(2)}px');
        } else {
          print('  ✅ Keeping existing frame dimensions (already initialized)');
        }
        
        // No portrait-specific shrink; maintain exact hardware aspect ratio
        _frameOrigin = Offset(
          (workspaceW - _frameWidth)/2,
          (workspaceH - _frameHeight)/2,
        );
        _frameOrigin = _snapOffset(_frameOrigin);
        if (!_viewInitialized && _uiOriginal != null) {
          print('  ⚠️ !_viewInitialized - recalculating scale!');
          final iw = _uiOriginal!.width.toDouble();
          final ih = _uiOriginal!.height.toDouble();
          
          // Scale to fit: works for both saved images (800x480/480x800) and regular photos
          // Saved images will have fitScale close to 1.0, photos will be scaled down to fit
          final fitScale = math.min(_frameWidth / iw, _frameHeight / ih);
          
          print('  New fitScale: ${fitScale.toStringAsFixed(6)}');
          _viewScale = fitScale;
          // Allow zooming out to a small fraction of fit scale, in, to large magnification
          _minScale = fitScale * 0.01; // 1% of fit size (very far zoom out)
          if (_minScale < 0.005) _minScale = 0.005;
          _maxScale = fitScale * 80; // very deep zoom possible
          // center image to crop frame and ensure no rotation
          _viewRotation = 0.0;
          _centerViewOnFrame(fitScale);
          _viewInitialized = true;
          // Update frame border color for initial image
          _updateFrameBorderColor();
          // Cropped preview now paints directly; no PNG cache needed
        } else {
          print('  ✅ _viewInitialized=true, keeping existing scale');
        }
        // If a Saved→Editor placement requested a recenter, apply it now using final frame values
        if (_needsRecenteringOnce) {
          print('  ⚠️ _needsRecenteringOnce is true - recentering!');
          final iw = _uiOriginal?.width.toDouble() ?? 0;
          final ih = _uiOriginal?.height.toDouble() ?? 0;
          final fitScaleNow = (iw>0 && ih>0) ? math.min(_frameWidth / iw, _frameHeight / ih) : 1.0;
          final double scale = (_viewScale.isFinite && _viewScale > 0) ? _viewScale : fitScaleNow;
          print('  Recentering with scale: ${scale.toStringAsFixed(6)}');
          _viewRotation = 0.0;
          _centerViewOnFrame(scale);
          _needsRecenteringOnce = false;
        }
        
        if (_uiOriginal != null) {
          final scaledW = _uiOriginal!.width * _viewScale;
          final scaledH = _uiOriginal!.height * _viewScale;
          print('  Final rendered: Image ${scaledW.toStringAsFixed(2)}×${scaledH.toStringAsFixed(2)} in Frame ${_frameWidth.toStringAsFixed(2)}×${_frameHeight.toStringAsFixed(2)}');
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
              // Update frame border color based on image behind it
              _updateFrameBorderColor();
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
                      border: Border.all(color: _frameBorderColor, width: 3),
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
                  child: Builder(
                    builder: (btnContext) => IconButton(
                      icon: const Icon(Icons.info_outline, color: Colors.white, size: 24),
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
                      onPressed: () {
                        showDialog(
                          context: btnContext,
                          builder: (ctx) => AlertDialog(
                            title: Row(
                              children: const [
                                Icon(Icons.touch_app, color: Colors.blue),
                                SizedBox(width: 8),
                                Text('How to Adjust Image'),
                              ],
                            ),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text(
                                  '• Drag with one finger to move',
                                  style: TextStyle(fontSize: 15, height: 1.6),
                                ),
                                Text(
                                  '• Pinch with two fingers to zoom',
                                  style: TextStyle(fontSize: 15, height: 1.6),
                                ),
                                Text(
                                  '• Rotate with two fingers to angle',
                                  style: TextStyle(fontSize: 15, height: 1.6),
                                ),
                                Text(
                                  '• Double-tap to reset view',
                                  style: TextStyle(fontSize: 15, height: 1.6),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Got it!'),
                              ),
                            ],
                          ),
                        );
                      },
                      tooltip: 'Help',
                    ),
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
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(0,0,img.width.toDouble(), img.height.toDouble()),
      image: img,
      fit: BoxFit.fill,
      alignment: Alignment.center,
      filterQuality: FilterQuality.high,
    );
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
    paintImage(
      canvas: canvas,
      rect: Rect.fromLTWH(0,0,image.width.toDouble(), image.height.toDouble()),
      image: image,
      fit: BoxFit.fill,
      alignment: Alignment.center,
      filterQuality: FilterQuality.high,
    );
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
  final bool wasPortrait; // orientation when saved
  final bool isDefaultAsset; // true if from bundled assets
  final String title; // display name
  const _LibraryEntry({required this.id, required this.image, required this.rawCodes, required this.pngBytes, required this.created, required this.wasPortrait, required this.isDefaultAsset, required this.title});
}

// Simple data holder for Pixabay search results
class _PixabayImage {
  final String id;
  final String previewUrl;
  final String fullUrl;
  final int width;
  final int height;
  final String author;
  const _PixabayImage({required this.id, required this.previewUrl, required this.fullUrl, required this.width, required this.height, required this.author});
}

// Default asset list - empty to not show sample images in Saved
const List<String> kDefaultAssetImages = [];

extension _LibraryPersistence on _EPaperImageSenderState {
  // Marker file to remember if user deleted the bundled sample (prevents reseeding)
  File? get _asset1DeletedFlagFile =>
      (_libraryDir == null) ? null : File('${_libraryDir!.path}/asset_image1.deleted');
  Future<void> _initPersistentLibrary() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _libraryDir = Directory('${dir.path}/library');
      if(!await _libraryDir!.exists()){
        await _libraryDir!.create(recursive: true);
      }
      final indexFile = File('${_libraryDir!.path}/index.json');
      if(await indexFile.exists()){
        await _loadLibraryIndex(indexFile);
      }
      // Seed sample image from assets into Saved if missing
      await _seedSampleImageIfMissing();
      _refresh();
    } catch (e) {
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
        final wasPortrait = (item['wasPortrait'] == true) || (item['wasVertical'] == true); // backward compatible
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
            final correctedPortrait = isAsset ? _isPortraitAsset(baseName) : wasPortrait;
            _library.add(_LibraryEntry(
              id: id,
              image: decoded.clone(),
              rawCodes: Uint8List.fromList(rawCodes),
              pngBytes: pngBytes,
              created: DateTime.fromMillisecondsSinceEpoch(createdMs),
              wasPortrait: correctedPortrait,
              isDefaultAsset: isAsset,
              title: title,
            ));
          }catch(_){ }
        }
      }
    }catch(e){ }
  }

  Future<void> _persistLibraryEntry(_LibraryEntry entry, {bool writeIndex = true}) async {
    try{
      if(_libraryDir==null) return;
      final rawFile = File('${_libraryDir!.path}/${entry.id}.raw');
      final pngFile = File('${_libraryDir!.path}/${entry.id}.png');
      await rawFile.writeAsBytes(entry.rawCodes, flush: true);
      await pngFile.writeAsBytes(entry.pngBytes, flush: true);
      if(writeIndex){ await _writeLibraryIndex(); }
    }catch(e){ }
  }

  Future<void> _writeLibraryIndex() async {
    try{
      if(_libraryDir==null) return;
      final indexFile = File('${_libraryDir!.path}/index.json');
      final list = _library.map((e)=>{
        'id': e.id,
        'created': e.created.millisecondsSinceEpoch,
        // Write both keys for backward/forward compatibility
        'wasPortrait': e.wasPortrait,
        'wasVertical': e.wasPortrait,
      }).toList();
      await indexFile.writeAsString(jsonEncode(list), flush: true);
    }catch(e){ }
  }

  Future<void> _deleteLibraryEntryFiles(_LibraryEntry entry) async {
    try{
      if(_libraryDir==null) return;
      final rawFile = File('${_libraryDir!.path}/${entry.id}.raw');
      final pngFile = File('${_libraryDir!.path}/${entry.id}.png');
      if(await rawFile.exists()) { await rawFile.delete(); }
      if(await pngFile.exists()) { await pngFile.delete(); }
      // If deleting the bundled sample, record a flag so we don't auto-reseed it later
      if (entry.id.toLowerCase() == 'asset_image1') {
        final flag = _asset1DeletedFlagFile;
        if (flag != null) {
          try { await flag.writeAsString('deleted', flush: true); } catch (_) {}
        }
      }
      await _writeLibraryIndex();
    }catch(e){ }
  }

  // Seed SamplePics/Image1.* into the library as a default asset, treated like a saved image
  Future<void> _seedSampleImageIfMissing() async {
    try{
      // Respect user deletion: if flag exists, do not re-seed
      final delFlag = _asset1DeletedFlagFile;
      if (delFlag != null && await delFlag.exists()) return;
      // Avoid duplicate seeding
      if (_library.any((e) => e.id.toLowerCase() == 'asset_image1')) return;
      // Discover asset path via manifest (supports png/jpg variants)
      final manifestText = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifest = jsonDecode(manifestText);
      String? assetPath;
      for (final key in manifest.keys) {
        final k = key.toString().toLowerCase();
        if (k.contains('samplepics/image1')) { assetPath = key; break; }
      }
      // Fallback to common extensions if manifest scan missed it
      assetPath ??= await _tryFindFirstExistingAsset([
        'SamplePics/Image1.png',
        'SamplePics/Image1.jpg',
        'SamplePics/Image1.jpeg',
        'SamplePics/Image1.webp',
      ]);
      if (assetPath == null) return; // not packaged
      // Load asset bytes
      final data = await rootBundle.load(assetPath);
      final Uint8List bytes = data.buffer.asUint8List();
      // Decode
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      final bool wasPortrait = decoded.height > decoded.width;
      // Build 800x480 base (landscape canvas) using fit letterbox
      final img.Image base = _fitImage(decoded);
      // Quantize + raw codes using the same pipeline as saving
      final Tuple2<img.Image, Uint8List> q = _quantizeTo6ColorAndCreateRawBytes(base);
      img.Image disp = q.item1; // 800x480
      final Uint8List rawCodes = q.item2;
      // Store PNG in the same visual orientation as the frame orientation marker
      if (wasPortrait) {
        disp = img.copyRotate(disp, angle: -90); // store portrait PNG
      }
      final Uint8List pngBytes = Uint8List.fromList(img.encodePng(disp));
      // Create and persist entry
      final entry = _LibraryEntry(
        id: 'asset_image1',
        image: q.item1.clone(),
        rawCodes: rawCodes,
        pngBytes: pngBytes,
        created: DateTime.now(),
        wasPortrait: wasPortrait,
        isDefaultAsset: true,
        title: 'Image1',
      );
      _library.insert(0, entry);
      _refresh();
      await _persistLibraryEntry(entry);
      _updateStatus('Sample image added to Saved');
    } catch (e){
    }
  }

  // Try direct asset paths in order; returns first that exists, else null
  Future<String?> _tryFindFirstExistingAsset(List<String> candidates) async {
    for (final p in candidates) {
      try {
        await rootBundle.load(p);
        return p;
      } catch (_) {}
    }
    return null;
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
