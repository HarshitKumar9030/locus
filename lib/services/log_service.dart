import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';

/// Remote logging service to capture and send logs from devices
/// Especially useful for debugging issues on specific devices like Redmi 9A
class LogService {
  static const String _logQueueKey = 'device_log_queue';
  static const int _maxLogQueueSize = 200;
  static const Duration _sendTimeout = Duration(seconds: 10);
  
  static String? _deviceId;
  static String? _deviceModel;
  static String? _androidVersion;
  
  /// Initialize device info
  static Future<void> init() async {
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        _deviceId = androidInfo.id;
        _deviceModel = '${androidInfo.manufacturer} ${androidInfo.model}';
        _androidVersion = 'Android ${androidInfo.version.release} (SDK ${androidInfo.version.sdkInt})';
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        _deviceId = iosInfo.identifierForVendor;
        _deviceModel = iosInfo.utsname.machine;
        _androidVersion = 'iOS ${iosInfo.systemVersion}';
      }
    } catch (e) {
      print('LogService: Error getting device info: $e');
    }
  }
  
  /// Log levels
  static const String INFO = 'INFO';
  static const String WARN = 'WARN';
  static const String ERROR = 'ERROR';
  static const String DEBUG = 'DEBUG';
  
  /// Log a message and queue it for sending
  static Future<void> log(String level, String tag, String message, {Map<String, dynamic>? extra}) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final logEntry = {
      'level': level,
      'tag': tag,
      'message': message,
      'timestamp': timestamp,
      'deviceId': _deviceId ?? 'unknown',
      'deviceModel': _deviceModel ?? 'unknown',
      'androidVersion': _androidVersion ?? 'unknown',
      'extra': extra,
    };
    
    // Also print locally for debugging
    print('[$level] $tag: $message');
    
    // Queue for remote sending
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> queue = prefs.getStringList(_logQueueKey) ?? [];
      
      // Keep queue bounded
      if (queue.length >= _maxLogQueueSize) {
        queue = queue.sublist(queue.length - _maxLogQueueSize + 1);
      }
      
      queue.add(jsonEncode(logEntry));
      await prefs.setStringList(_logQueueKey, queue);
    } catch (e) {
      print('LogService: Error queueing log: $e');
    }
  }
  
  /// Convenience methods
  static Future<void> info(String tag, String message, {Map<String, dynamic>? extra}) => 
      log(INFO, tag, message, extra: extra);
  
  static Future<void> warn(String tag, String message, {Map<String, dynamic>? extra}) => 
      log(WARN, tag, message, extra: extra);
  
  static Future<void> error(String tag, String message, {Map<String, dynamic>? extra}) => 
      log(ERROR, tag, message, extra: extra);
  
  static Future<void> debug(String tag, String message, {Map<String, dynamic>? extra}) => 
      log(DEBUG, tag, message, extra: extra);
  
  /// Send queued logs to the server
  static Future<bool> sendLogs(String baseUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_logQueueKey) ?? [];
      
      if (queue.isEmpty) return true;
      
      final logs = queue.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
      
      final response = await http.post(
        Uri.parse('$baseUrl/api/logs'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': _deviceId ?? 'unknown',
          'deviceModel': _deviceModel ?? 'unknown',
          'logs': logs,
        }),
      ).timeout(_sendTimeout);
      
      if (response.statusCode == 200) {
        // Clear sent logs
        await prefs.setStringList(_logQueueKey, []);
        print('LogService: Successfully sent ${logs.length} logs');
        return true;
      } else {
        print('LogService: Failed to send logs: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('LogService: Error sending logs: $e');
      return false;
    }
  }
  
  /// Get current queue size
  static Future<int> getQueueSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_logQueueKey) ?? [];
      return queue.length;
    } catch (e) {
      return 0;
    }
  }
  
  /// Clear all queued logs
  static Future<void> clearLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_logQueueKey, []);
    } catch (e) {
      print('LogService: Error clearing logs: $e');
    }
  }
}
