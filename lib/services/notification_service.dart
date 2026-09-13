import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _hasPermission = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    const AndroidInitializationSettings androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    
    // Deliberately does NOT request permission here. main() awaits
    // initialize(), and asking at this point put a system alert in front of a
    // blank launch screen before the user had seen the app at all — and on
    // iOS startup blocked until they answered it. Permission is requested at
    // the moment a notification is actually needed, see [requestPermission].
    const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const InitializationSettings settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(settings: settings);
    _isInitialized = true;
    
    // Check if we already have permission
    await _checkPermission();
  }

  Future<void> _checkPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      _hasPermission = status.isGranted;
      return;
    }
    // iOS: not granted until asked. Leaving this optimistically true made
    // every just-in-time check below a no-op.
    _hasPermission = false;
  }

  /// Check if notification permission is granted
  Future<bool> hasPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.status;
      _hasPermission = status.isGranted;
    }
    return _hasPermission;
  }

  /// Request notification permission and return if granted.
  ///
  /// Called the first time a notification would actually be shown, and from
  /// the Settings toggle — never at startup.
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      _hasPermission = status.isGranted;
      return _hasPermission;
    }
    if (Platform.isIOS) {
      final granted = await _notifications
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      _hasPermission = granted ?? false;
      return _hasPermission;
    }
    return true;
  }

  Future<void> showNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_isInitialized) await initialize();
    
    // Check/request permission before showing notification
    if (!_hasPermission) {
      await requestPermission();
      if (!_hasPermission) return; // User denied permission
    }

    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'pdf_helper_channel',
      'PDF Helper',
      channelDescription: 'Notifications for PDF operations',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      color: Color(0xFFE94560),
      enableVibration: true,
      playSound: true,
    );

    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }

  // Convenience methods for specific operations
  Future<void> showMergeComplete(int pageCount) async {
    await showNotification(
      title: 'PDF Merged Successfully',
      body: '$pageCount pages merged into one PDF',
    );
  }

  Future<void> showSplitComplete(int pageCount) async {
    await showNotification(
      title: 'PDF Split Complete',
      body: '$pageCount page(s) extracted successfully',
    );
  }

  Future<void> showScanComplete(int pageCount) async {
    await showNotification(
      title: 'Scan Complete',
      body: '$pageCount page(s) converted to PDF',
    );
  }
}

