import 'dart:convert';

class AppLog {
  static const bool enabled = true; // flip to false to silence logs
  static const int _maxEntries = 1000;
  static final List<String> _ring = <String>[];

  static int _seq = 0;

  static void d(String tag, String message, [Map<String, Object?> extra = const {}]) {
    if (!enabled) return;
    final ts = DateTime.now().toIso8601String();
    final payload = extra.isEmpty ? '' : ' ' + jsonEncode(extra);
    _seq = (_seq + 1) & 0x7fffffff;
    final line = '[$ts][$tag][#$_seq] $message$payload';
    _push(line);
    // Use print so it shows in logcat/Xcode/Flutter console
    // Avoid debugPrint throttling for long captures
    // ignore: avoid_print
    print('----------');
    print(line);
    print('----------');
  }

  static void e(String tag, String message, [Object? error, StackTrace? stack, Map<String, Object?> extra = const {}]) {
    if (!enabled) return;
    final ts = DateTime.now().toIso8601String();
    final err = error == null ? '' : ' error=$error';
    final st = stack == null ? '' : '\n$stack';
    final payload = extra.isEmpty ? '' : ' ' + jsonEncode(extra);
    _seq = (_seq + 1) & 0x7fffffff;
    final line = '[$ts][$tag][ERROR][#$_seq] $message$err$payload$st';
    _push(line);
    // ignore: avoid_print
    print('----------');
    print(line);
    print('----------');
  }

  static List<String> dump() => List.unmodifiable(_ring);

  static void clear() => _ring.clear();

  static void _push(String line) {
    _ring.add(line);
    if (_ring.length > _maxEntries) {
      _ring.removeAt(0);
    }
  }

  
}
