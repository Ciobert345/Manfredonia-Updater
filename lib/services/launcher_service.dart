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
    print("[LauncherService] Starting aggressive version detection for: $instancePath");
    
    // 1. Check for version.txt (Primary Source of truth for Modpack Version)
    final versionPaths = [
      p.join(instancePath, 'version.txt'),
      p.join(instancePath, 'overrides', 'version.txt'),
      p.join(instancePath, 'minecraft', 'version.txt'),
    ];

    for (final path in versionPaths) {
      final file = File(path);
      if (await file.exists()) {
        final v = (await file.readAsString()).trim();
        if (v.isNotEmpty) {
          print("[LauncherService] Found modpack version in $path: $v");
          return v;
        }
      }
    }

    // 2. Comprehensive manifest search (Fallback)
    final manifestLocations = [
      p.join(instancePath, 'manifest.json'),
      p.join(instancePath, 'overrides', 'manifest.json'),
      p.join(instancePath, 'minecraft', 'manifest.json'),
      p.join(instancePath, 'modrinth.index.json'),
      p.join(instancePath, 'overrides', 'modrinth.index.json'),
      p.join(instancePath, 'minecraft', 'modrinth.index.json'),
      p.join(instancePath, 'instance.json'),
      p.join(instancePath, 'pack.json'),
      p.join(instancePath, 'modpack.json'),
    ];

    for (final loc in manifestLocations) {
      final file = File(loc);
      if (await file.exists()) {
        final version = await _extractVersionFromFile(file);
        if (version != null) return version;
      }
    }

    // 3. Last ditch effort: search ANY JSON file in the root or top subfolders
    try {
      final rootDir = Directory(instancePath);
      if (await rootDir.exists()) {
        // Limited depth scan to avoid performance issues
        final List<FileSystemEntity> entities = [];
        entities.addAll(rootDir.listSync().whereType<File>());
        
        // Scan common subdirs
        for (var sub in ['overrides', 'minecraft', '.minecraft', 'config']) {
          final subDir = Directory(p.join(instancePath, sub));
          if (subDir.existsSync()) {
            entities.addAll(subDir.listSync().whereType<File>());
          }
        }

        for (final file in entities) {
          if (file is File && file.path.endsWith('.json')) {
            // Avoid re-checking standard ones
            if (manifestLocations.contains(file.path)) continue;
            
            final version = await _extractVersionFromFile(file);
            if (version != null) return version;
          }
        }
      }
    } catch (e) {
      print("[LauncherService] Error in exhaustive version search: $e");
    }

    print("[LauncherService] No version found for: $instancePath");
    return '0.0.0';
  }

  Future<String?> _extractVersionFromFile(File file) async {
    try {
      print("[LauncherService] Extracting version from: ${file.path}");
      final content = await file.readAsString();
      final data = json.decode(content);
      
      if (data is! Map) {
        print("[LauncherService] File content is not a Map: ${file.path}");
        return null;
      }

      // 1. Direct field match (most common)
      final directVersion = data['version'] ?? 
                          data['versionId'] ?? 
                          data['version_number'] ??
                          data['packVersion'] ??
                          data['version_name'] ??
                          data['version_id'] ??
                          data['metadata']?['version'];
      
      if (directVersion != null) {
        final vStr = directVersion.toString().trim();
        // If it looks like a Minecraft version (e.g. 1.21.1) but we are in a field 
        // that often confuses them, be careful. However, 'version' is usually modpack ver.
        print("[LauncherService] SUCCESS: Extracted direct version from ${file.path}: $vStr");
        return vStr;
      }
      
      // 2. Modrinth name pattern matching (e.g. "Pack v1.0.0")
      final name = data['name'] ?? data['title'];
      if (name != null) {
        final vStr = name.toString().trim();
        final match = RegExp(r'v?(\d+\.\d+\.\d+)').firstMatch(vStr);
        if (match != null) {
          print("[LauncherService] SUCCESS: Extracted version from name field in ${file.path}: ${match.group(0)}");
          return match.group(0);
        }
      }

      // 3. Nested search (sometimes it's in 'summary' or 'description')
      for (var key in ['minecraft', 'summary', 'description', 'metadata']) {
        if (data[key] is Map) {
          final sub = data[key] as Map;
          final v = sub['version'] ?? sub['versionId'];
          if (v != null) {
            print("[LauncherService] SUCCESS: Found version in nested $key of ${file.path}: $v");
            return v.toString().trim();
          }
        }
      }

      // 4. Exhaustive search: look for ANY string that looks like a version X.Y.Z
      // We check all values at depth 1
      for (var value in data.values) {
        if (value is String) {
          final s = value.trim();
          final match = RegExp(r'^v?(\d+\.\d+\.\d+)$').firstMatch(s);
          if (match != null) {
            // IGNORE typical Minecraft versions during exhaustive search 
            // to avoid picking up 'minecraft: 1.21.1' as the modpack version.
            if (s.contains('1.21') || s.contains('1.20') || s.contains('1.19')) {
              print("[LauncherService] Skipping likely MC version pattern in exhaustive search: $s");
              continue;
            }
            print("[LauncherService] SUCCESS: Found version pattern in unknown field in ${file.path}: $s");
            return s;
          }
        }
      }
      print("[LauncherService] No version pattern found in: ${file.path}");
    } catch (e) {
      print("[LauncherService] ERROR parsing ${file.path}: $e");
    }
    return null;
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
        // Standard CF format
        if (data['baseModLoader'] != null) {
          final name = data['baseModLoader']['name'] as String;
          return _extractFabricVersion(name);
        }
        // Alternative CF format
        if (data['minecraft'] != null && data['minecraft']['modLoaders'] != null) {
          final loaders = data['minecraft']['modLoaders'] as List;
          for (var loader in loaders) {
            final id = loader['id'] as String;
            final v = _extractFabricVersion(id);
            if (v != null) return v;
          }
        }
      } catch (e) { print("[LauncherService] Error reading CF manifest: $e"); }
    }

    // 2. Check SKLauncher / Vanilla manifest.json
    final skPath = p.join(instancePath, 'manifest.json');
    if (await File(skPath).exists()) {
      try {
        final data = json.decode(await File(skPath).readAsString());
        if (data['fabric'] != null) {
          return _extractFabricVersion(data['fabric'].toString());
        }
        if (data['minecraft'] != null && data['minecraft']['modLoaders'] != null) {
          final loaders = data['minecraft']['modLoaders'] as List;
          for (var loader in loaders) {
            final id = loader['id'] as String;
            final v = _extractFabricVersion(id);
            if (v != null) return v;
          }
        }
      } catch (e) { print("[LauncherService] Error reading SK manifest: $e"); }
    }

    // 3. Check instance.json (Modrinth/Prism/MultiMC)
    final instanceJsonPath = p.join(instancePath, 'instance.json');
    if (await File(instanceJsonPath).exists()) {
      try {
        final data = json.decode(await File(instanceJsonPath).readAsString());
        if (data['components'] != null && data['components'] is List) {
          final components = data['components'] as List;
          for (var comp in components) {
            if (comp['uid'] == 'net.fabricmc.fabric-loader') {
              final v = comp['version']?.toString() ?? comp['cachedVersion']?.toString();
              if (v != null) return v;
            }
          }
        }
      } catch (e) { print("[LauncherService] Error reading instance.json: $e"); }
    }

    // 4. Check modpack.json (Modrinth standard)
    final modpackPath = p.join(instancePath, 'modpack.json');
    if (await File(modpackPath).exists()) {
      try {
        final data = json.decode(await File(modpackPath).readAsString());
        if (data['minecraft'] != null && data['minecraft']['modLoaders'] != null) {
          final loaders = data['minecraft']['modLoaders'] as List;
          for (var loader in loaders) {
            final id = loader['id'] as String;
            final v = _extractFabricVersion(id);
            if (v != null) return v;
          }
        }
      } catch (e) { print("[LauncherService] Error reading modpack.json: $e"); }
    }

    // 5. Fallback to profiles.json
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
                final v = _extractFabricVersion(vid);
                if (v != null) return v;
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  Future<String?> getMinecraftVersion(String instancePath) async {
    print("[LauncherService] Detecting Minecraft version for: $instancePath");

    // 1. Check CurseForge minecraftinstance.json
    final cfPath = p.join(instancePath, 'minecraftinstance.json');
    if (await File(cfPath).exists()) {
      try {
        final data = json.decode(await File(cfPath).readAsString());
        if (data['gameVersion'] != null) return data['gameVersion'].toString();
      } catch (e) { print("[LauncherService] Error reading CF manifest for MC: $e"); }
    }

    // 2. Check Modrinth instance.json
    final instanceJsonPath = p.join(instancePath, 'instance.json');
    if (await File(instanceJsonPath).exists()) {
      try {
        final data = json.decode(await File(instanceJsonPath).readAsString());
        if (data['components'] != null && data['components'] is List) {
          final components = data['components'] as List;
          for (var comp in components) {
            if (comp['uid'] == 'net.minecraft') {
              final v = comp['version']?.toString() ?? comp['cachedVersion']?.toString();
              if (v != null) return v;
            }
          }
        }
      } catch (e) { print("[LauncherService] Error reading instance.json for MC: $e"); }
    }

    // 3. Check standard manifest.json
    final skPath = p.join(instancePath, 'manifest.json');
    if (await File(skPath).exists()) {
      try {
        final data = json.decode(await File(skPath).readAsString());
        if (data['minecraft'] != null) {
          if (data['minecraft'] is String) return data['minecraft'];
          if (data['minecraft'] is Map && data['minecraft']['version'] != null) return data['minecraft']['version'].toString();
        }
      } catch (e) { print("[LauncherService] Error reading manifest.json for MC: $e"); }
    }
    
    // 4. Check modpack.json (Modrinth standard)
    final modpackPath = p.join(instancePath, 'modpack.json');
    if (await File(modpackPath).exists()) {
      try {
        final data = json.decode(await File(modpackPath).readAsString());
        if (data['game'] != null) return data['game'].toString();
      } catch (e) { print("[LauncherService] Error reading modpack.json for MC: $e"); }
    }

    // 5. Fallback to profiles.json
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
                final v = _extractMinecraftVersion(vid);
                if (v != null) return v;
              }
            }
          }
        }
      }
    } catch (_) {}

    return null;
  }

  Future<void> initializeInstance(String path, String version, String fabricVersion, String minecraftVersion, {String? displayName, String? launcherKey}) async {
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
          "version": minecraftVersion,
          "modLoaders": [
            {"id": "fabric-$fabricVersion", "primary": true}
          ]
        },
        "manifestType": "minecraftModpack",
        "manifestVersion": 1,
        "name": displayName ?? p.basename(path),
        "version": version,
        "author": "Manfredonia Manager",
        "files": [],
        "overrides": "overrides"
      };
      await File(p.join(path, 'manifest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(cfManifest));
      await _createCurseForgeMetadata(path, displayName ?? p.basename(path), fabricVersion, minecraftVersion, cfManifest);
    } else {
      // General manifest for other launchers (SK, etc)
      final manifest = {
        "fabric": fabricVersion,
        "minecraft": minecraftVersion,
        "version": version
      };
      await File(p.join(path, 'manifest.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    }
    
    print("[LauncherService] Initialized new instance folder at $path");

    // Register in launcher_profiles.json if SKLauncher/Vanilla
    if (launcherKey == 'sklauncher' || launcherKey == 'sklauncher_alt') {
      await _registerSkProfile(path, displayName ?? p.basename(path), fabricVersion, minecraftVersion);
    }
  }

  Future<void> _createCurseForgeMetadata(String instancePath, String name, String fabricVersion, String minecraftVersion, Map<String, dynamic> manifest) async {
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
        "gameVersion": minecraftVersion,
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

  Future<void> _registerSkProfile(String gameDir, String name, String fabricVersion, String minecraftVersion) async {
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
        "lastVersionId": "fabric-loader-$fabricVersion-$minecraftVersion",
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

  String? _extractFabricVersion(String? vid) {
    if (vid == null) return null;
    // Match 0.16.10 in 'fabric-loader-0.16.10-1.21.1' or just '0.16.10'
    final match = RegExp(r'fabric(?:-loader)?-([0-9.]+)').firstMatch(vid);
    if (match != null) return match.group(1);
    
    // If it's a version string but doesn't have 'fabric', 
    // it's likely a loader-only string passed in SKLauncher
    if (vid.contains('.') && !vid.contains('1.')) return vid;
    
    return null;
  }

  String? _extractMinecraftVersion(String? vid) {
    if (vid == null) return null;
    // Match 1.21.1 in 'fabric-loader-0.16.10-1.21.1' or '1.21.1-fabric'
    final match = RegExp(r'(1\.\d+(?:\.\d+)?)$').firstMatch(vid);
    if (match != null) return match.group(1);

    // If it starts with 1. and has no fabric, it's just the MC version
    if (vid.startsWith('1.') && !vid.contains('fabric')) return vid;

    return null;
  }
}
