import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  static const String _baseUrlKey = 'api_base_url';
  
  // Default to localhost for emulator (10.0.2.2 for Android)
  // The user should change this in the app settings
  static const String _defaultUrl = 'http://10.0.2.2:3000'; 

  Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_baseUrlKey) ?? _defaultUrl;
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseUrlKey, url);
  }

  Future<Map<String, dynamic>?> startSession(String deviceId, int durationHours) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/session/start'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceId': deviceId,
          'duration': durationHours * 60 * 60 * 1000,
        }),
      );

      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      print('Error starting session: $e');
    }
    return null;
  }

  Future<void> stopSession(String sessionId) async {
    final baseUrl = await getBaseUrl();
    try {
      await http.post(
        Uri.parse('$baseUrl/api/session/stop'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'sessionId': sessionId}),
      );
    } catch (e) {
      print('Error stopping session: $e');
    }
  }

  Future<bool> sendLocations(List<Map<String, dynamic>> locations) async {
    final baseUrl = await getBaseUrl();
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/location'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(locations),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Error sending locations: $e');
      return false;
    }
  }

  Future<bool> sendLocation(String sessionId, double lat, double lng, int timestamp) async {
    return sendLocations([{
      'sessionId': sessionId,
      'latitude': lat,
      'longitude': lng,
      'timestamp': timestamp,
    }]);
  }
}
