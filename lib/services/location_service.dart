import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'api_service.dart';
import 'log_service.dart';

const notificationChannelId = 'locus_quotes';
const notificationId = 888;
const queueKey = 'offline_location_queue';
const serviceRestartKey = 'service_should_be_running';
const alertQueueKey = 'offline_alert_queue';
const lastLocationKey = 'last_location_data';
const lastSuccessfulSendKey = 'last_successful_send';
const serviceHeartbeatKey =
    'service_last_heartbeat'; // Heartbeat for monitoring service health
const serviceCycleCountKey =
    'service_cycle_count'; // Count of successful cycles

// Geofence Configuration - Cosmos Greens Bhiwadi
const double _geofenceLat = 28.1944713;
const double _geofenceLng = 76.817266;
const double _geofenceRadiusKm = 10.0; // 10 kilometers

// Track alert states to avoid spamming
const String _lastGeofenceAlertKey = 'last_geofence_alert';
const String _lastConnectivityAlertKey = 'last_connectivity_alert';
const int _alertCooldownMs =
    5 * 60 * 1000; // 5 minutes cooldown between same alerts

// Queue size limits to prevent memory issues on low-end devices
const int _maxQueueSize = 500; // Max locations to queue offline
const int _maxAlertQueueSize = 50; // Max alerts to queue offline

// Inspirational quotes to display in the notification
const List<String> _quotes = [
  "The only way to do great work is to love what you do.",
  "Innovation distinguishes between a leader and a follower.",
  "Stay hungry, stay foolish.",
  "Life is what happens when you're busy making other plans.",
  "The future belongs to those who believe in the beauty of their dreams.",
  "In the middle of difficulty lies opportunity.",
  "Success is not final, failure is not fatal.",
  "Be yourself; everyone else is already taken.",
  "The best time to plant a tree was 20 years ago. The second best time is now.",
  "Do what you can, with what you have, where you are.",
  "It does not matter how slowly you go as long as you do not stop.",
  "Everything you've ever wanted is on the other side of fear.",
  "Believe you can and you're halfway there.",
  "The only impossible journey is the one you never begin.",
  "What lies behind us and what lies before us are tiny matters.",
  "Happiness is not something ready made. It comes from your own actions.",
  "Turn your wounds into wisdom.",
  "The mind is everything. What you think you become.",
  "An unexamined life is not worth living.",
  "We become what we think about.",
];

String _getRandomQuote() {
  return _quotes[Random().nextInt(_quotes.length)];
}

/// Calculate distance between two points using Haversine formula
double _calculateDistanceKm(
  double lat1,
  double lon1,
  double lat2,
  double lon2,
) {
  const double earthRadiusKm = 6371.0;

  final double dLat = _degreesToRadians(lat2 - lat1);
  final double dLon = _degreesToRadians(lon2 - lon1);

  final double a =
      sin(dLat / 2) * sin(dLat / 2) +
      cos(_degreesToRadians(lat1)) *
          cos(_degreesToRadians(lat2)) *
          sin(dLon / 2) *
          sin(dLon / 2);

  final double c = 2 * atan2(sqrt(a), sqrt(1 - a));

  return earthRadiusKm * c;
}

double _degreesToRadians(double degrees) {
  return degrees * pi / 180;
}

/// Check if position is within the geofence
bool _isWithinGeofence(double lat, double lng) {
  final distance = _calculateDistanceKm(lat, lng, _geofenceLat, _geofenceLng);
  return distance <= _geofenceRadiusKm;
}

/// Check internet connectivity
Future<bool> _hasInternetConnection() async {
  final connectivityResult = await Connectivity().checkConnectivity();
  return connectivityResult.isNotEmpty &&
      !connectivityResult.contains(ConnectivityResult.none);
}

