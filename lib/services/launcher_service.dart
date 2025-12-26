import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class LauncherService {
  Map<String, String> getLauncherPaths() {
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    final appData = Platform.environment['APPDATA'] ?? '';

    // Check for the specific CurseForge path provided by the user
    String cfPath = p.join(userProfile, 'curseforge', 'minecraft', 'Instances');
    if (!Directory(cfPath).existsSync()) {
      // Fallback to standard path
      cfPath = p.join(userProfile, 'Documents', 'CurseForge', 'Minecraft', 'Instances');
    }

    return {
      'curseforge': cfPath,
      'modrinth': p.join(appData, 'ModrinthApp', 'profiles'),
      'modrinth_alt': p.join(appData, 'com.modrinth.launcher', 'meta', 'instances'),
      'sklauncher': p.join(appData, '.minecraft', 'modpacks'),
      'sklauncher_alt': p.join(appData, '.sklauncher', 'instances'),
    };
  }

  List<String> scanInstances(String launcherPath) {
    if (launcherPath.isEmpty) return [];
    
    final dir = Directory(launcherPath);
    if (!dir.existsSync()) return [];

    try {
      return dir
          .listSync()
          .whereType<Directory>()
          .map((d) => p.basename(d.path))
          .toList();
    } catch (e) {
      print('Error scanning instances: $e');
      return [];
    }
  }

  Future<String> getLocalVersion(String instancePath) async {
    final file = File(p.join(instancePath, 'version.txt'));
    if (await file.exists()) {
      return (await file.readAsString()).trim();
    }
    return '0.0.0';
  }

  Future<void> setLocalVersion(String instancePath, String version) async {
    final file = File(p.join(instancePath, 'version.txt'));
    await file.writeAsString(version);
  }

  Future<String?> getFabricVersion(String instancePath) async {
    print("[LauncherService] Detecting Fabric version for: $instancePath");
    
    // 1. Check CurseForge minecraftinstance.json
    final cfPath = p.join(instancePath, 'minecraftinstance.json');
    if (await File(cfPath).exists()) {
      try {
        final data = json.decode(await File(cfPath).readAsString());
        if (data['baseModLoader'] != null) {
          final name = data['baseModLoader']['name'] as String;
          print("[LauncherService] Found in CF manifest: $name");
          if (name.startsWith('fabric-')) return name.replaceFirst('fabric-', '');
        }
      } catch (e) { print("[LauncherService] Error reading CF manifest: $e"); }
    }

    // 2. Check SKLauncher / Vanilla manifest.json
    final skPath = p.join(instancePath, 'manifest.json');
    if (await File(skPath).exists()) {
      try {
        final data = json.decode(await File(skPath).readAsString());
        // Handle flat format: {"fabric": "0.16.10"}
        if (data['fabric'] != null) {
          final v = data['fabric'].toString();
          print("[LauncherService] Found flat fabric in manifest: $v");
          return v;
        }
        // Handle nested format
        if (data['minecraft'] != null && data['minecraft']['modLoaders'] != null) {
          final loaders = data['minecraft']['modLoaders'] as List;
          for (var loader in loaders) {
            final id = loader['id'] as String;
            print("[LauncherService] Found in SK manifest: $id");
            if (id.startsWith('fabric-')) return id.replaceFirst('fabric-', '');
          }
        }
      } catch (e) { print("[LauncherService] Error reading SK manifest: $e"); }
    }

    // 3. Fallback to reading launcher_profiles.json if available
    try {
      final appData = Platform.environment['APPDATA'] ?? '';
      final profilesPath = p.join(appData, '.minecraft', 'launcher_profiles.json');
      if (await File(profilesPath).exists()) {
        final data = json.decode(await File(profilesPath).readAsString());
        if (data['profiles'] != null) {
          final profiles = data['profiles'] as Map<String, dynamic>;
          final normalizedInstance = p.canonicalize(instancePath).toLowerCase();
          for (var profile in profiles.values) {
            if (profile['gameDir'] != null) {
              final normalizedDir = p.canonicalize(profile['gameDir']).toLowerCase();
              if (normalizedDir == normalizedInstance && profile['lastVersionId'] != null) {
                final vid = profile['lastVersionId'] as String;
                print("[LauncherService] Found in profiles.json: $vid");
                // Match patterns like 'fabric-loader-0.16.10-1.21.1' or 'fabric-0.16.10'
                final match = RegExp(r'fabric(?:-loader)?-([0-9.]+)').firstMatch(vid);
                if (match != null) return match.group(1);
              }
            }
          }
        }
      }
    } catch (e) { print("[LauncherService] Error reading profiles.json: $e"); }

    print("[LauncherService] No Fabric version detected");
    return null;
  }

  Future<void> initializeInstance(String path, String version, String fabricVersion, {String? displayName, String? launcherKey}) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }

    // Create version.txt
    await File(p.join(path, 'version.txt')).writeAsString(version);

    // Create a basic manifest for the launcher to recognize it
    if (launcherKey == 'curseforge') {
      final cfManifest = {
        "minecraft": {
          "version": "1.21.1",
          "modLoaders": [
            {"id": "fabric-$fabricVersion", "primary": true}
          ]
        },
        "manifestType": "minecraftModpack",
        "manifestVersion": 1,
        "name": displayName ?? p.basename(path),
        "version": version,
        "author": "Manfredonia Updater",
        "files": [],
        "overrides": "overrides"
      };
      await File(p.join(path, 'manifest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(cfManifest));
      await _createCurseForgeMetadata(path, displayName ?? p.basename(path), fabricVersion, cfManifest);
    } else {
      // General manifest for other launchers (SK, etc)
      final manifest = {
        "fabric": fabricVersion,
        "minecraft": "1.21.1"
      };
      await File(p.join(path, 'manifest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    }
    
    print("[LauncherService] Initialized new instance folder at $path");

    // Register in launcher_profiles.json if SKLauncher/Vanilla
    if (launcherKey == 'sklauncher' || launcherKey == 'sklauncher_alt') {
      await _registerSkProfile(path, displayName ?? p.basename(path), fabricVersion);
    }
  }

  Future<void> _createCurseForgeMetadata(String instancePath, String name, String fabricVersion, Map<String, dynamic> manifest) async {
    try {
      // Create mandatory folders for CurseForge
      for (var f in ['mods', 'config', 'overrides', 'resourcepacks', 'saves', 'screenshots', 'blueprints']) {
        final d = Directory(p.join(instancePath, f));
        if (!d.existsSync()) await d.create(recursive: true);
      }

      // Create a dummy modlist.html (sometimes required)
      final modlistFile = File(p.join(instancePath, 'modlist.html'));
      if (!await modlistFile.exists()) {
        await modlistFile.writeAsString("<ul><li>Manfredonia Pack Mods</li></ul>");
      }

      final cfFile = File(p.join(instancePath, 'minecraftinstance.json'));
      final now = DateTime.now().toUtc().toIso8601String();
      final guid = _generateGuid();
      
      // Ensure path ends with trailing backslash for CurseForge
      String formattedPath = instancePath;
      if (!formattedPath.endsWith('\\')) formattedPath += '\\';

      final metadata = {
        "baseModLoader": {
          "name": "fabric-$fabricVersion",
          "type": 4
        },
        "isCustom": true,
        "isUnlocked": true,
        "guid": guid,
        "name": name,
        "gameVersion": "1.21.1",
        "installPath": formattedPath,
        "jsonVersion": 1,
        "manifest": manifest,
        "installedAddons": [],
        "overrides": "overrides",
        "lastPlayed": "0001-01-01T00:00:00Z",
        "playedCount": 0,
        "wasNameManuallyChanged": false,
        "installDate": now,
        "dateCreated": now,
        "dateModified": now,
        "gameVersionTypeId": 68441,
        "projectID": 0,
        "fileID": 0,
        "modpackId": 0,
        "isStatic": false,
        "isEnabled": true,
        "isValid": true,
        "gameTypeID": 432
      };
      
      await cfFile.writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
      print("[LauncherService] Created validated CurseForge metadata with GUID $guid for '$name'");
    } catch (e) {
      print("[LauncherService] Error creating CurseForge metadata: $e");
    }
  }

  String _generateGuid() {
    final r = DateTime.now().microsecondsSinceEpoch;
    final r2 = DateTime.now().millisecondsSinceEpoch;
    // Standard-compliant hex UUID format (8-4-4-4-12)
    final hex = r.toRadixString(16).padLeft(12, '0');
    final hex2 = r2.toRadixString(16).padLeft(8, '0');
    return "${hex2.substring(0,8)}-${hex.substring(0,4)}-4000-8000-${hex.substring(0,12)}";
  }

  Future<void> _registerSkProfile(String gameDir, String name, String fabricVersion) async {
    try {
      final appData = Platform.environment['APPDATA'] ?? '';
      final profilesPath = p.join(appData, '.minecraft', 'launcher_profiles.json');
      final file = File(profilesPath);
      
      if (!await file.exists()) {
        print("[LauncherService] launcher_profiles.json not found, skipping registration");
        return;
      }

      final data = json.decode(await file.readAsString());
      if (data['profiles'] == null) data['profiles'] = {};
      
      final profiles = data['profiles'] as Map<String, dynamic>;
      final profileId = _generateId();
      
      final newProfile = {
        "name": name,
        "gameDir": gameDir,
        "lastVersionId": "fabric-loader-$fabricVersion-1.21.1",
        "type": "custom",
        "created": DateTime.now().toIso8601String(),
        "lastUsed": DateTime.now().toIso8601String(),
        "icon": "Grass"
      };

      profiles[profileId] = newProfile;
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      print("[LauncherService] Registered new profile '$name' in launcher_profiles.json");
    } catch (e) {
      print("[LauncherService] Error registering profile: $e");
    }
  }

  String _generateId() {
    final random = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return "manfredonia_$random";
  }
}
