import 'dart:convert';
import 'dart:io';

import 'package:proxypin/network/util/logger.dart';

import 'ai_settings.dart';

class AIMessage {
  final String role; // system, user, assistant, tool
  final String content;
  final String? name; // tool name for tool message
  final String? toolCallId;
  final List<Map<String, dynamic>>? toolCalls; // for assistant messages with tool_calls

  AIMessage(this.role, this.content, {this.name, this.toolCallId, this.toolCalls});

  factory AIMessage.fromJson(Map<String, dynamic> json) {
    return AIMessage(
      json['role'] as String? ?? '',
      json['content'] as String? ?? '',
      name: json['name'] as String?,
      toolCallId: json['tool_call_id'] as String?,
      toolCalls: (json['tool_calls'] as List?)
          ?.map((e) => (e as Map).cast<String, dynamic>())
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        if (name != null) 'name': name,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolCalls != null) 'tool_calls': toolCalls,
        'content': content,
      };
}

class AIToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> jsonSchema;

  AIToolSpec(this.name, this.description, this.jsonSchema);

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': jsonSchema,
        }
      };
}

class AIClient {
  final AISettings settings;

  AIClient(this.settings);

  Uri _buildUri(String path) {
    final base = settings.baseUrl.endsWith('/')
        ? settings.baseUrl.substring(0, settings.baseUrl.length - 1)
        : settings.baseUrl;
    return Uri.parse('$base$path');
  }

  // Sanitize and normalize message payloads to maximize compatibility
  Map<String, dynamic>? _messageToJson(AIMessage m) {
    final role = m.role.trim();
    // Drop malformed tool messages missing required tool_call_id
    if (role == 'tool' && (m.toolCallId == null || m.toolCallId!.trim().isEmpty)) {
      return null;
    }
    final map = <String, dynamic>{'role': role};
    if (m.name != null) map['name'] = m.name;
    if (m.toolCallId != null) map['tool_call_id'] = m.toolCallId;
    // Sanitize tool_calls for assistant messages
    List<Map<String, dynamic>>? toolCalls;
    if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
      toolCalls = m.toolCalls!
          .map((tc) {
            final id = (tc['id'] as String?)?.trim();
            final type = (tc['type'] as String?)?.trim();
            final fn = (tc['function'] as Map?)?.cast<String, dynamic>();
            final name = (fn?['name'] as String?)?.trim();
            final args = fn?['arguments'];
            if (id == null || id.isEmpty || type != 'function' || name == null || name.isEmpty) {
              return null;
            }
            return {
              'id': id,
              'type': 'function',
              'function': {
                'name': name,
                'arguments': args is String || args is Map<String, dynamic> ? args : (args?.toString() ?? ''),
              },
            };
          })
          .whereType<Map<String, dynamic>>()
          .toList();
      if (toolCalls.isNotEmpty) {
        map['tool_calls'] = toolCalls;
      }
    }
    // Content field: keep as string; empty allowed for tool/assistant-with-tool_calls
    map['content'] = m.content;
    return map;
  }

  Future<Map<String, dynamic>> chat({
    required List<AIMessage> messages,
    List<AIToolSpec>? tools,
    bool stream = false,
    double temperature = 0.2,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(_buildUri('/chat/completions'));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      // Expect JSON response for non-stream requests
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (settings.apiKey.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${settings.apiKey}');
      }
      // Build a minimal, widely-compatible OpenAI-compatible request body
      final body = <String, dynamic>{
        'model': settings.model,
        'messages': messages.map(_messageToJson).whereType<Map<String, dynamic>>().toList(),
        // Many backends default to auto tool selection; omit tool_choice to avoid schema mismatches
        if (settings.enableTools && tools != null && tools.isNotEmpty)
          'tools': tools.map((t) => t.toJson()).toList(),
        'temperature': temperature,
        if (stream) 'stream': true,
      };
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('AI HTTP ${resp.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } catch (e, t) {
      logger.e('AI chat request failed', error: e, stackTrace: t);
      rethrow;
    } finally {
      client.close();
    }
  }

  // Stream assistant content deltas (text only). Tool-call streaming is not handled here.
  Stream<String> chatStream({
    required List<AIMessage> messages,
    List<AIToolSpec>? tools,
    double temperature = 0.2,
  }) async* {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(_buildUri('/chat/completions'));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (settings.apiKey.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${settings.apiKey}');
      }
      final body = <String, dynamic>{
        'model': settings.model,
        'messages': messages.map(_messageToJson).whereType<Map<String, dynamic>>().toList(),
        if (settings.enableTools && tools != null && tools.isNotEmpty)
          'tools': tools.map((t) => t.toJson()).toList(),
        'temperature': temperature,
        'stream': true,
      };
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final text = await resp.transform(utf8.decoder).join();
        throw HttpException('AI HTTP ${resp.statusCode}: $text');
      }
      await for (final line in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (!t.startsWith('data:')) continue;
        final payload = t.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
          final piece = delta?['content'];
          if (piece is String && piece.isNotEmpty) {
            yield piece;
          }
        } catch (_) {
          // ignore malformed lines
        }
      }
    } catch (e, t) {
      logger.e('AI chat stream failed', error: e, stackTrace: t);
      rethrow;
    } finally {
      client.close();
    }
  }

  // Raw streaming of each SSE JSON chunk (already parsed).
  Stream<Map<String, dynamic>> chatStreamRaw({
    required List<AIMessage> messages,
    List<AIToolSpec>? tools,
    double temperature = 0.2,
  }) async* {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(_buildUri('/chat/completions'));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      // Explicitly request SSE for raw streaming
      req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (settings.apiKey.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${settings.apiKey}');
      }
      final body = <String, dynamic>{
        'model': settings.model,
        'messages': messages.map(_messageToJson).whereType<Map<String, dynamic>>().toList(),
        if (settings.enableTools && tools != null && tools.isNotEmpty)
          'tools': tools.map((t) => t.toJson()).toList(),
        'temperature': temperature,
        'stream': true,
      };
      req.add(utf8.encode(jsonEncode(body)));
      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final text = await resp.transform(utf8.decoder).join();
        throw HttpException('AI HTTP ${resp.statusCode}: $text');
      }
      await for (final line in resp.transform(utf8.decoder).transform(const LineSplitter())) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (!t.startsWith('data:')) continue;
        final payload = t.substring(5).trim();
        if (payload == '[DONE]') break;
        try {
          final json = jsonDecode(payload) as Map<String, dynamic>;
          yield json;
        } catch (_) {
          // ignore malformed lines
        }
      }
    } catch (e, t) {
      logger.e('AI chat raw stream failed', error: e, stackTrace: t);
      rethrow;
    } finally {
      client.close();
    }
  }
}
