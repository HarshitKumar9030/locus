import 'dart:io';
import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:disable_battery_optimization/disable_battery_optimization.dart';

const String _batteryOptPromptShownKey = 'battery_opt_prompt_shown';
const String _autostartPromptShownKey = 'autostart_prompt_shown';

/// Service to handle battery optimization settings for aggressive OEMs like Xiaomi, Huawei, etc.
class BatteryOptimizationService {
  /// Check if device manufacturer is known to aggressively kill background apps
  static Future<bool> isAggressiveOEM() async {
    if (!Platform.isAndroid) return false;

    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final manufacturer = androidInfo.manufacturer.toLowerCase();

    // Known aggressive OEMs that kill background apps
    const aggressiveOEMs = [
      'xiaomi',
      'redmi',
      'poco',
      'miui',
      'huawei',
      'honor',
      'oppo',
      'vivo',
      'realme',
      'oneplus',
      'samsung', // Some Samsung devices are aggressive too
      'meizu',
      'asus',
      'nokia', // HMD Nokia with aggressive battery saving
      'tecno',
      'infinix',
      'itel',
    ];

    return aggressiveOEMs.any((oem) => manufacturer.contains(oem));
  }

  /// Check if battery optimization is disabled for this app
  static Future<bool> isBatteryOptimizationDisabled() async {
    if (!Platform.isAndroid) return true;
    return await DisableBatteryOptimization.isBatteryOptimizationDisabled ??
        false;
  }

  /// Check if auto start is enabled
  static Future<bool> isAutoStartEnabled() async {
    if (!Platform.isAndroid) return true;
    return await DisableBatteryOptimization.isAutoStartEnabled ?? false;
  }

  /// Request to disable battery optimization (shows system dialog)
  static Future<bool> requestDisableBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    return await DisableBatteryOptimization.showDisableBatteryOptimizationSettings() ??
        false;
  }

  /// Show manufacturer-specific auto-start settings (for Xiaomi, Huawei, etc.)
  static Future<bool> showAutoStartSettings() async {
    if (!Platform.isAndroid) return true;
    return await DisableBatteryOptimization.showEnableAutoStartSettings(
          "Enable Auto Start",
          "For reliable background tracking, please enable Auto Start for this app.",
        ) ??
        false;
  }

  /// Show all manufacturer-specific battery optimization settings
  static Future<void> showManufacturerBatterySettings() async {
    if (!Platform.isAndroid) return;
    await DisableBatteryOptimization.showDisableManufacturerBatteryOptimizationSettings(
      "Disable Battery Optimization",
      "Your device may restrict background apps. Please disable battery optimization for reliable tracking.",
    );
  }

  /// Check if we've already shown the battery optimization prompt
  static Future<bool> hasShownBatteryOptPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_batteryOptPromptShownKey) ?? false;
  }

  /// Mark battery optimization prompt as shown
  static Future<void> markBatteryOptPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_batteryOptPromptShownKey, true);
  }

  /// Check if we've already shown the autostart prompt
  static Future<bool> hasShownAutostartPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autostartPromptShownKey) ?? false;
  }

  /// Mark autostart prompt as shown
  static Future<void> markAutostartPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autostartPromptShownKey, true);
  }

  /// Show a comprehensive dialog to guide user through all necessary settings
  static Future<void> showBatteryOptimizationDialog(
    BuildContext context,
  ) async {
    final isAggressive = await isAggressiveOEM();
    final isBatteryOptDisabled = await isBatteryOptimizationDisabled();
    final isAutoStartOn = await isAutoStartEnabled();

    // If everything is already configured, no need to show dialog
    if (isBatteryOptDisabled && (isAutoStartOn || !isAggressive)) {
      return;
    }

    if (!context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF18181B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF3F3F46)),
        ),
        title: const Row(
          children: [
            Icon(Icons.battery_alert, color: Color(0xFFEF4444), size: 24),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Important: Battery Settings',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'For reliable background tracking, you need to configure battery settings:',
                style: TextStyle(color: Color(0xFFA1A1AA), fontSize: 14),
              ),
              const SizedBox(height: 16),
              if (!isBatteryOptDisabled) ...[
                _buildSettingTile(
                  icon: Icons.battery_saver,
                  title: '1. Disable Battery Optimization',
                  subtitle: 'Prevents system from killing the app',
                  isConfigured: false,
                ),
                const SizedBox(height: 12),
              ],
              if (isAggressive && !isAutoStartOn) ...[
                _buildSettingTile(
                  icon: Icons.play_circle_outline,
                  title:
                      '${!isBatteryOptDisabled ? "2" : "1"}. Enable Auto Start',
                  subtitle: 'Required for ${_getManufacturerName()} devices',
                  isConfigured: false,
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF422006),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFFBBF24).withOpacity(0.3),
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.warning_amber,
                      color: Color(0xFFFBBF24),
                      size: 20,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Without these settings, tracking may stop when screen is off.',
                        style: TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              markBatteryOptPromptShown();
            },
            child: const Text(
              'Later',
              style: TextStyle(color: Color(0xFF71717A)),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();

              // Step 1: Disable battery optimization
              if (!isBatteryOptDisabled) {
                await requestDisableBatteryOptimization();
              }

              // Step 2: Show auto-start settings for aggressive OEMs
              if (isAggressive && !isAutoStartOn) {
                await Future.delayed(const Duration(milliseconds: 500));
                await showAutoStartSettings();
              }

              await markBatteryOptPromptShown();
              await markAutostartPromptShown();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF10B981),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text('Configure Now'),
          ),
        ],
      ),
    );
  }

  static Widget _buildSettingTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isConfigured,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF27272A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isConfigured
              ? const Color(0xFF10B981)
              : const Color(0xFF3F3F46),
        ),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: isConfigured
                ? const Color(0xFF10B981)
                : const Color(0xFFA1A1AA),
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF71717A),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            isConfigured ? Icons.check_circle : Icons.arrow_forward_ios,
            color: isConfigured
                ? const Color(0xFF10B981)
                : const Color(0xFF71717A),
            size: 16,
          ),
        ],
      ),
    );
  }

  static Future<String> _getManufacturerName() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    final manufacturer = androidInfo.manufacturer;
    // Capitalize first letter
    if (manufacturer.isEmpty) return 'your';
    return manufacturer[0].toUpperCase() +
        manufacturer.substring(1).toLowerCase();
  }
}
