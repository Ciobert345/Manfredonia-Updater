import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

class UpdateService {
  Future<void> updatePack(
    String instancePath,
    String downloadUrl,
    Function(double progress, String? status) onProgress, {
    List<String> preservedFiles = const [],
  }) async {
    final client = http.Client();
    final request = http.Request('GET', Uri.parse(downloadUrl));
    final response = await client.send(request);

    final totalSize = response.contentLength ?? 0;
    int downloadedSize = 0;
    List<int> bytes = [];

    await for (var chunk in response.stream) {
      bytes.addAll(chunk);
      downloadedSize += chunk.length;
      if (totalSize > 0) {
        onProgress((downloadedSize / totalSize) * 0.5, 'downloading'); 
      }
    }

    // Cleanup folders
    onProgress(0.55, 'cleaning');
    
    // Selective cleanup for mods
    final modsDir = Directory(p.join(instancePath, 'mods'));
    if (await modsDir.exists()) {
      final entries = await modsDir.list().toList();
      for (var entry in entries) {
        if (entry is File) {
          final fileName = p.basename(entry.path);
          if (!preservedFiles.contains(fileName)) {
            await entry.delete();
          }
        } else if (entry is Directory) {
          await entry.delete(recursive: true);
        }
      }
    }

    final otherFolders = ['config', 'scripts', 'kubejs', 'defaultconfigs'];
    for (var folder in otherFolders) {
      final dir = Directory(p.join(instancePath, folder));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }

    // Extract
    onProgress(0.60, 'extracting');
    final archive = ZipDecoder().decodeBytes(bytes);
    final totalFiles = archive.length;
    int extractedFiles = 0;

    for (var file in archive) {
      final filename = file.name;
      String? currentStatus;
      
      if (filename.startsWith('mods/')) {
        currentStatus = 'mods';
      } else if (filename.startsWith('config/') || filename.startsWith('defaultconfigs/')) {
        currentStatus = 'config';
      } else if (filename.startsWith('scripts/') || filename.startsWith('kubejs/')) {
        currentStatus = 'scripts';
      }

      if (file.isFile) {
        final data = file.content as List<int>;
        final outFile = File(p.join(instancePath, filename));
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(data);
      } else {
        await Directory(p.join(instancePath, filename)).create(recursive: true);
      }
      
      extractedFiles++;
      onProgress(0.6 + (extractedFiles / totalFiles) * 0.4, currentStatus); 
    }

    onProgress(1.0, 'completed');
  }
}
