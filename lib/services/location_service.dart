import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

const notificationChannelId = 'locus_tracking';
const notificationId = 888;
const queueKey = 'offline_location_queue';

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    'Locus Tracking Service',
    description: 'This channel is used for silent location tracking.',
    importance: Importance.low, // Silent notification
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'Locus',
      initialNotificationContent: 'Service active',
      foregroundServiceNotificationId: notificationId,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
      onBackground: onIosBackground,
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final apiService = ApiService();

  service.on('stopService').listen((event) {
    service.stopSelf();
  });

  // Update notification silently
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: "Locus",
      content: "Silent tracking active",
    );
  }

  Timer.periodic(const Duration(seconds: 20), (timer) async {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = prefs.getString('current_session_id');
    final endTimeMillis = prefs.getInt('session_end_time');

    if (sessionId != null && endTimeMillis != null) {
      if (DateTime.now().millisecondsSinceEpoch < endTimeMillis) {
        try {
          final position = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
          
          final newLocation = {
            'sessionId': sessionId,
            'latitude': position.latitude,
            'longitude': position.longitude,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          };

          // Add to queue
          List<String> queue = prefs.getStringList(queueKey) ?? [];
          queue.add(jsonEncode(newLocation));
          await prefs.setStringList(queueKey, queue);

          // Try to flush queue
          if (queue.isNotEmpty) {
            final List<Map<String, dynamic>> batch = queue
                .map((e) => jsonDecode(e) as Map<String, dynamic>)
                .toList();

            print('Attempting to send ${batch.length} locations...');
            final success = await apiService.sendLocations(batch);

            if (success) {
              print('Successfully sent batch.');
              await prefs.setStringList(queueKey, []);
            } else {
              print('Failed to send. Keeping in queue.');
            }
          }

        } catch (e) {
          print('Error in tracking loop: $e');
        }
      } else {
        // Session expired
        print('Session expired. Stopping service.');
        service.stopSelf();
        await prefs.remove('current_session_id');
        await prefs.remove('session_end_time');
      }
    } else {
       // No active session, stop service
       service.stopSelf();
    }
  });
}
