import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'ui/dashboard_page.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  
  // Initialize persistence
  await SettingsService().init();
  
  // Initialize notifications
  await NotificationService().init();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(520, 760),
    center: true,
    title: 'Manfredonia Manager',
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setHasShadow(false);
    
    // Set icon
    await windowManager.setIcon('assets/app_logo_final.png');
    
    await windowManager.center();
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ManfredoniaApp());
}

class ManfredoniaApp extends StatelessWidget {
  const ManfredoniaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Manfredonia Manager',
      builder: (context, child) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Material(
            color: Colors.transparent,
            child: child!,
          ),
        );
      },
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
        fontFamily: 'Inter',
        useMaterial3: true,
        canvasColor: Colors.transparent,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const DashboardPage(),
    );
  }
}
