import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/util/file_read.dart';

import 'ai_client.dart';

class AIHistory {
  static Future<File> _file() async {
    final home = await FileRead.homeDir();
    final path = '${home.path}${Platform.pathSeparator}ai_history.json';
    return File(path);
  }

  static Future<List<AIMessage>> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return <AIMessage>[];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return <AIMessage>[];
      final arr = jsonDecode(text) as List<dynamic>;
      return arr.map((e) => AIMessage.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return <AIMessage>[];
    }
  }

  static Future<void> save(List<AIMessage> list) async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        await f.create(recursive: true);
      }
      // cap to avoid unbounded growth
      final max = 500;
      final slice = list.length > max ? list.sublist(list.length - max) : list;
      await f.writeAsString(jsonEncode(slice.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        await f.writeAsString('[]');
      }
    } catch (_) {}
  }
}

