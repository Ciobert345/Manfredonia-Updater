import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SettingsService {
  static final SettingsService _instance = SettingsService._internal();
  factory SettingsService() => _instance;
  SettingsService._internal();

  String? lastLauncher;
  String? lastInstance;

  Future<void> init() async {
    await loadSettings();
  }

  Future<File> _getSettingsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, 'settings.json'));
  }

  Future<void> loadSettings() async {
    try {
      final file = await _getSettingsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final data = json.decode(content);
        lastLauncher = data['lastLauncher'];
        lastInstance = data['lastInstance'];
      }
    } catch (e) {
      print("[Settings] Error loading settings: $e");
    }
  }

  Future<void> saveSettings() async {
    try {
      final file = await _getSettingsFile();
      final data = {
        'lastLauncher': lastLauncher,
        'lastInstance': lastInstance,
      };
      await file.writeAsString(json.encode(data));
    } catch (e) {
      print("[Settings] Error saving settings: $e");
    }
  }
}
