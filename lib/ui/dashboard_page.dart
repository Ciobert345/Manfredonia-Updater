import 'dart:io';
import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:window_manager/window_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/github_service.dart';
import '../services/launcher_service.dart';
import '../services/update_service.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> with WidgetsBindingObserver {
  final LauncherService _launcherService = LauncherService();
  final GithubService _githubService = GithubService();
  final UpdateService _updateService = UpdateService();

  late Map<String, String> _launchers;
  List<String> _instances = [];
  String? _selectedLauncher;
  String? _selectedInstance;
  String _localVersion = 'v?.?.?';
  String _remoteVersion = 'v?.?.?';
  GithubRelease? _latestRelease;
  String? _lastNotifiedTag;
  String? _placeholderInstance;

  double _progress = 0.0;
  bool _isUpdating = false;
  String _statusTitle = "Sync Manifest";
  IconData _statusIcon = Icons.sync;
  String _updateBtnText = "Check for Updates";

  // Sync item states
  bool _modsDone = false;
  bool _configDone = false;
  bool _scriptsDone = false;

  // Custom mod preservation
  bool _preserveModsEnabled = false;
  List<String> _preservedMods = [];
  List<String> _localMods = [];


  @override
  void initState() {
    super.initState();
    _launchers = _launcherService.getLauncherPaths();
    WidgetsBinding.instance.addObserver(this);
    
    // Simply load the last session on startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadLastSession();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print("[Dashboard] Window focused, refreshing instances...");
      _refreshInstances();
    }
  }


  Future<void> _loadLastSession() async {
    final settings = SettingsService();
    if (settings.lastLauncher != null) {
      await _onLauncherChanged(settings.lastLauncher);
      
      if (settings.lastInstance != null && _instances.contains(settings.lastInstance)) {
        await _onInstanceChanged(settings.lastInstance);
      }
    }
  }


  Future<void> _onLauncherChanged(String? value) async {
    // Optimization: avoid redundant clear if launcher didn't change
    if (value == _selectedLauncher && _instances.isNotEmpty) {
      return;
    }

    setState(() {
      _selectedLauncher = value;
      _selectedInstance = null;
      _instances = [];
    });

    if (value != null) {
      await _refreshInstances();
    }
  }

  Future<void> _refreshInstances() async {
    if (_selectedLauncher == null) return;
    
    List<String> combinedInstances = [];
    final value = _selectedLauncher;

    if (value == 'sklauncher') {
      combinedInstances.addAll(_launcherService.scanInstances(_launchers['sklauncher']!));
      combinedInstances.addAll(_launcherService.scanInstances(_launchers['sklauncher_alt']!));
    } else if (value == 'modrinth') {
      combinedInstances.addAll(_launcherService.scanInstances(_launchers['modrinth']!));
      combinedInstances.addAll(_launcherService.scanInstances(_launchers['modrinth_alt']!));
    } else if (_launchers.containsKey(value)) {
      combinedInstances.addAll(_launcherService.scanInstances(_launchers[value]!));
    }
    
    final newList = combinedInstances.toSet().toList();
    
    // Manage placeholder disappearance
    if (_placeholderInstance != null) {
      if (newList.contains(_placeholderInstance)) {
        print("[Dashboard] Placeholder found on disk, clearing flag...");
        _placeholderInstance = null;
      } else if (_selectedLauncher == 'modrinth' || _selectedLauncher == 'modrinth_alt') {
        // Only show placeholder for Modrinth launcher
        newList.insert(0, _placeholderInstance!);
      }
    }

    newList.add("__NEW_INSTALL__");

    if (!listEquals(_instances, newList)) {
      print("[Dashboard] Instances list changed, updating UI...");
      setState(() {
        _instances = newList;
      });
      
      // Auto-validate selected instance if list changed
      if (_selectedInstance != null && newList.contains(_selectedInstance)) {
        _onInstanceChanged(_selectedInstance);
      }
    }
  }

  final TextEditingController _installNameController = TextEditingController();

  Future<void> _handleNewInstallation() async {
    _installNameController.text = "Manfredonia Pack";
    bool valid = false;
    String? name;

    if (_selectedLauncher == 'modrinth' || _selectedLauncher == 'modrinth_alt') {
      await _handleModrinthMrpackInstall();
      return;
    }

    while (!valid) {
      final result = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1e293b),
          title: const Text("New Installation", style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Enter a name for your new modpack instance:", style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              TextField(
                controller: _installNameController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  hintText: "Instance Name",
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("CANCEL", style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3b82f6)),
              child: const Text("INSTALL"),
            ),
          ],
        ),
      );

      if (result != true) return; // User cancelled

      name = _installNameController.text.trim();
      print("[Dashboard] User entered instance name: $name");
      if (name == null || name.isEmpty) continue;

      // Check if already in list
      if (_instances.contains(name)) {
        print("[Dashboard] Name collision in UI list: $name");
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An instance with this name already exists!')),
        );
        continue;
      }

      // Check on disk
      final root = _launchers[_selectedLauncher!] ?? _launchers.values.first;
      final fullPath = p.join(root, name);
      print("[Dashboard] Checking disk path: $fullPath");
      if (Directory(fullPath).existsSync()) {
        print("[Dashboard] Disk collision detected at: $fullPath");
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A folder with this name already exists in your launcher directory!')),
        );
        continue;
      }

      valid = true;
    }

    if (name != null) {
      print("[Dashboard] Proceeding with installation for: $name");
      
      // Ensure we have release info before starting
      if (_latestRelease == null) {
        print("[Dashboard] Release info missing, fetching now...");
        setState(() => _updateBtnText = "Fetching info...");
        _latestRelease = await _githubService.getLatestRelease();
      }

      if (_latestRelease == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not fetch update info from GitHub. Please check your connection.')),
        );
        return;
      }

      setState(() {
        _selectedInstance = name;
        _instances.insert(0, name!);
      });
      await _startUpdate(isNewInstall: true);
    }
  }

  Future<void> _onInstanceChanged(String? value) async {
    if (value == "__NEW_INSTALL__") {
      await _handleNewInstallation();
      return;
    }
    setState(() {
      _selectedInstance = value;
      _localVersion = 'Checking...';
    });
    
    SettingsService().lastLauncher = _selectedLauncher;
    SettingsService().lastInstance = value;
    SettingsService().saveSettings();

    if (value != null) {
      try {
        final path = await _getInstancePath();
        if (path != null) {
          final local = await _launcherService.getLocalVersion(path);
          _latestRelease = await _githubService.getLatestRelease();
          final latest = _latestRelease;
          
          setState(() {
            _localVersion = 'v$local';
            final normLocal = _normalizeVersion(local);

            if (latest != null) {
              _remoteVersion = 'v${latest.tag}';
              final normRemote = _normalizeVersion(latest.tag);
              print("[Dashboard] Version comparison: Local='$local' (norm='$normLocal') vs Remote='${latest.tag}' (norm='$normRemote')");
              
              bool isMatch = normLocal == normRemote;

              if (!isMatch && normLocal != "0.0.0") {
                _updateBtnText = "Update to v${latest.tag}";
                // Silent spam prevention: only notify once per version in a session
                if (_lastNotifiedTag != latest.tag) {
                  NotificationService().showUpdateNotification(latest.tag);
                  _lastNotifiedTag = latest.tag;
                }
              } else if (normLocal == "0.0.0") {
                final hasContent = Directory(p.join(path, 'mods')).existsSync() || 
                                   Directory(p.join(path, 'config')).existsSync();
                _updateBtnText = hasContent ? "Sync & Link Pack" : "Install Pack";
                
                // Only notify if sync is needed AND we haven't notified this tag yet
                if (hasContent && _lastNotifiedTag != latest.tag) {
                  NotificationService().showUpdateNotification(latest.tag);
                  _lastNotifiedTag = latest.tag;
                }
              } else {
                _updateBtnText = "Up to date";
              }
            } else {
              _remoteVersion = 'v?.?.?';
              _updateBtnText = "Offline / Rate Limited";
            }

            // Final override for new Modrinth installs
            if (value == _placeholderInstance && normLocal == "0.0.0") {
              _updateBtnText = "Waiting Modrinth";
            }
          });

          // These don't depend on GitHub release info
          _validateInstanceMetadata(path);
          await _loadPreservedMods(path);
          await _scanLocalMods(path);
        }
      } catch (e) {
        print("[Dashboard] Error in update check: $e");
        setState(() {
          _localVersion = 'Error';
          _updateBtnText = "Retry Check";
        });
      }
    }
  }

  void _showMissingManifestWarning() {

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1e293b),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.orange.withOpacity(0.3))),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 12),
            Text("Istanza Non Valida", style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("ATTENZIONE!", style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 8),
            Text(
              "Questa istanza non contiene il file manifest.json.\nPotrebbe essere un'istanza vuota o non aggiornata.",
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            SizedBox(height: 16),
            Text(
              "Per favore, aggiorna prima questa istanza usando il pulsante Update, oppure seleziona un'altra istanza.",
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("HO CAPITO", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<String?> _getInstancePath({String? launcher, String? instance}) async {
    final l = launcher ?? _selectedLauncher;
    final i = instance ?? _selectedInstance;
    if (l == null || i == null) return null;
    
    String? basePath;
    if (l == 'sklauncher') {
      if (Directory(p.join(_launchers['sklauncher']!, i)).existsSync()) {
        basePath = _launchers['sklauncher']!;
      } else if (Directory(p.join(_launchers['sklauncher_alt']!, i)).existsSync()) {
        basePath = _launchers['sklauncher_alt']!;
      }
    } else if (l == 'modrinth') {
      if (Directory(p.join(_launchers['modrinth']!, i)).existsSync()) {
        basePath = _launchers['modrinth']!;
      } else if (Directory(p.join(_launchers['modrinth_alt']!, i)).existsSync()) {
        basePath = _launchers['modrinth_alt']!;
      }
    } else {
      basePath = _launchers[l];
    }
    
    if (basePath == null) return null;
    return p.join(basePath, i);
  }

  Future<void> _startUpdate({bool isRepair = false, bool isNewInstall = false}) async {
    if (_latestRelease == null || _selectedInstance == null || _selectedLauncher == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a launcher and instance first.')),
      );
      return;
    }

    setState(() {
      _isUpdating = true;
      _progress = 0.0;
      _statusTitle = isNewInstall ? "Preparing Installation" : (isRepair ? "Repairing Files" : "Starting Update");
      _statusIcon = isRepair ? Icons.build : Icons.downloading;
      _updateBtnText = isRepair ? "Repairing..." : "Updating...";
      _modsDone = false;
      _configDone = false;
      _scriptsDone = false;
    });

    try {
      String? path;
      if (isNewInstall) {
        final basePath = _launchers[_selectedLauncher!.contains('alt') ? _selectedLauncher : _selectedLauncher];
        // For new install, use the primary path if possible
        final root = _launchers[_selectedLauncher!] ?? _launchers.values.first;
        path = p.join(root, _selectedInstance!);
        
        // Initialize metadata for the new instance
        final manifest = await _githubService.getManifest(_latestRelease!.manifestUrl, fallbackBody: _latestRelease!.body);
        final fabricV = manifest?['fabric'] ?? '0.16.10';
        final minecraftV = manifest?['minecraft'] ?? '1.21.1';
        await _launcherService.initializeInstance(
          path, 
          '0.0.0', 
          fabricV, 
          minecraftV,
          displayName: _selectedInstance,
          launcherKey: _selectedLauncher,
        );
      } else {
        path = await _getInstancePath();
      }

      if (path == null) throw Exception("Instance path not found");

      await _updateService.updatePack(
        path, 
        _latestRelease!.downloadUrl, 
        (p, status) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            
            if (status == 'mods') _modsDone = true;
            if (status == 'config') _configDone = true;
            if (status == 'scripts') _scriptsDone = true;

            if (status == 'downloading') {
              _statusTitle = "Downloading Pack...";
              _statusIcon = Icons.cloud_download;
            } else if (status == 'cleaning') {
              _statusTitle = "Cleaning instance...";
              _statusIcon = Icons.cleaning_services;
            } else if (status == 'extracting') {
              _statusTitle = "Extracting files...";
              _statusIcon = Icons.unarchive;
            } else if (status == 'completed') {
              _modsDone = true;
              _configDone = true;
              _scriptsDone = true;
              _statusTitle = "Installation Complete";
            }
          });
        },
        preservedFiles: _preserveModsEnabled ? _preservedMods : [],
      );

      // Validate instance metadata (Fabric & MC Version) after update
      await _validateInstanceMetadata(path);

      await _launcherService.setLocalVersion(path, _latestRelease!.tag);

      setState(() {
        _statusTitle = isRepair ? "Repair Complete" : "Update Complete";
        _statusIcon = Icons.check_circle;
        _updateBtnText = "Completed";
        _localVersion = 'v${_latestRelease!.tag}';
        _modsDone = true;
        _configDone = true;
        _scriptsDone = true;
      });

      _showNotification(
        isRepair ? 'Repair successful!' : 'Update successful!',
        NotificationType.success,
      );

      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _isUpdating = false;
            _progress = 0.0;
            _statusTitle = "Sync Manifest";
            _statusIcon = Icons.sync;
            _updateBtnText = "Up to date";
          });
        }
      });
    } catch (e) {
      setState(() {
        _statusTitle = isRepair ? "Repair Failed" : "Update Failed";
        _isUpdating = false;
        _updateBtnText = isRepair ? "Retry Repair" : "Retry Update";
      });
      _showNotification(
        'Error: ${e.toString()}',
        NotificationType.error,
      );
    }
  }

  void _showNotification(String message, NotificationType type) {
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => Positioned(
        bottom: 70,
        left: 22,
        right: 22,
        child: _CustomNotification(
          message: message,
          type: type,
          onDismiss: () => entry.remove(),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
  }

  Future<void> _loadPreservedMods(String instancePath) async {
    final file = File(p.join(instancePath, 'preserved_mods.json'));
    if (await file.exists()) {
      try {
        final content = await file.readAsString();
        final List<dynamic> data = json.decode(content);
        setState(() {
          _preservedMods = data.cast<String>();
          _preserveModsEnabled = _preservedMods.isNotEmpty;
        });
      } catch (e) {
        print("[Dashboard] Error loading preserved mods: $e");
      }
    } else {
      setState(() {
        _preservedMods = [];
        _preserveModsEnabled = false;
      });
    }
  }

  Future<void> _savePreservedMods(String instancePath) async {
    final file = File(p.join(instancePath, 'preserved_mods.json'));
    if (_preservedMods.isEmpty) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(json.encode(_preservedMods));
  }

  Future<void> _scanLocalMods(String instancePath) async {
    final modsDir = Directory(p.join(instancePath, 'mods'));
    if (await modsDir.exists()) {
      final entries = await modsDir.list().toList();
      final jars = entries
          .whereType<File>()
          .map((e) => p.basename(e.path))
          .where((e) => e.endsWith('.jar'))
          .toList();
      jars.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      setState(() {
        _localMods = jars;
      });
    } else {
      setState(() {
        _localMods = [];
      });
    }
  }

  Future<void> _openChangelog() async {
    final url = Uri.parse('https://github.com/${_githubService.owner}/${_githubService.repo}/releases');
    if (!await launchUrl(url)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open changelog link.')),
      );
    }
  }

  Future<void> _validateInstanceMetadata(String path) async {
    print("[Dashboard] Validating instance metadata for path: $path");
    if (_latestRelease == null) return;
    if (_latestRelease!.manifestUrl.isEmpty) return;

    final manifest = await _githubService.getManifest(
      _latestRelease!.manifestUrl,
      fallbackBody: _latestRelease!.body
    );
    if (manifest == null) return;

    // 1. Check Fabric Version
    final requiredFabric = manifest['fabric'] as String?;
    if (requiredFabric != null) {
      final currentFabric = await _launcherService.getFabricVersion(path);
      if (currentFabric == null) {
        _showNotification(
          "Fabric Loader not detected! Version $requiredFabric is required. Please install it in your launcher.",
          NotificationType.warning
        );
      } else if (currentFabric != requiredFabric) {
        _showNotification(
          "Fabric Loader mismatch: required $requiredFabric, found $currentFabric. Update it in your launcher settings!",
          NotificationType.warning
        );
      }
    }

    // 2. Check Minecraft Game Version
    final requiredMC = manifest['minecraft'] as String?;
    if (requiredMC != null) {
      final currentMC = await _launcherService.getMinecraftVersion(path);
      if (currentMC == null) {
        _showNotification(
          "Minecraft Version not detected! Version $requiredMC is required. Please install it in your launcher.",
          NotificationType.warning
        );
      } else if (currentMC != requiredMC) {
        _showNotification(
          "Minecraft Version mismatch: required $requiredMC, found $currentMC. Change it in your launcher settings!",
          NotificationType.warning
        );
      }
    }
  }


  Future<void> _handleModrinthMrpackInstall() async {
    if (_latestRelease == null) {
      print("[Dashboard] Release info missing, fetching now...");
      setState(() => _updateBtnText = "Fetching info...");
      _latestRelease = await _githubService.getLatestRelease();
    }

    if (_latestRelease == null || _latestRelease!.mrpackUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No .mrpack file found in the latest release. Please contact the administrator.')),
      );
      return;
    }

    setState(() {
      _placeholderInstance = "Manfredonia Pack";
      if (!_instances.contains(_placeholderInstance)) {
        _instances.insert(0, _placeholderInstance!);
      }
      _selectedInstance = _placeholderInstance;

      _isUpdating = true;
      _progress = 0.0;
      _statusTitle = "Downloading Modpack";
      _statusIcon = Icons.cloud_download;
      _updateBtnText = "Downloading...";
      _modsDone = false;
      _configDone = false;
      _scriptsDone = false;
    });

    try {
      final tempDir = await getTemporaryDirectory();
      final savePath = p.join(tempDir.path, "Manfredonia_Pack_${_latestRelease!.tag}.mrpack");
      
      await _updateService.downloadFile(
        _latestRelease!.mrpackUrl,
        savePath,
        (progress) {
          if (!mounted) return;
          setState(() {
            _progress = progress;
            
            // Simulating sync steps for UI feedback
            if (progress > 0.3) _modsDone = true;
            if (progress > 0.6) _configDone = true;
            if (progress > 0.9) _scriptsDone = true;
          });
        },
      );

      print("[Dashboard] Download complete: $savePath");
      
      setState(() {
        _statusTitle = "Download Complete";
        _statusIcon = Icons.check_circle;
        _updateBtnText = "Completed";
        _progress = 1.0;
        _modsDone = true;
        _configDone = true;
        _scriptsDone = true;
      });

      _showNotification("Download completed! Modrinth will now open the file.", NotificationType.success);

      // Open the file with the system default handler (Modrinth)
      final url = Uri.file(savePath);
      if (await canLaunchUrl(url)) {
        await launchUrl(url);
      } else {
        // Fallback for Windows if canLaunchUrl fails for local files
        if (Platform.isWindows) {
          await Process.run('explorer', [savePath]);
        } else {
          throw Exception("Could not open the downloaded file.");
        }
      }

      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _isUpdating = false;
            _progress = 0.0;
            _statusTitle = "Sync Manifest";
            _statusIcon = Icons.sync;
            
            if (_placeholderInstance != null && _selectedInstance == _placeholderInstance) {
              _updateBtnText = "Waiting Modrinth";
            } else {
              _onInstanceChanged(_selectedInstance);
            }
          });
        }
      });

    } catch (e) {
      print("[Dashboard] Error during .mrpack download: $e");
      setState(() {
        _isUpdating = false;
        _statusTitle = "Download Failed";
        _updateBtnText = "Retry";
      });
      _showNotification("Error downloading modpack: $e", NotificationType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF020617),
          ),
          child: Stack(
            children: [
              // Background Image
              const Positioned.fill(
                child: Opacity(
                  opacity: 0.6,
                  child: Image(
                    image: AssetImage('assets/images/panorama.png'),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
              // Blur & Gradient
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          const Color(0xFF172554).withOpacity(0.2),
                          const Color(0xFF020617).withOpacity(1.0),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              
              // Content
              Column(
                children: [
                  // Header (Drag region)
                  GestureDetector(
                    onHorizontalDragStart: (_) => windowManager.startDragging(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.1),
                        border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            height: 52,
                            width: 52,
                            child: Image.asset('assets/app_logo_final.png', fit: BoxFit.contain),
                          ),
                          const SizedBox(width: 16),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Manfredonia Manager',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                                Text(
                                  'MODPACK MANAGER',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFBFDBFE),
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                                ),
                                child: const Text('v1.0.0', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFBFDBFE))),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: () => windowManager.close(),
                                icon: const Icon(Icons.close, color: Colors.white30, size: 20),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Body
                  Expanded(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLabel('Select Launcher'),
                            const SizedBox(height: 8),
                            _buildDropdown(
                              icon: Icons.rocket_launch,
                              value: _selectedLauncher,
                              hint: 'Choose a launcher platform...',
                              items: const [
                                DropdownMenuItem(value: 'curseforge', child: Text('CurseForge')),
                                DropdownMenuItem(value: 'modrinth', child: Text('Modrinth')),
                                DropdownMenuItem(value: 'sklauncher', child: Text('SKLauncher')),
                              ],
                              onChanged: _onLauncherChanged,
                            ),
                            const SizedBox(height: 20),
                            
                            _buildLabel('Target Instance', opacity: _selectedLauncher == null ? 0.4 : 0.7),
                            const SizedBox(height: 8),
                            _buildDropdown(
                              icon: Icons.folder,
                              value: _selectedInstance,
                              hint: _selectedLauncher == null ? 'Waiting for launcher...' : 'Select an instance...',
                              enabled: _selectedLauncher != null,
                              items: _instances.map((i) {
                                if (i == "__NEW_INSTALL__") {
                                  return const DropdownMenuItem(
                                    value: "__NEW_INSTALL__",
                                    child: Text("+ Install as NEW", style: TextStyle(color: Color(0xFF3b82f6), fontWeight: FontWeight.bold)),
                                  );
                                }
                                return DropdownMenuItem(value: i, child: Text(i));
                              }).whereType<DropdownMenuItem<String>>().toList(),
                              onChanged: _onInstanceChanged,
                            ),
                            const SizedBox(height: 20),
    
                            // Sync Status Card
                            _buildStatusCard(),
                            const SizedBox(height: 20),


                            // Advanced Options
                            if (_selectedInstance != null && _selectedInstance != "__NEW_INSTALL__") 
                              _buildAdvancedOptions(),
                            
                            const SizedBox(height: 20),
    
                            // Buttons
                            Row(
                              children: [
                                Expanded(
                                  flex: 2,
                                  child: _buildPrimaryButton(),
                                ),
                                const SizedBox(width: 12),
                                _buildSecondaryButton(),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  // Footer
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.2),
                      border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            _buildVersionInfo(Icons.download_done, _localVersion, Colors.grey),
                            const SizedBox(width: 6),
                            _buildVersionInfo(Icons.speed, _remoteVersion, const Color(0xFF3b82f6), active: true),
                          ],
                        ),
                        Row(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF3b82f6).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: const Color(0xFF3b82f6).withOpacity(0.2),
                                ),
                              ),
                              child: InkWell(
                                onTap: _openChangelog,
                                borderRadius: BorderRadius.circular(20),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'CHANGELOG',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFFBFDBFE),
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      SizedBox(width: 4),
                                      Icon(Icons.arrow_outward_rounded, size: 10, color: Color(0xFFBFDBFE)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text, {double opacity = 0.7}) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.bold,
        color: Colors.white.withOpacity(opacity),
        letterSpacing: 1.5,
      ),
    );
  }

  Widget _buildDropdown({
    required IconData icon,
    required String? value,
    required String hint,
    required List<DropdownMenuItem<String>> items,
    required Function(String?) onChanged,
    bool enabled = true,
  }) {
    // Create a map of values to labels
    final Map<String, String> itemLabels = {};
    for (var item in items) {
      if (item.value != null && item.child is Text) {
        itemLabels[item.value!] = (item.child as Text).data ?? '';
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return PopupMenuButton<String>(
          enabled: enabled,
          offset: Offset.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          color: const Color(0xFF0f172a),
          constraints: BoxConstraints(
            minWidth: constraints.maxWidth,
            maxWidth: constraints.maxWidth,
          ),
          itemBuilder: (context) {
            return items.map((item) {
              return PopupMenuItem<String>(
                value: item.value,
                height: 40,
                child: item.child,
              );
            }).toList();
          },
          onSelected: (String newValue) {
            onChanged(newValue);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: enabled ? const Color(0xFF1e293b).withOpacity(0.6) : const Color(0xFF1e293b).withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: enabled ? const Color(0xFF60a5fa).withOpacity(0.3) : Colors.white.withOpacity(0.1),
                width: 1.5,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: enabled ? const Color(0xFF60a5fa) : Colors.grey),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    value != null && itemLabels.containsKey(value)
                        ? itemLabels[value]!
                        : hint,
                    style: TextStyle(
                      color: value != null ? Colors.white : (enabled ? Colors.white60 : Colors.grey),
                      fontSize: 14,
                    ),
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 24, color: enabled ? const Color(0xFF60a5fa) : Colors.grey),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF3b82f6).withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3b82f6).withOpacity(0.15)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(_statusIcon, size: 18, color: const Color(0xFF3b82f6)),
                  const SizedBox(width: 8),
                  Text(_statusTitle.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF3b82f6), letterSpacing: 1)),
                ],
              ),
              if (_isUpdating)
                Text('${(_progress * 100).toInt()}%', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF3b82f6))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _SyncItem(label: 'Mods', isDone: _modsDone, icon: Icons.extension)),
              const SizedBox(width: 8),
              Expanded(child: _SyncItem(label: 'Config', isDone: _configDone, icon: Icons.settings_suggest)),
              const SizedBox(width: 8),
              Expanded(child: _SyncItem(label: 'Scripts', isDone: _scriptsDone, icon: Icons.code)),
            ],
          ),
          if (_isUpdating) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress,
                backgroundColor: Colors.black.withOpacity(0.25),
                valueColor: const AlwaysStoppedAnimation(Color(0xFF3b82f6)),
                minHeight: 6,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdvancedOptions() {
    final accentColor = _preserveModsEnabled ? Colors.greenAccent : const Color(0xFF3b82f6).withOpacity(0.5);
    
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: 400.ms,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(1), // Border width
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accentColor.withOpacity(0.3),
              accentColor.withOpacity(0.05),
            ],
          ),
          boxShadow: [
            if (_preserveModsEnabled)
              BoxShadow(
                color: Colors.greenAccent.withOpacity(0.12),
                blurRadius: 20,
                spreadRadius: -5,
              ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0f172a).withOpacity(0.7),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: accentColor.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _preserveModsEnabled ? Icons.security_rounded : Icons.security_outlined,
                              size: 18,
                              color: accentColor,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "MOD PRESERVATION",
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: accentColor,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              Text(
                                _preserveModsEnabled ? "SHIELD ACTIVE" : "STANDARD CLEANUP",
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: _preserveModsEnabled ? Colors.greenAccent.withOpacity(0.7) : Colors.white24,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Transform.scale(
                        scale: 0.8,
                        child: Switch(
                          value: _preserveModsEnabled,
                          activeColor: Colors.greenAccent,
                          activeTrackColor: Colors.greenAccent.withOpacity(0.2),
                          onChanged: (val) {
                            if (val) {
                              _showPreservationWarning();
                            } else {
                              setState(() {
                                _preserveModsEnabled = false;
                                _preservedMods = [];
                              });
                              _getInstancePath().then((path) {
                                if (path != null) _savePreservedMods(path);
                              });
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  if (_preserveModsEnabled) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Divider(color: Colors.white10, height: 1),
                    ),
                    InkWell(
                      onTap: _showModSelectionDialog,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.04),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.tune_rounded, size: 16, color: Colors.blueAccent.withOpacity(0.7)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                "${_preservedMods.length} Personal Mods Selected",
                                style: const TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.w500),
                              ),
                            ),
                            const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: Colors.white24),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
       ).animate(target: _preserveModsEnabled ? 1 : 0)
       .shimmer(duration: 3.seconds, color: Colors.white.withOpacity(0.05)),
    );
  }



  void _showPreservationWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0f172a),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Colors.redAccent, width: 1),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            SizedBox(width: 12),
            Text("Advanced Feature", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "DANGER ZONE",
              style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w900, fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              "By enabling this, you can choose which mods to keep during updates.\n\n"
              "WARNING: Preserved mods can cause crashes or errors.\n\n"
              "Use this feature at your own risk!",
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCEL", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _preserveModsEnabled = true);
              Navigator.pop(context);
              _showModSelectionDialog();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.withOpacity(0.2),
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
            ),
            child: const Text("I UNDERSTAND"),
          ),
        ],
      ),
    );
  }

  void _showModSelectionDialog() async {
    final path = await _getInstancePath();
    if (path == null) return;
    
    await _scanLocalMods(path);
    if (!mounted) return;

    List<String> tempSelection = List.from(_preservedMods);
    String searchQuery = "";

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Close",
      barrierColor: Colors.black.withOpacity(0.7),
      transitionDuration: const Duration(milliseconds: 400),
      pageBuilder: (context, anim1, anim2) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final filteredMods = _localMods
                .where((m) => m.toLowerCase().contains(searchQuery.toLowerCase()))
                .toList();

            return Center(
              child: Container(
                width: 480,
                height: 600,
                margin: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.1)),
                  boxShadow: [
                    BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 40, spreadRadius: 10)
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Scaffold(
                      backgroundColor: const Color(0xFF0f172a).withOpacity(0.8),
                      appBar: AppBar(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        automaticallyImplyLeading: false,
                        title: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.1), shape: BoxShape.circle),
                              child: const Icon(Icons.inventory_2_rounded, size: 20, color: Colors.blueAccent),
                            ),
                            const SizedBox(width: 12),
                            const Text("LOCAL MOD SHIELD", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1)),
                          ],
                        ),
                        actions: [
                          IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, color: Colors.white38)),
                        ],
                      ),
                      body: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          children: [
                            // Search Bar
                            AnimatedContainer(
                              duration: 300.ms,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.blueAccent.withOpacity(0.3)),
                                boxShadow: [
                                  BoxShadow(color: Colors.blueAccent.withOpacity(0.1), blurRadius: 10, spreadRadius: -2)
                                ],
                              ),
                              child: TextField(
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                                decoration: InputDecoration(
                                  hintText: "Search local .jar files...",
                                  hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
                                  prefixIcon: const Icon(Icons.search_rounded, color: Colors.blueAccent, size: 20),
                                  filled: true,
                                  fillColor: const Color(0xFF1e293b).withOpacity(0.5),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                ),
                                onChanged: (val) {
                                  setDialogState(() => searchQuery = val);
                                },
                              ),
                            ),
                            const SizedBox(height: 20),
                            Expanded(
                              child: filteredMods.isEmpty 
                                ? Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.search_off_rounded, size: 48, color: Colors.white10),
                                        const SizedBox(height: 12),
                                        Text(
                                          searchQuery.isEmpty ? "No mods detected in this instance" : "No results for '$searchQuery'", 
                                          style: const TextStyle(color: Colors.white38, fontSize: 13)
                                        ),
                                      ],
                                    ),
                                  )
                                : ListView.builder(
                                    itemCount: filteredMods.length,
                                    itemBuilder: (context, index) {
                                      final mod = filteredMods[index];
                                      final isSelected = tempSelection.contains(mod);
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 8),
                                        child: InkWell(
                                          onTap: () {
                                            setDialogState(() {
                                              if (isSelected) tempSelection.remove(mod);
                                              else tempSelection.add(mod);
                                            });
                                          },
                                          borderRadius: BorderRadius.circular(12),
                                          child: AnimatedContainer(
                                            duration: 300.ms,
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                            decoration: BoxDecoration(
                                              color: isSelected ? Colors.blueAccent.withOpacity(0.1) : Colors.white.withOpacity(0.03),
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(
                                                color: isSelected ? Colors.blueAccent.withOpacity(0.4) : Colors.white.withOpacity(0.05),
                                              ),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(
                                                  isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                                                  size: 20,
                                                  color: isSelected ? Colors.blueAccent : Colors.white12,
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Text(
                                                    mod, 
                                                    style: TextStyle(
                                                      color: isSelected ? Colors.white : Colors.white60, 
                                                      fontSize: 13,
                                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ).animate(delay: (index < 15 ? index * 20 : 0).ms).fadeIn(duration: 300.ms),
                                      );
                                    },
                                  ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              height: 50,
                              child: ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    _preservedMods = tempSelection;
                                    _preserveModsEnabled = _preservedMods.isNotEmpty;
                                  });
                                  _savePreservedMods(path);
                                  Navigator.pop(context);
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF3b82f6),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  elevation: 8,
                                  shadowColor: const Color(0xFF3b82f6).withOpacity(0.4),
                                ),
                                child: Text("SAVE CONFIGURATION (${tempSelection.length})", style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return FadeTransition(
          opacity: anim1,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: anim1, curve: Curves.easeOutBack)),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildPrimaryButton() {
    bool canUpdate = !_isUpdating && _selectedInstance != null && _remoteVersion != 'v?.?.?' && _updateBtnText != "Waiting Modrinth";
    final primaryColor = const Color(0xFF3b82f6);
    final accentColor = const Color(0xFF2563eb);
    
    return AnimatedContainer(
      duration: 300.ms,
      height: 56,
      decoration: BoxDecoration(
        gradient: canUpdate ? LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [primaryColor, accentColor],
        ) : null,
        color: canUpdate ? null : Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: canUpdate ? Colors.white.withOpacity(0.2) : Colors.white.withOpacity(0.05),
          width: 1,
        ),
        boxShadow: canUpdate ? [
          BoxShadow(
            color: primaryColor.withOpacity(0.3),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ] : [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canUpdate ? _startUpdate : null,
          borderRadius: BorderRadius.circular(16),
          splashColor: Colors.white.withOpacity(0.1),
          highlightColor: Colors.white.withOpacity(0.05),
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.sync_rounded, 
                  size: 22, 
                  color: canUpdate ? Colors.white : Colors.white10,
                ),
                const SizedBox(width: 10),
                Text(
                  _updateBtnText.toUpperCase(), 
                  style: TextStyle(
                    fontWeight: FontWeight.w900, 
                    letterSpacing: 1.5,
                    fontSize: 14,
                    color: canUpdate ? Colors.white : Colors.white10,
                  )
                ),
              ],
            ),
          ),
        ),
      ),
    ).animate(target: canUpdate ? 1 : 0)
     .shimmer(duration: 2.seconds, color: Colors.white.withOpacity(0.1), delay: 1.seconds)
     .scale(begin: const Offset(1, 1), end: const Offset(1.01, 1.01), duration: 400.ms, curve: Curves.easeOut);
  }

  Widget _buildSecondaryButton() {
    bool canRepair = !_isUpdating && _selectedInstance != null && _latestRelease != null;
    final secondaryColor = const Color(0xFF0ea5e9);
    
    return AnimatedContainer(
      duration: 300.ms,
      height: 56,
      width: 120,
      decoration: BoxDecoration(
        color: canRepair ? secondaryColor.withOpacity(0.1) : Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: canRepair ? secondaryColor.withOpacity(0.4) : Colors.white.withOpacity(0.05),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canRepair ? () => _startUpdate(isRepair: true) : null,
          borderRadius: BorderRadius.circular(16),
          splashColor: secondaryColor.withOpacity(0.1),
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.build_rounded, 
                  size: 18, 
                  color: canRepair ? secondaryColor : Colors.white10,
                ),
                const SizedBox(width: 8),
                Text(
                  'REPAIR', 
                  style: TextStyle(
                    fontWeight: FontWeight.bold, 
                    letterSpacing: 1,
                    fontSize: 14,
                    color: canRepair ? Colors.white : Colors.white10,
                  )
                ),
              ],
            ),
          ),
        ),
      ),
    ).animate(target: canRepair ? 1 : 0)
     .scale(begin: const Offset(1, 1), end: const Offset(1.01, 1.01), duration: 400.ms);
  }

  Widget _buildVersionInfo(IconData icon, String version, Color color, {bool active = false}) {
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? color.withOpacity(0.1) : Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? color.withOpacity(0.2) : Colors.white.withOpacity(0.05),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active)
              const _PulseIndicator()
            else
              Container(
                height: 6,
                width: 6,
                decoration: BoxDecoration(color: color.withOpacity(0.5), shape: BoxShape.circle),
              ),
            const SizedBox(width: 8),
            Text(
              version,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                color: active ? const Color(0xFFBFDBFE) : Colors.white24,
              ),
            ),
          ],
        ),
    );
  }
  String _normalizeVersion(String v) {
    if (v == '0.0.0' || v.isEmpty) return '0.0.0';
    final match = RegExp(r'(\d+\.\d+(\.\d+)?)').firstMatch(v);
    if (match != null) return match.group(0)!;
    return v.trim().toLowerCase().replaceFirst('v', '');
  }
}

