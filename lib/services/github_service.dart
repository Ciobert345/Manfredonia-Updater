import 'dart:convert';
import 'package:http/http.dart' as http;

class GithubRelease {
  final String tag;
  final String downloadUrl;
  final String manifestUrl;
  final String body;

  GithubRelease({required this.tag, required this.downloadUrl, required this.manifestUrl, required this.body});

  factory GithubRelease.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'] ?? '0.0.0';
    final body = json['body'] ?? '';
    String downloadUrl = '';
    String manifestUrl = '';

    print("[GithubService] Parsing release assets for tag $tag...");
    if (json['assets'] != null) {
      for (var asset in json['assets']) {
        final name = asset['name'].toString().toLowerCase();
        print("[GithubService] Checking asset: $name");
        if (name.endsWith('.zip')) {
          downloadUrl = asset['browser_download_url'] ?? '';
        } else if (name == 'manifest.json') {
          manifestUrl = asset['browser_download_url'] ?? '';
        }
      }
    }

    // Fallback: If no manifest.json asset, try to extract from body
    // If body contains a JSON block with "fabric": "..."
    if (manifestUrl.isEmpty && body.contains('"fabric"')) {
      print("[GithubService] Fallback: Found potential manifest in body");
      // We'll mark a special flag or just handle it in the Service
    }

    return GithubRelease(tag: tag, downloadUrl: downloadUrl, manifestUrl: manifestUrl, body: body);
  }
}

class GithubService {
  final String owner = 'Ciobert345';
  final String repo = 'Mod-server-Manfredonia';

  Future<GithubRelease?> getLatestRelease() async {
    final url = Uri.parse('https://api.github.com/repos/$owner/$repo/releases/latest');
    
    try {
      final response = await http.get(url, headers: {
        'User-Agent': 'ManfredoniaUpdater-Flutter',
        'Accept': 'application/vnd.github.v3+json',
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        return GithubRelease.fromJson(json.decode(response.body));
      }
      return null;
    } catch (e) {
      print('Error checking GitHub: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getManifest(String url, {String? fallbackBody}) async {
    if (url.isNotEmpty) {
      try {
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          return json.decode(response.body);
        }
      } catch (e) {
        print('Error fetching manifest: $e');
      }
    }

    // Try fallback from body if provided
    if (fallbackBody != null && (fallbackBody.contains('"fabric"') || fallbackBody.contains('fabric:'))) {
      try {
        print("[GithubService] Attempting to extract manifest from body fallback");
        // Try to find a JSON block: { ... "fabric": "..." ... }
        final jsonRegExp = RegExp(r'\{[\s\S]*"fabric"[\s\S]*\}');
        final jsonMatch = jsonRegExp.firstMatch(fallbackBody);
        if (jsonMatch != null) {
          return json.decode(jsonMatch.group(0)!);
        }

        // Try to find individual lines like "fabric: 0.16.10" or "fabric: 0.16.10"
        final fabricMatch = RegExp(r'fabric[:"]\s*"?([0-9.]+)"?').firstMatch(fallbackBody);
        if (fabricMatch != null) {
          final version = fabricMatch.group(1);
          print("[GithubService] Extracted fabric version from body text: $version");
          return {'fabric': version};
        }
      } catch (e) {
        print("[GithubService] Error extracting manifest from body: $e");
      }
    }
    
    return null;
  }
}
