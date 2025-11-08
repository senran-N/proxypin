import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/util/file_read.dart';
import 'package:proxypin/network/util/logger.dart';

/// Persistent AI settings (stored in ~/.proxypin/ai_config.json)
class AISettings {
  String baseUrl;
  String apiKey;
  String model;
  bool enableTools;
  int maxContextItems;

  AISettings({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.enableTools = true,
    this.maxContextItems = 20,
  });

  static AISettings? _instance;

  static Future<AISettings> get instance async {
    if (_instance != null) return _instance!;
    try {
      final file = await _file();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          _instance = AISettings.fromJson(json);
          return _instance!;
        }
      }
    } catch (e) {
      logger.w('Load AI settings failed: $e');
    }
    _instance = AISettings();
    return _instance!;
  }

  static Future<File> _file() async {
    final home = await FileRead.homeDir();
    final path = '${home.path}${Platform.pathSeparator}ai_config.json';
    return File(path);
  }

  Future<void> save() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        await f.create(recursive: true);
      }
      await f.writeAsString(jsonEncode(toJson()));
    } catch (e) {
      logger.e('Save AI settings failed', error: e);
    }
  }

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'enableTools': enableTools,
        'maxContextItems': maxContextItems,
      };

  factory AISettings.fromJson(Map<String, dynamic> json) => AISettings(
        baseUrl: (json['baseUrl'] as String?)?.trim().isNotEmpty == true
            ? json['baseUrl'] as String
            : 'https://api.openai.com/v1',
        apiKey: json['apiKey'] ?? '',
        model: json['model'] ?? 'gpt-4o-mini',
        enableTools: json['enableTools'] ?? true,
        maxContextItems: json['maxContextItems'] ?? 20,
      );
}

