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
  // =============================================================
  // CONSTANTS / STATIC CONFIG
  // =============================================================
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
  // Periodic connection status for bottom bar
  Timer? _connectionStatusTimer;
  String _connectionStatusText = 'Not connected';
  // Stay on the second screen even if temporarily disconnected (for background auto-reconnect)
  bool _stayOnSecondScreen = false;
  // Header/logo asset (FramePic/eframe.*) to show in the AppBar
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
  double _ditherStrength = 1.0; // 0=off .. 1=full
  double _strongColorBoost = 1.0; // influences brightness/contrast/saturation mapping (default max)

  // =============================================================
  // IN-MEMORY LIBRARY (session only)
  // =============================================================
  final List<_LibraryEntry> _library = [];
  int? _selectedLibraryIndex; // selected index in library view
  bool _showLibrary = false; // toggle to show library screen when connected
  bool _showDeviceList = false; // show device list while connected
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
  final TextEditingController _aiPromptController = TextEditingController(text: 'eframe art');
  bool _aiIsGenerating = false;
  Uint8List? _aiPngBytes;
  String? _aiError;
  bool _aiPortrait = false; // false = landscape (800x480), true = portrait (480x800)
  final ButtonStyle _smallBtnStyle = ElevatedButton.styleFrom(
    minimumSize: const Size(60,34),
    padding: const EdgeInsets.symmetric(horizontal:8, vertical:4),
    textStyle: const TextStyle(fontSize:11, fontWeight: FontWeight.w500),
  );

  Widget _smallBtn(String label, VoidCallback? onPressed, {IconData? icon}){
    if(icon!=null){
      return ElevatedButton.icon(
        style: _smallBtnStyle,
        onPressed: onPressed,
        icon: Icon(icon, size:14),
        label: Text(label),
      );
    }
    return ElevatedButton(
      style: _smallBtnStyle,
      onPressed: onPressed,
      child: Text(label),
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
  // Top promo images from assets/FramePic
  List<String> _topPromoAssets = const [];
  @override
  void initState(){
    super.initState();
    _checkPermissions();
    _initPersistentLibrary();
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
    // Discover top promo images under FramePic/
    _loadTopPromoAssets();
  // Load header/logo asset named eframe in FramePic/ or FramePics/
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

  Future<void> _loadTopPromoAssets() async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestJson);
      // Collect images from both FramePic/ and FramePics/
      final all = manifestMap.keys.where((k)=>
        (k.startsWith('FramePic/') || k.startsWith('FramePics/')) &&
        (k.toLowerCase().endsWith('.png') || k.toLowerCase().endsWith('.jpg') || k.toLowerCase().endsWith('.jpeg'))
      ).toList();
      // Exclude the header/logo 'eframe' from promo strip
      final filtered = all.where((k){
        final base = k.split('/').last.toLowerCase();
        final noExt = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
        return noExt != 'eframe';
      }).toList();
      // Prefer images with 'finger' (e.g., frameFinger.png) first
      filtered.sort((a,b){
        int pri(String s){
          final base = s.split('/').last.toLowerCase();
          return base.contains('finger') ? 0 : 1;
        }
        final pa = pri(a); final pb = pri(b);
        if(pa!=pb) return pa - pb;
        return a.compareTo(b);
      });
      // Take up to two
      final list = filtered.take(2).toList();
      if(mounted){ setState(()=> _topPromoAssets = list); }
    }catch(_){ /* ignore */ }
  }

  Future<void> _loadHeaderAsset() async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = json.decode(manifestJson);
      final keys = manifestMap.keys.where((k)=> (k.startsWith('FramePic/') || k.startsWith('FramePics/')) ).toList();
      String? chosen;
      for(final k in keys){
        final base = k.split('/').last.toLowerCase();
        final nameNoExt = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
        if(nameNoExt == 'eframe'){ chosen = k; break; }
        if(chosen==null && nameNoExt.contains('eframe')){ chosen = k; }
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
          title: const Text('Please Toch the corner of Frame and click On connect'),
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
              child: const Text('Connect'),
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
      // list of candidate image assets under FramePic(s)/
      final keys = manifestMap.keys.where((k){
        if(!(k.startsWith('FramePic/') || k.startsWith('FramePics/'))) return false;
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
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children:[
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _pickImage,
              icon: const Icon(Icons.photo_library, size: 18),
              label: const Text('Gallary', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: _library.isEmpty ? null : Colors.green.shade600,
                foregroundColor: _library.isEmpty ? null : Colors.white,
              ),
              onPressed: _library.isEmpty ? null : (){ setState(()=> _showLibrary = true); },
              icon: const Icon(Icons.collections, size: 18),
              label: Text('Library(${_library.length})', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: (){ setState((){ _showAi = true; _aiError = null; }); },
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('AI image', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
    if(_showDeviceList){
      return _buildDisconnected();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _connectedTopBar(),
        const SizedBox(height: 8),
        if (_originalImage != null) _buildCropFrame() else Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: _isSending ? 6 : 0),
            child: Center(
            child: _processedPngBytes != null
                ? (_verticalFrame
                    ? RotatedBox(quarterTurns: 3, child: Image.memory(_processedPngBytes!, fit: BoxFit.contain))
                    : Image.memory(_processedPngBytes!, fit: BoxFit.contain))
                : (_library.isNotEmpty
                    ? ( (_library.first.wasVertical)
                        ? RotatedBox(quarterTurns: 3, child: Image.memory(_library.first.pngBytes, fit: BoxFit.contain))
                        : Image.memory(_library.first.pngBytes, fit: BoxFit.contain))
                    : Text('Pick an image', style: Theme.of(context).textTheme.titleMedium)),
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
          Text('${_transferProgress}%  ${_transferSpeed.toStringAsFixed(1)} KB/s', textAlign: TextAlign.center, style: const TextStyle(fontSize:12)),
        ],
        SizedBox(height: _isSending ? 0 : 4),
        _statusCard(),
      ],
    );
  }

  // Main action bar (orientation toggle, add to library, process, send, reset)
  Widget _buildActionBar(){
    return Container(
      padding: const EdgeInsets.symmetric(horizontal:8, vertical:2),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(8),
      ),
  child: Row(children:[
  _smallBtn(_verticalFrame ? 'Portrait' : 'Landscape', _originalImage==null ? null : (){
    setState((){ _verticalFrame = !_verticalFrame; _viewInitialized=false; _processedImage=null; _processedBytes=null; _processedPngBytes=null; });
  }, icon: Icons.screen_rotation),
        const SizedBox(width:6),
  _smallBtn('Add in Library', _originalImage==null ? null : _addCurrentToLibrary, icon: Icons.library_add),
        const SizedBox(width:6),
  _smallBtn(
    'Send',
    _sendOrProcessThenSend,
  icon: Icons.send),
    const SizedBox(width:6),
    _smallBtn('Exit', _exitApp, icon: Icons.exit_to_app),
      ]),
    );
  }

  // ========================= AI IMAGES VIEW =========================
  Widget _buildAiView(){
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children:[
          // Generate first, with green color
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
          const SizedBox(width: 8),
          // Orientation toggle next
          _smallBtn(_aiPortrait ? 'Portrait' : 'Landscape', _aiIsGenerating ? null : (){ setState(()=> _aiPortrait = !_aiPortrait); }, icon: Icons.screen_rotation),
          const SizedBox(width: 8),
          // Use in Editor next
          _smallBtn('Use in Editor', (_aiPngBytes==null || _aiIsGenerating) ? null : _useAiImage, icon: Icons.open_in_new),
          const Spacer(),
          // Back last, aligned right
          _smallBtn('Back', (){ setState((){ _showAi = false; }); }, icon: Icons.arrow_back),
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
              color: Colors.white,
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
      const String aiPrefix = 'Paiting colourful (black,white,red,yellow,blue,green) ';
      final safePrompt = (aiPrefix + (prompt.isEmpty ? '' : prompt)).trim();
      final encoded = Uri.encodeComponent(safePrompt);
      final seed = (safePrompt.hashCode & 0x7fffffff).toString();
      final genW = _aiPortrait ? IMAGE_HEIGHT : IMAGE_WIDTH;  // 480 if portrait
      final genH = _aiPortrait ? IMAGE_WIDTH : IMAGE_HEIGHT;  // 800 if portrait
      final candidates = <Uri>[
        Uri.parse('https://image.pollinations.ai/prompt/$encoded?width=$genW&height=$genH&seed=$seed&nologo=true'),
        Uri.parse('https://image.pollinations.ai/prompt/$encoded?size=${genW}x${genH}&seed=$seed&nologo=true'),
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
        ..userAgent = 'eframe-app'
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
      final int w = _aiPortrait ? IMAGE_HEIGHT : IMAGE_WIDTH;
      final int h = _aiPortrait ? IMAGE_WIDTH : IMAGE_HEIGHT;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0,0,w.toDouble(),h.toDouble()));
      final hash = prompt.hashCode;
      Color c1 = HSVColor.fromAHSV(1.0, (hash & 0xFF).toDouble() % 360, 0.5, 0.95).toColor();
      Color c2 = HSVColor.fromAHSV(1.0, ((hash>>8) & 0xFF).toDouble() % 360, 0.7, 0.7).toColor();
      final paint = Paint()
        ..shader = ui.Gradient.linear(const Offset(0,0), Offset(w.toDouble(), h.toDouble()), [c1, c2]);
      canvas.drawRect(Rect.fromLTWH(0,0,w.toDouble(),h.toDouble()), paint);
      final words = prompt.isEmpty ? ['eframe','art'] : prompt.split(RegExp(r'\s+')).take(5).toList();
      final rng = math.Random(hash);
      for(int i=0;i<words.length;i++){
        final px = rng.nextDouble()*w;
        final py = rng.nextDouble()*h;
        final sz = 30.0 + rng.nextDouble()*120.0;
        final p = Paint()..color = HSVColor.fromAHSV(0.8, (rng.nextInt(360)).toDouble(), 0.6, 0.9).toColor();
        canvas.drawCircle(Offset(px,py), sz, p);
      }
      final textPainter = TextPainter(
        text: TextSpan(text: prompt.isEmpty ? 'eframe' : prompt, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700)),
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
        _verticalFrame = _aiPortrait; // match editor orientation to generated image
        _showAi = false;
      });
      await _loadUiImage();
      _updateStatus('AI image loaded into editor');
    }catch(_){
      _updateStatus('Failed to load AI image');
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
    if(_isSending) return;
    // If disconnected, show message and exit
    if(_connectedDevice==null || _rxCharacteristic==null){
      if(!mounted) return;
      // Pick the correct finger image based on current orientation
      final String? fingerAsset = await _resolveFingerAssetForOrientation(_verticalFrame);
      await showDialog(
        context: context,
        builder: (ctx){
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
      return;
    }
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
          _smallBtn('Back', ()=> setState(()=> _showLibrary=false), icon: Icons.arrow_back),
          const SizedBox(width:6),
          _smallBtn(_isSending? 'Sending' : 'Send', (_selectedLibraryIndex==null || _isSending) ? null : _sendSelectedLibraryItem, icon: Icons.send),
          const SizedBox(width:6),
            _smallBtn('Delete', (_selectedLibraryIndex==null || _isSending) ? null : _deleteSelectedLibraryItem, icon: Icons.delete),
          const SizedBox(width:8),
          Expanded(child: Text('Library (${_library.length})', style: const TextStyle(fontSize:13,fontWeight: FontWeight.w600))),
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

  // Preview: show only "In Frame" (left); processing happens on Send
  Widget _buildPreviewAndSliders(){
    return SizedBox(
      height: _isSending ? 190 : 210,
      child: Row(children:[
  if (_originalImage != null) Expanded(child: _previewPanel('In Frame', _croppedOriginalPreview())),
      ]),
    );
  }

  // Build a preview representing only the area inside the back square (frame)
  Widget _croppedOriginalPreview(){
    // Render immediately; avoid showing any placeholder during quick orientation toggles.
    // Frame dimensions are recomputed in _buildCropFrame on every build.
    if (_uiOriginal == null || _frameWidth==0 || _frameHeight==0) {
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
              border: Border.all(color: Colors.white, width: whiteBorder),
            ),
            child: SizedBox(
              width: _frameWidth,
              height: _frameHeight,
              child: CustomPaint(
                painter: _CroppedPreviewPainter(
                  image: _uiOriginal!,
                  scale: _viewScale,
                  rotation: _viewRotation,
                  translation: _viewTranslation,
                  frameOrigin: _frameOrigin,
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
          color: Colors.white,
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
              // Refresh button top-right
              Positioned(
                top: 0,
                right: 0,
                child: IconButton(
                  onPressed: _resetView,
                  tooltip: 'Reset View',
                  icon: const Icon(Icons.refresh, size: 18),
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
  void _updateStatus(String message) {
    final now = DateTime.now();
    if(_isSending && now.difference(_lastStatusUpdate).inMilliseconds < 350 && !message.startsWith('Progress')){ return; }
    _lastStatusUpdate = now;
    if(mounted){ setState(()=> _statusMessage = message); }
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
        .map((m) => [m.rgbColor.red, m.rgbColor.green, m.rgbColor.blue])
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
    _updateStatus("finding eframe");
    
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
              _updateStatus("Auto-connecting to ${name}");
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
  _showDeviceList = false;
        _stayOnSecondScreen = true; // remain on second screen going forward
      });
      // Listen for future connection state changes and auto-reconnect
      await _connStateSub?.cancel();
      _connStateSub = device.connectionState.listen((s) async {
        if(s == BluetoothConnectionState.disconnected){
          if(mounted){
            setState((){
              _connectedDevice = null;
              _rxCharacteristic = null;
              // If we are staying on second screen, leave _showDeviceList=false so UI remains
              if(!_stayOnSecondScreen){ _showDeviceList = true; }
            });
            _updateStatus('Device disconnected. Reconnecting...');
          }
          if(!_isScanning && !_isConnecting){ _scanForDevices(); }
        }
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
  _showDeviceList = true;
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
      
      // Perform vertical flip (device correction) then horizontal flip to intentionally show a flipped image on the e-paper (net 180° rotation).
      final int w = IMAGE_WIDTH;
      final int h = IMAGE_HEIGHT;
      final Uint8List src = _processedBytes!; // raw codes length w*h
      // Vertical flip
      final Uint8List vFlipped = Uint8List(src.length);
      for (int y = 0; y < h; y++) {
        final int srcOffset = y * w;
        final int dstOffset = (h - 1 - y) * w;
        vFlipped.setRange(dstOffset, dstOffset + w, src, srcOffset);
      }
      // Horizontal flip on the vertically flipped buffer -> 180° rotation overall
      final Uint8List vhFlipped = Uint8List(src.length);
      for (int y = 0; y < h; y++) {
        final int row = y * w;
        for (int x = 0; x < w; x++) {
          vhFlipped[row + (w - 1 - x)] = vFlipped[row + x];
        }
      }
      Uint8List packedData = _packPixels(vhFlipped);
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: false,
      title: const SizedBox.shrink(),
      toolbarHeight: _headerAspectRatio!=null ? MediaQuery.of(context).size.width / _headerAspectRatio! : 88,
      backgroundColor: Theme.of(context).colorScheme.inversePrimary,
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
    body: Padding(padding: const EdgeInsets.all(12), child: (((_connectedDevice==null) && !_stayOnSecondScreen) || _showDeviceList) ? _buildDisconnected() : _buildConnected()),
  );

  Widget _buildDisconnected(){
    // Auto-start scanning while the first window is visible
    if(!_isScanning && !_isConnecting && _connectedDevice==null){
      // Fire-and-forget; UI will update from scan stream
      _scanForDevices();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
  if(_topPromoAssets.isNotEmpty) ...[
    SizedBox(
      height: 200, // give more area to avoid cropping
      child: Row(children:[
        for(final p in _topPromoAssets)
          Expanded(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal:6),
            child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: Colors.grey.shade200),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: Image.asset(p, fit: BoxFit.contain), // show entire image without cropping
            ),
          )),
      ]),
    ),
    const SizedBox(height:8),
  ],
  const Text('Please touch the corner of Frame', style: TextStyle(fontSize:12,fontStyle: FontStyle.italic)),
  const SizedBox(height:8),
        // Connect button hidden; auto-scan/auto-connect runs automatically
        const SizedBox.shrink(),
        const SizedBox(height:6),
        ElevatedButton.icon(
          onPressed: _exitApp,
          icon: const Icon(Icons.exit_to_app),
          label: const Text('Exit'),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.black87, foregroundColor: Colors.white),
        ),
        if(_connectedDevice!=null) ...[
          const SizedBox(height:6),
          ElevatedButton.icon(
            onPressed: _disconnectDevice,
            icon: const Icon(Icons.bluetooth_disabled),
            label: const Text('Disconnect'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
          ),
        ],
        const SizedBox(height:8),
        Expanded(
          child: (!_devicesList.any((d)=> d.advName.isNotEmpty))
              ? Center(
                  child: Text(
                    _isScanning ? 'Scanning for devices...' : 'No devices found',
                    style: const TextStyle(fontSize: 12),
                  ),
                )
              : SingleChildScrollView(
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _devicesList
                            .where((d) => d.advName.isNotEmpty)
                            .map((d) => d.advName)
                            .toSet()
                            .join('\n'),
                        style: const TextStyle(fontSize: 12, height: 1.3),
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(height:8),
        _statusCard(),
      ],
    );
  }

  Widget _statusCard() => Container(
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Colors.grey[200],
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
      height: _isSending ? 290 : 300, // reduced heights to avoid bottom overflow
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
    paintImage(canvas: canvas, rect: Rect.fromLTWH(0,0,img.width.toDouble(), img.height.toDouble()), image: img, fit: BoxFit.contain, alignment: Alignment.topLeft);
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
    paintImage(canvas: canvas, rect: Rect.fromLTWH(0,0,image.width.toDouble(), image.height.toDouble()), image: image, fit: BoxFit.contain, alignment: Alignment.topLeft);
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

// Default asset list (landscape). Updated to new "cat" and "leaves" images (remove old portrait lion/umbrella).
const List<String> kDefaultAssetImages = [
  'FramePics/cat.png',
  'FramePics/leaves.png',
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
              title: _deriveAssetTitle(baseName),
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

  // Discover asset images under FramePics/ by reading the AssetManifest (handles arbitrary filenames)
  Future<List<String>> _discoverAssetManifestImages() async {
    try{
      final manifestJson = await rootBundle.loadString('AssetManifest.json');
      final Map<String, dynamic> manifestMap = jsonDecode(manifestJson);
      final list = manifestMap.keys.where((k)=> k.startsWith('FramePics/') && (k.endsWith('.png')||k.endsWith('.jpg')||k.endsWith('.jpeg'))).toList();
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
    return set.where((p)=> p.startsWith('FramePics/')).toList();
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
    final obsolete = _library.where((e)=> e.isDefaultAsset && (e.id.contains('lion') || e.id.contains('umbrella') || e.id.contains('umberalla'))).toList();
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