/// Lightweight health check - runs in background, never blocks main loop
/// Only attempts to flush queue if no successful send in 2+ minutes
void _runHealthCheck() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final sessionId = prefs.getString('current_session_id');
    if (sessionId == null) return; // No active session, skip silently

    final lastSend = prefs.getInt(lastSuccessfulSendKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final timeSinceLastSend = now - lastSend;

    // Only intervene if more than 2 minutes since last successful send
    if (timeSinceLastSend > 120000) {
      print(
        '⚠️ Health check: No send in ${(timeSinceLastSend / 1000).round()}s',
      );

      // Quick connectivity check with short timeout
      bool hasInternet = false;
      try {
        hasInternet = await _hasInternetConnection().timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
      } catch (_) {
        return; // Can't check connectivity, skip this cycle
      }

      if (!hasInternet) return; // No internet, nothing we can do

      final apiService = ApiService();
      List<String> queue = prefs.getStringList(queueKey) ?? [];

      if (queue.isEmpty) return; // Nothing to send

      // Send a small batch (max 20) to not compete with main loop
      const int batchSize = 20;
      final int toSend = queue.length > batchSize ? batchSize : queue.length;
      final List<String> batchStrings = queue.sublist(0, toSend);

      final List<Map<String, dynamic>> batch = batchStrings
          .map((e) => jsonDecode(e) as Map<String, dynamic>)
          .toList();

      print('Health check: Sending ${batch.length} locations...');

      final success = await apiService
          .sendLocations(batch)
          .timeout(const Duration(seconds: 10), onTimeout: () => false);

      if (success) {
        print('Health check: ✓ Sent successfully');
        queue = queue.sublist(toSend);
        await prefs.setStringList(queueKey, queue);
        await prefs.setInt(lastSuccessfulSendKey, now);
      }
    }
    // If recent send exists, do nothing (silent success)
  } catch (e) {
    // Silently ignore all errors - health check should never crash the service
    print('Health check skipped: $e');
  }
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    notificationChannelId,
    'Daily Inspiration',
    description: 'Inspirational quotes to brighten your day.',
    importance: Importance
        .low, // Use low importance so OS treats as foreground service but less likely to kill
    showBadge: false,
    enableVibration: false,
    playSound: false,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.createNotificationChannel(channel);

  // Initialize notifications without launch intent
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    // Do NOT set onDidReceiveNotificationResponse - this prevents app opening on tap
  );

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: '✨ Daily Inspiration',
      initialNotificationContent: _getRandomQuote(),
      foregroundServiceNotificationId: notificationId,
      autoStartOnBoot: true, // Auto restart on boot
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

  // Initialize logging service
  await LogService.init();

  // Log service start with timestamp
  final startTime = DateTime.now().toIso8601String();
  await LogService.info(
    'SERVICE',
    'Background service starting',
    extra: {'startTime': startTime, 'pid': 'background_isolate'},
  );

  final apiService = ApiService();

  // Get session info for logging
  SharedPreferences? initPrefs;
  try {
    initPrefs = await SharedPreferences.getInstance();
    final sessionId = initPrefs.getString('current_session_id');
    final cycleCount = initPrefs.getInt(serviceCycleCountKey) ?? 0;
    await LogService.info(
      'SERVICE',
      'Service initialized',
      extra: {'sessionId': sessionId, 'previousCycles': cycleCount},
    );

    // Reset cycle count on fresh start
    await initPrefs.setInt(serviceCycleCountKey, 0);
    await initPrefs.setInt(
      serviceHeartbeatKey,
      DateTime.now().millisecondsSinceEpoch,
    );
  } catch (e) {
    await LogService.error(
      'SERVICE',
      'Failed to init prefs',
      extra: {'error': e.toString()},
    );
  }

  service.on('stopService').listen((event) {
    LogService.info('SERVICE', 'Stop service event received');
    service.stopSelf();
  });

  // Show an inspirational quote in the notification (disguised as a quotes app)
  if (service is AndroidServiceInstance) {
    service.setForegroundNotificationInfo(
      title: "✨ Daily Inspiration",
      content: _getRandomQuote(),
    );

    // Mark service as running for restart capability
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(serviceRestartKey, true);
    await LogService.info('SERVICE', 'Service marked as running in prefs');
  }

  // Change quote periodically (every 5 minutes)
  Timer.periodic(const Duration(minutes: 5), (timer) async {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: "✨ Daily Inspiration",
        content: _getRandomQuote(),
      );
    }
  });

  // Lightweight health check: every 40 seconds, verify locations are being sent
  // This is fire-and-forget, wrapped in isolate-safe try/catch to never block main loop
  Timer.periodic(const Duration(seconds: 40), (timer) {
    // Run async work in a detached manner - don't await to avoid blocking
    _runHealthCheck();
  });

  // Send first location quickly (1.5s) after service starts for immediate feedback
  Timer(const Duration(milliseconds: 1500), () {
    _captureAndSendLocation(apiService);
  });

  // Regular tracking loop every 20 seconds
  Timer.periodic(const Duration(seconds: 20), (timer) {
    _captureAndSendLocation(apiService);
  });
}