class _SyncItem extends StatelessWidget {
  final String label;
  final bool isDone;
  final IconData icon;
  
  const _SyncItem({
    required this.label, 
    this.isDone = false,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final activeColor = const Color(0xFF3b82f6);
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: isDone ? activeColor.withOpacity(0.08) : Colors.black.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDone ? activeColor.withOpacity(0.4) : Colors.white.withOpacity(0.05),
          width: 1,
        ),
        boxShadow: isDone ? [
          BoxShadow(
            color: activeColor.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: -2,
          )
        ] : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDone ? Icons.check_circle : icon,
            size: 18,
            color: isDone ? activeColor : Colors.white24,
          ),
          const SizedBox(height: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w900,
              color: isDone ? Colors.white : Colors.white24,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isDone ? "INSTALLED" : "PENDING",
            style: TextStyle(
              fontSize: 7,
              fontWeight: FontWeight.bold,
              color: isDone ? activeColor.withOpacity(0.8) : Colors.white10,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    ).animate(target: isDone ? 1 : 0)
     .shimmer(duration: 1200.ms, color: Colors.white.withOpacity(0.05))
     .scale(begin: const Offset(1, 1), end: const Offset(1.02, 1.02), duration: 400.ms, curve: Curves.easeOutBack);
  }
}

