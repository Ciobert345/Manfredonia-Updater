import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  Future<void> init() async {
    await localNotifier.setup(
      appName: 'Manfredonia Manager',
    );
  }

  Future<void> showUpdateNotification(String version) async {
    final notification = LocalNotification(
      title: "Aggiornamento disponibile",
      body: "Nuova versione v$version per il Manfredonia Pack.",
      actions: [
        LocalNotificationAction(text: "Apri Manager"),
      ],
    );

    notification.onClick = () {
      _showWindow();
    };

    await notification.show();
  }

  Future<void> showUpToDateNotification() async {
    final notification = LocalNotification(
      title: "Manfredonia Manager",
      body: "Il Mod Pack è già aggiornato all'ultima versione.",
    );

    notification.onClick = () {
      _showWindow();
    };

    await notification.show();
  }

  Future<void> _showWindow() async {
    if (!await windowManager.isVisible()) {
      await windowManager.show();
    }
    await windowManager.focus();
  }
}