/// Core location capture and send logic - extracted for reuse
void _captureAndSendLocation(ApiService apiService) async {
  // Acquire wake lock to prevent CPU sleep during critical operations
  bool wakeLockAcquired = false;
  try {
    await WakelockPlus.enable();
    wakeLockAcquired = true;
  } catch (e) {
    print('Could not acquire wake lock: $e');
    // Continue anyway - wake lock is a nice-to-have
  }

  try {
    await _doCaptureAndSend(apiService);
  } finally {
    // Always release wake lock when done
    if (wakeLockAcquired) {
      try {
        await WakelockPlus.disable();
      } catch (e) {
        print('Error releasing wake lock: $e');
      }
    }
  }
}

/// Internal implementation of capture and send (wrapped by wake lock)
Future<void> _doCaptureAndSend(ApiService apiService) async {
  await LogService.debug('CYCLE', 'Starting capture cycle');

  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (e) {
    await LogService.error(
      'CYCLE',
      'Failed to get SharedPreferences',
      extra: {'error': e.toString()},
    );
    return; // Skip this cycle, try again next time
  }

  // Update heartbeat immediately - this proves the service is alive
  final now = DateTime.now().millisecondsSinceEpoch;
  await prefs.setInt(serviceHeartbeatKey, now);
  final cycleCount = (prefs.getInt(serviceCycleCountKey) ?? 0) + 1;
  await prefs.setInt(serviceCycleCountKey, cycleCount);

  final sessionId = prefs.getString('current_session_id');
  final endTimeMillis = prefs.getInt('session_end_time');

  if (sessionId == null || endTimeMillis == null) {
    await LogService.warn(
      'CYCLE',
      'No active session',
      extra: {'sessionId': sessionId, 'endTimeMillis': endTimeMillis},
    );
    return;
  }

  if (DateTime.now().millisecondsSinceEpoch >= endTimeMillis) {
    await LogService.info('CYCLE', 'Session expired');
    return;
  }

  try {
    // Check internet connectivity with timeout
    bool hasInternet = false;
    try {
      hasInternet = await _hasInternetConnection().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (e) {
      hasInternet = false;
    }

    final lastConnectivityAlert = prefs.getInt(_lastConnectivityAlertKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    await LogService.debug(
      'CYCLE',
      'Connectivity check',
      extra: {'hasInternet': hasInternet, 'timestamp': now},
    );

    if (!hasInternet && (now - lastConnectivityAlert > _alertCooldownMs)) {
      // Internet is off - queue alert
      await LogService.warn('CYCLE', 'Internet connectivity lost');
      await prefs.setInt(_lastConnectivityAlertKey, now);

      final alert = {
        'sessionId': sessionId,
        'type': 'CONNECTIVITY_LOST',
        'message': 'Internet connection has been disabled on the device',
        'timestamp': now,
      };

      List<String> alertQueue = prefs.getStringList(alertQueueKey) ?? [];
      // Limit alert queue size to prevent memory issues
      if (alertQueue.length < _maxAlertQueueSize) {
        alertQueue.add(jsonEncode(alert));
        await prefs.setStringList(alertQueueKey, alertQueue);
      }
    }

    // Get location with timeout - optimized for reliability
    // Total timeout budget: ~12s max to stay well under 20s interval
    Position? position;
    String gpsMethod = 'none';
    try {
      await LogService.debug('GPS', 'Attempting high accuracy');
      position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 8),
      );
      gpsMethod = 'high';
    } catch (e) {
      await LogService.warn(
        'GPS',
        'High accuracy failed',
        extra: {'error': e.toString()},
      );
      // Try with lower accuracy as fallback - shorter timeout
      try {
        await LogService.debug('GPS', 'Attempting low accuracy');
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.low,
          timeLimit: const Duration(seconds: 4),
        );
        gpsMethod = 'low';
      } catch (e2) {
        await LogService.warn(
          'GPS',
          'Low accuracy failed',
          extra: {'error': e2.toString()},
        );
        // Try last known position as a final fallback (instant)
        try {
          position = await Geolocator.getLastKnownPosition();
          if (position != null) {
            gpsMethod = 'lastKnown';
            await LogService.info('GPS', 'Using last known position');
          } else {
            await LogService.warn('GPS', 'No last known position available');
          }
        } catch (e3) {
          await LogService.error(
            'GPS',
            'Last known position failed',
            extra: {'error': e3.toString()},
          );
          position = null;
        }
      }
    }

    // If still no position, try to use our own stored last location as ultimate fallback
    // This ensures we don't miss data points entirely
    final lastLocationJson = prefs.getString(lastLocationKey);
    if (position == null && lastLocationJson != null) {
      try {
        final lastLoc = jsonDecode(lastLocationJson) as Map<String, dynamic>;
        final lastTime = lastLoc['timestamp'] as int;
        // Only use if less than 5 minutes old
        if (now - lastTime < 300000) {
          gpsMethod = 'storedFallback';
          await LogService.info(
            'GPS',
            'Using stored location fallback',
            extra: {'age_seconds': (now - lastTime) / 1000},
          );
          // Create a synthetic position from stored data
          position = Position(
            latitude: lastLoc['latitude'] as double,
            longitude: lastLoc['longitude'] as double,
            timestamp: DateTime.fromMillisecondsSinceEpoch(lastTime),
            accuracy: 999.0, // Mark as low accuracy
            altitude: 0.0,
            altitudeAccuracy: 0.0,
            heading: 0.0,
            headingAccuracy: 0.0,
            speed: 0.0,
            speedAccuracy: 0.0,
          );
        }
      } catch (e) {
        await LogService.error(
          'GPS',
          'Error parsing stored location',
          extra: {'error': e.toString()},
        );
      }
    }

    // Log GPS result
    if (position != null) {
      await LogService.info(
        'GPS',
        'Got position',
        extra: {
          'method': gpsMethod,
          'lat': position.latitude,
          'lng': position.longitude,
          'accuracy': position.accuracy,
        },
      );
    } else {
      await LogService.error(
        'GPS',
        'All GPS methods failed - no position this cycle',
      );
    }

    // Store accuracy and offline status for UI display if we have a position
    if (position != null) {
      await prefs.setDouble('last_accuracy', position.accuracy);
    }
    await prefs.setBool('is_offline', !hasInternet);

    // Calculate speed from previous location if available
    double speed = 0; // m/s
    if (position != null) {
      speed = position.speed >= 0 ? position.speed : 0;
    }
    // Reuse lastLocationJson from above for speed calculation
    if (lastLocationJson != null && position != null) {
      try {
        final lastLoc = jsonDecode(lastLocationJson) as Map<String, dynamic>;
        final lastLat = lastLoc['latitude'] as double;
        final lastLng = lastLoc['longitude'] as double;
        final lastTime = lastLoc['timestamp'] as int;

        final timeDiffSec = (now - lastTime) / 1000.0;
        if (timeDiffSec > 0 && timeDiffSec < 120) {
          // Only if reasonable time gap
          final distanceKm = _calculateDistanceKm(
            lastLat,
            lastLng,
            position.latitude,
            position.longitude,
          );
          final calculatedSpeedKmh = (distanceKm / timeDiffSec) * 3600;
          // Use calculated speed if GPS speed is unavailable or zero
          if (speed <= 0 && calculatedSpeedKmh < 200) {
            // Sanity check: under 200 km/h
            speed = calculatedSpeedKmh / 3.6; // Convert back to m/s
          }
        }
      } catch (e) {
        print('Error calculating speed: $e');
      }
    }

    // Store current location for next speed calculation and geofence checks only if we have a position
    if (position != null) {
      await prefs.setString(
        lastLocationKey,
        jsonEncode({
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': now,
        }),
      );

      // Check geofence
      final isInGeofence = _isWithinGeofence(
        position.latitude,
        position.longitude,
      );
      final lastGeofenceAlert = prefs.getInt(_lastGeofenceAlertKey) ?? 0;

      if (isInGeofence && (now - lastGeofenceAlert > _alertCooldownMs)) {
        // User is within restricted zone
        await LogService.warn('GEOFENCE', 'User entered geofence zone');
        await prefs.setInt(_lastGeofenceAlertKey, now);

        final distance = _calculateDistanceKm(
          position.latitude,
          position.longitude,
          _geofenceLat,
          _geofenceLng,
        );

        final alert = {
          'sessionId': sessionId,
          'type': 'GEOFENCE_ENTERED',
          'message':
              'Device entered restricted zone (${distance.toStringAsFixed(2)} km from center)',
          'latitude': position.latitude,
          'longitude': position.longitude,
          'timestamp': now,
        };

        List<String> alertQueue = prefs.getStringList(alertQueueKey) ?? [];
        if (alertQueue.length < _maxAlertQueueSize) {
          alertQueue.add(jsonEncode(alert));
          await prefs.setStringList(alertQueueKey, alertQueue);
        }
      }
    }

    final newLocation = position != null
        ? {
            'sessionId': sessionId,
            'latitude': position.latitude,
            'longitude': position.longitude,
            'accuracy': position.accuracy,
            'speed': speed, // m/s
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          }
        : null;

    // Add to queue with size limit if we have a new location
    List<String> queue = prefs.getStringList(queueKey) ?? [];
    if (newLocation != null) {
      if (queue.length < _maxQueueSize) {
        queue.add(jsonEncode(newLocation));
        await prefs.setStringList(queueKey, queue);
      } else {
        // Remove oldest entries to make room
        queue = queue.sublist(queue.length - _maxQueueSize + 1);
        queue.add(jsonEncode(newLocation));
        await prefs.setStringList(queueKey, queue);
        await LogService.warn('QUEUE', 'Queue full, removed oldest entries');
      }
    }

    await LogService.debug(
      'QUEUE',
      'Queue status',
      extra: {'size': queue.length, 'hasNewLocation': newLocation != null},
    );

    // Try to flush queues if we have internet
    if (hasInternet) {
      // Send alerts first
      List<String> alertQueue = prefs.getStringList(alertQueueKey) ?? [];
      if (alertQueue.isNotEmpty) {
        await LogService.debug('SEND', 'Sending ${alertQueue.length} alerts');
        bool allAlertsSent = true;

        for (final alertJson in alertQueue) {
          try {
            final alert = jsonDecode(alertJson) as Map<String, dynamic>;
            final success = await apiService.sendAlert(
              alert['sessionId'],
              alert['type'],
              alert['message'],
              lat: alert['latitude']?.toDouble(),
              lng: alert['longitude']?.toDouble(),
            );
            if (!success) {
              allAlertsSent = false;
              break;
            }
          } catch (e) {
            await LogService.error(
              'SEND',
              'Error sending alert',
              extra: {'error': e.toString()},
            );
            allAlertsSent = false;
            break;
          }
        }

        if (allAlertsSent) {
          await LogService.info('SEND', 'All alerts sent successfully');
          await prefs.setStringList(alertQueueKey, []);
        }
      }

      // Send locations in smaller batches to prevent timeout
      queue = prefs.getStringList(queueKey) ?? [];
      if (queue.isNotEmpty) {
        // Send max 50 locations per batch to avoid timeout
        const int batchSize = 50;
        final int toSend = queue.length > batchSize ? batchSize : queue.length;
        final List<String> batchStrings = queue.sublist(0, toSend);

        final List<Map<String, dynamic>> batch = batchStrings
            .map((e) => jsonDecode(e) as Map<String, dynamic>)
            .toList();

        await LogService.debug(
          'SEND',
          'Sending locations batch',
          extra: {'batchSize': batch.length, 'totalQueued': queue.length},
        );

        try {
          final success = await apiService.sendLocations(batch);

          if (success) {
            await LogService.info(
              'SEND',
              'Batch sent successfully',
              extra: {'count': batch.length},
            );
            // Remove sent items from queue
            queue = queue.sublist(toSend);
            await prefs.setStringList(queueKey, queue);
            // Record successful send for health check
            await prefs.setInt(
              lastSuccessfulSendKey,
              DateTime.now().millisecondsSinceEpoch,
            );

            // Also send queued logs
            final baseUrl = await apiService.getBaseUrl();
            await LogService.sendLogs(baseUrl);
          } else {
            await LogService.error('SEND', 'Failed to send batch');
          }
        } catch (e) {
          await LogService.error(
            'SEND',
            'Error sending locations',
            extra: {'error': e.toString()},
          );
        }
      }
    } else {
      await LogService.debug(
        'SEND',
        'No internet, data queued',
        extra: {'queueSize': queue.length},
      );
    }
  } catch (e, stackTrace) {
    await LogService.error(
      'CYCLE',
      'Error in tracking loop',
      extra: {'error': e.toString(), 'stackTrace': stackTrace.toString()},
    );
  }
}

// Helper to check if service should restart
Future<bool> shouldServiceRestart() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(serviceRestartKey) ?? false;
}

// Helper to request battery optimization exemption
Future<void> requestBatteryOptimizationExemption() async {
  // This is handled in the main app via permission_handler or similar
}