class _PulseIndicator extends StatelessWidget {
  const _PulseIndicator();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      width: 8,
      decoration: const BoxDecoration(
        color: Color(0xFF3b82f6),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: Color(0xFF3b82f6), blurRadius: 4),
        ],
      ),
    ).animate(onPlay: (controller) => controller.repeat())
     .scale(begin: const Offset(1, 1), end: const Offset(1.2, 1.2), duration: 1500.ms)
     .fadeOut(begin: 0.5, duration: 1500.ms);
  }
}

enum NotificationType { success, error, warning, info }

class _CustomNotification extends StatelessWidget {
  final String message;
  final NotificationType type;
  final VoidCallback onDismiss;

  const _CustomNotification({
    required this.message,
    required this.type,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    Color color;
    IconData icon;
    
    switch (type) {
      case NotificationType.success:
        color = const Color(0xFF10b981);
        icon = Icons.check_circle_rounded;
        break;
      case NotificationType.error:
        color = const Color(0xFFef4444);
        icon = Icons.error_rounded;
        break;
      case NotificationType.warning:
        color = const Color(0xFFf59e0b);
        icon = Icons.warning_rounded;
        break;
      case NotificationType.info:
        color = const Color(0xFF3b82f6);
        icon = Icons.info_rounded;
        break;
    }

    return Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0f172a).withOpacity(0.85),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withOpacity(0.4), width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: color.withOpacity(0.15),
                      blurRadius: 30,
                      spreadRadius: -10,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: color, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type.name.toUpperCase(),
                            style: TextStyle(
                              color: color,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: onDismiss,
                      icon: const Icon(Icons.close, color: Colors.white24, size: 18),
                      splashRadius: 20,
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
        .animate()
        .fadeIn(duration: 400.ms)
        .slideY(begin: 0.3, end: 0, curve: Curves.easeOutExpo)
        .then(delay: 4.seconds)
        .fadeOut(duration: 400.ms)
        .slideY(begin: 0, end: 0.3, curve: Curves.easeInCirc)
        .callback(callback: (_) => onDismiss()),
      ),
    );
  }
}
