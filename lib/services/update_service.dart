import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class AppUpdateInfo {
  final String latestVersion;
  final String changelog;
  final String? windowsUrl;
  final String? apkUrl;
  final String? releaseUrl;
  final bool hasUpdate;

  AppUpdateInfo({
    required this.latestVersion,
    required this.changelog,
    this.windowsUrl,
    this.apkUrl,
    this.releaseUrl,
    required this.hasUpdate,
  });
}

class UpdateService {
  static const String currentVersion = '2.5.0';
  static const String repoOwner = 'hellwarr';
  static const String repoName = 'timber_dry';

  /// Check GitHub for latest release
  static Future<AppUpdateInfo?> fetchLatestRelease() async {
    try {
      final url = Uri.parse('https://api.github.com/repos///releases/latest');
      final response = await http.get(url, headers: {
        'Accept': 'application/vnd.github.v3+json',
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final tagName = (data['tag_name'] as String? ?? '').replaceFirst('v', '').trim();
        final body = data['body'] as String? ?? 'Оновлення містить виправлення та нові функції.';
        final htmlUrl = data['html_url'] as String?;

        String? winUrl;
        String? apkUrl;

        final assets = data['assets'] as List? ?? [];
        for (var asset in assets) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          final downloadUrl = asset['browser_download_url'] as String?;
          if (name.contains('.apk')) {
            apkUrl = downloadUrl;
          } else if (name.contains('windows') || name.contains('.zip') || name.contains('.exe')) {
            winUrl = downloadUrl;
          }
        }

        final hasUpdate = _isVersionNewer(currentVersion, tagName);

        return AppUpdateInfo(
          latestVersion: tagName.isNotEmpty ? tagName : currentVersion,
          changelog: body,
          windowsUrl: winUrl,
          apkUrl: apkUrl,
          releaseUrl: htmlUrl,
          hasUpdate: hasUpdate,
        );
      }
    } catch (_) {}
    return null;
  }

  static bool _isVersionNewer(String current, String remote) {
    if (remote.isEmpty) return false;
    try {
      final curParts = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      final remParts = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();

      for (int i = 0; i < 3; i++) {
        final cur = i < curParts.length ? curParts[i] : 0;
        final rem = i < remParts.length ? remParts[i] : 0;
        if (rem > cur) return true;
        if (rem < cur) return false;
      }
    } catch (_) {}
    return false;
  }

  /// Show stylish update dialog to user
  static Future<void> checkAndShowUpdateDialog(BuildContext context, {bool isManualCheck = false}) async {
    final update = await fetchLatestRelease();

    if (!context.mounted) return;

    if (update != null && update.hasUpdate) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF141A26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFFF9000), width: 1.5),
          ),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9000).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.system_update_rounded, color: Color(0xFFFF9000), size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Доступне оновлення!',
                      style: GoogleFonts.inter(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    Text(
                      'Версія v${update.latestVersion} (поточна: v)',
                      style: GoogleFonts.inter(fontSize: 12, color: const Color(0xFF00E5FF)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Що нового в цій версії:',
                style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Text(
                    update.changelog,
                    style: GoogleFonts.inter(fontSize: 13, color: Colors.white.withOpacity(0.9), height: 1.4),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Пізніше', style: GoogleFonts.inter(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                String? targetUrl;
                if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && update.apkUrl != null) {
                  targetUrl = update.apkUrl;
                } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows && update.windowsUrl != null) {
                  targetUrl = update.windowsUrl;
                } else {
                  targetUrl = update.releaseUrl ?? update.apkUrl ?? update.windowsUrl;
                }

                if (targetUrl != null) {
                  final uri = Uri.parse(targetUrl);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                }
              },
              icon: const Icon(Icons.download_rounded, color: Colors.black, size: 18),
              label: Text(
                'Оновити зараз',
                style: GoogleFonts.inter(color: Colors.black, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF9000),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
      );
    } else if (isManualCheck) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF10B981),
          content: Text('У вас встановлено найновішу версію TimberDry (v)!'),
        ),
      );
    }
  }
}
