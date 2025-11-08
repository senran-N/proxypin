import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_toastr/flutter_toastr.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:proxypin/ai/ai_client.dart';
import 'package:proxypin/ai/ai_settings.dart';
import 'package:proxypin/ai/ai_tools.dart';
import 'package:proxypin/network/bin/configuration.dart';
import 'package:proxypin/network/bin/server.dart';
import 'package:proxypin/network/channel/host_port.dart';
import 'package:proxypin/network/components/host_filter.dart';
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/network/http/http_client.dart';
import 'package:proxypin/network/http/websocket.dart';
import 'package:proxypin/ui/component/model/search_model.dart';
import 'package:proxypin/ui/content/panel.dart';
// Decouple from specific UI list states by passing a getter
import 'package:proxypin/utils/har.dart';

class AIChatPage extends StatefulWidget {
  final ProxyServer proxyServer;
  // Getter that returns the current view of requests (filtered list)
  final List<HttpRequest> Function()? getCurrentView;
  // Getter that returns all requests (unfiltered)
  final List<HttpRequest> Function()? getAllRequests;

  const AIChatPage({super.key, required this.proxyServer, required this.getCurrentView, this.getAllRequests});

  @override
  State<AIChatPage> createState() => _AIChatPageState();
}

class _AIChatPageState extends State<AIChatPage> with TickerProviderStateMixin {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<AIMessage> _history = [];
  AISettings _settings = AISettings();
  bool _sending = false;

  // Throttling for stream updates
  DateTime _lastUpdateTime = DateTime.now();
  static const _updateThrottleDuration = Duration(milliseconds: 50);
  bool _hasScheduledUpdate = false;

  @override
  void initState() {
    super.initState();
    AISettings.instance.then((s) => mounted ? setState(() => _settings = s) : null);
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // Throttled setState for stream updates
  void _throttledSetState(VoidCallback fn) {
    final now = DateTime.now();
    final timeSinceLastUpdate = now.difference(_lastUpdateTime);

    if (timeSinceLastUpdate >= _updateThrottleDuration) {
      _lastUpdateTime = now;
      if (mounted) setState(fn);
    } else if (!_hasScheduledUpdate) {
      _hasScheduledUpdate = true;
      final delay = _updateThrottleDuration - timeSinceLastUpdate;
      Future.delayed(delay, () {
        _hasScheduledUpdate = false;
        _lastUpdateTime = DateTime.now();
        if (mounted) setState(fn);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: theme.colorScheme.surface,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primary,
                    theme.colorScheme.secondary,
                  ],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.psychology_outlined,
                size: 20,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'AI Assistant',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                Text(
                  _sending ? '正在思考...' : '智能网络助手',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // 清空对话按钮
          if (_history.isNotEmpty)
            IconButton(
              tooltip: '清空对话',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: const Text('清空对话'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  setState(() => _history.clear());
                }
              },
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          // 设置按钮
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // 消息列表
          Expanded(
            child: _history.isEmpty
                ? _EmptyStateWidget(theme: theme)
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    itemCount: _history.length,
                    // Optimize performance with cacheExtent
                    cacheExtent: 500,
                    itemBuilder: (context, index) {
                      final m = _history[index];
                      final isUser = m.role == 'user';
                      // Distinguish tool-call messages from normal chat
                      if (m.role == 'tool') {
                        return RepaintBoundary(
                          child: _AnimatedMessageEntry(
                            key: ValueKey('tool-$index'),
                            index: index,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                              child: _ToolCallBubble(content: m.content),
                            ),
                          ),
                        );
                      }
                      return RepaintBoundary(
                        child: _AnimatedMessageEntry(
                          key: ValueKey('msg-$index-${m.role}'),
                          index: index,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: isUser
                                        ? theme.colorScheme.primary.withOpacity(0.1)
                                        : theme.colorScheme.secondary.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    isUser ? Icons.person_outline : Icons.smart_toy_outlined,
                                    color: isUser ? theme.colorScheme.primary : theme.colorScheme.secondary,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: _MessageBubble(
                                    content: m.content,
                                    isUser: isUser,
                                    theme: theme,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: theme.shadowColor.withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: theme.dividerColor.withOpacity(0.1),
                          width: 1,
                        ),
                      ),
                      child: TextField(
                        controller: _inputCtrl,
                        minLines: 1,
                        maxLines: 6,
                        decoration: InputDecoration(
                          hintText: '和 AI 对话，描述你的需求…',
                          hintStyle: TextStyle(
                            color: theme.colorScheme.onSurface.withOpacity(0.5),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 发送按钮
                  Container(
                    decoration: BoxDecoration(
                      gradient: _sending
                          ? null
                          : LinearGradient(
                              colors: [
                                theme.colorScheme.primary,
                                theme.colorScheme.secondary,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                      color: _sending ? theme.colorScheme.surfaceVariant : null,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: _sending
                          ? null
                          : [
                              BoxShadow(
                                color: theme.colorScheme.primary.withOpacity(0.3),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                    child: IconButton(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  theme.colorScheme.onSurface.withOpacity(0.5),
                                ),
                              ),
                            )
                          : const Icon(Icons.send_rounded, size: 20, color: Colors.white),
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final s = await AISettings.instance;
    final baseUrlCtrl = TextEditingController(text: s.baseUrl);
    final apiCtrl = TextEditingController(text: s.apiKey);
    final modelCtrl = TextEditingController(text: s.model);
    bool tools = s.enableTools;
    final maxItemsCtrl = TextEditingController(text: s.maxContextItems.toString());

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.settings,
                size: 20,
                color: Theme.of(ctx).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            const Text('AI 设置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SettingField(
                  label: 'Base URL',
                  icon: Icons.link,
                  child: TextField(
                    controller: baseUrlCtrl,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _SettingField(
                  label: 'API Key',
                  icon: Icons.key,
                  child: TextField(
                    controller: apiCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _SettingField(
                  label: 'Model',
                  icon: Icons.memory,
                  child: TextField(
                    controller: modelCtrl,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.build, size: 20, color: Theme.of(ctx).colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '启用工具调用',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: Theme.of(ctx).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      StatefulBuilder(
                        builder: (context, setState) => Switch(
                          value: tools,
                          onChanged: (v) => setState(() => tools = v),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _SettingField(
                  label: '上下文最大条数',
                  icon: Icons.format_list_numbered,
                  child: TextField(
                    controller: maxItemsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok == true) {
      s.baseUrl = baseUrlCtrl.text.trim();
      s.apiKey = apiCtrl.text.trim();
      s.model = modelCtrl.text.trim();
      s.enableTools = tools;
      s.maxContextItems = int.tryParse(maxItemsCtrl.text.trim()) ?? 20;
      await s.save();
      if (mounted) FlutterToastr.show('已保存', context, duration: 2);
      setState(() => _settings = s);
    }
  }

  // Removed: _attachCurrentView and _attachSelected

  Future<void> _send() async {
    final content = _inputCtrl.text.trim();
    if (content.isEmpty) return;
    setState(() {
      _history.add(AIMessage('user', content));
      _sending = true;
    });
    _inputCtrl.clear();
    _autoScrollToBottom();

    final system = AIMessage('system', _systemPrompt());
    try {
      await _chatLoop(system);
    } catch (e) {
      setState(() => _history.add(AIMessage('assistant', '出错了：$e')));
    } finally {
      setState(() => _sending = false);
      // Final scroll to bottom after completion
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _autoScrollToBottom();
    }
  }

  String _systemPrompt() {
    final maxItems = _settings.maxContextItems;
    return '''
You are an on-device assistant integrated with a network proxy tool (ProxyPin). Act with strict data minimization and explicit user intent.

Core Rules
- Only access data that is explicitly requested or strictly necessary to answer the current question. If the user’s ask is vague, ask for filters first (keyword, time window, method, status, ids).
- Always minimize context. Default to at most $maxItems items and avoid long bodies. Never dump full traffic or entire bodies unless the user clearly asks.
- Prefer structured, concise answers. Lead with the result; avoid repetition and boilerplate.

Tool Usage Policy
- Discovery/filtering: use get_traffic, search_traffic, list_requests with an explicit 'limit' (<= $maxItems). Prefer metadata over content.
- Field access: use get_fields for headers/cookies/basic body excerpts. For body content, prefer get_body_range or extract_json with a precise path. Do not read entire bodies if a slice or field suffices.
- Aggregation: use aggregate_traffic for stats instead of scanning many items.
- WebSocket: use get_ws_messages with a small 'limit'.
- Mutations (add_script, add_rewrite_rule, update_filters, set_config, replay_request):
  1) Explain the minimal plan and ask for confirmation unless the user explicitly requested the change.
  2) Make the smallest safe change. Avoid broad patterns and global effects.

Rewrite Rules (Very Important)
- Only modify the original message body. Do NOT invent a whole new body. Prefer update rules: type = requestUpdate/responseUpdate with items.type = updateBody using a precise regex 'key' and a 'value' replacement.
- When the user provides the original body text, derive a minimal regex from the exact snippet to change (escape special chars) and set 'value' to the updated snippet.
- Headers: use updateHeader with a specific '^Header-Name:.*\$' key and 'Header-Name: new' value; use addHeader/removeHeader as needed. Avoid full header replacement unless explicitly asked.
- Status code: include it only when the user asks; provide 'statusCode' to enable it. It will be applied even in update mode.
- Idempotent: if a rule for the same url/type already exists, update it rather than creating duplicates.

Privacy & Safety
- Do not exfiltrate data. Do not access unrelated traffic. Redact secrets (tokens, cookies, passwords) unless the user explicitly asks to see them.
- Never include more than $maxItems items or large raw blobs. Summarize and provide request_id references for drill‑down on demand.

Output Style
- Chinese preferred. Keep it short: bullets or short paragraphs.
- Return only requested fields. If listing traffic, include: time, method, url, status, duration_ms, and request_id. Omit raw bodies by default.
- When bodies are necessary, show only the minimal slice and clearly mark truncation.

Operational Guidance
- After each tool call, reassess; do not chain unnecessary calls.
- If a call fails or a required field is missing, state what is needed and ask for a narrower filter or the exact request_id.
''';
  }

  Future<void> _chatLoop(AIMessage system) async {
    final client = AIClient(_settings);
    final tools = _settings.enableTools ? _toolSpecs() : null;
    final conv = <AIMessage>[system, ..._history];
    for (int step = 0; step < 8; step++) {
      if (_settings.enableTools) {
        // Prefer streaming with tools; fallback to non-stream (with tools), then without tools
        try {
          String streamed = '';
          final Map<int, Map<String, String>> pending = {};
          setState(() => _history.add(AIMessage('assistant', '')));
          final idxMsg = _history.length - 1;
          await for (final chunk in client.chatStreamRaw(messages: conv, tools: tools)) {
            final choices = chunk['choices'] as List?;
            if (choices == null || choices.isEmpty) continue;
            final choice = choices.first as Map<String, dynamic>;
            final delta = choice['delta'] as Map<String, dynamic>?;
            if (delta == null) continue;
            final piece = delta['content'];
            if (piece is String && piece.isNotEmpty) {
              streamed += piece;
              if (!mounted) break;
              _throttledSetState(() {
                if (_history.length > idxMsg) {
                  _history[idxMsg] = AIMessage('assistant', streamed);
                }
              });
              _autoScrollToBottom();
            }
            final toolDeltas = (delta['tool_calls'] as List?)?.cast<Map<String, dynamic>>();
            if (toolDeltas != null) {
              for (final td in toolDeltas) {
                final i = (td['index'] as int?) ?? 0;
                final map = pending.putIfAbsent(i, () => {'id': '', 'name': '', 'arguments': ''});
                final id = td['id'] as String?;
                if (id != null && id.isNotEmpty) map['id'] = id;
                final fn = td['function'] as Map<String, dynamic>?;
                if (fn != null) {
                  final nm = fn['name'] as String?;
                  if (nm != null && nm.isNotEmpty) map['name'] = nm;
                  final argsSeg = fn['arguments'] as String?;
                  if (argsSeg != null && argsSeg.isNotEmpty) map['arguments'] = (map['arguments'] ?? '') + argsSeg;
                }
              }
            }
          }
          if (mounted) {
            setState(() {
              if (_history.length > idxMsg) {
                _history[idxMsg] = AIMessage('assistant', streamed);
              }
            });
          }
          if (streamed.trim().isEmpty && mounted) {
            setState(() {
              if (_history.isNotEmpty && _history.length - 1 >= idxMsg) {
                _history.removeAt(idxMsg);
              }
            });
          }
          final toolCalls = <Map<String, dynamic>>[];
          final sorted = pending.keys.toList()..sort();
          for (final i in sorted) {
            final m = pending[i]!;
            toolCalls.add({
              'id': (m['id'] ?? '').isNotEmpty ? m['id'] : 'call_$i',
              'type': 'function',
              'function': {'name': m['name'] ?? '', 'arguments': m['arguments'] ?? ''},
            });
          }
          conv.add(AIMessage('assistant', streamed, toolCalls: toolCalls.isEmpty ? null : toolCalls));
          if (streamed.trim().isNotEmpty) {
            await _autoCreateScriptFromContent(streamed);
          }
          if (toolCalls.isEmpty) break;
          for (var i = 0; i < toolCalls.length; i++) {
            final tc = toolCalls[i];
            final fn = tc['function'] as Map<String, dynamic>;
            final name = fn['name'] as String? ?? '';
            final argsStr = fn['arguments'] as String? ?? '';
            Map<String, dynamic> args;
            try {
              args = jsonDecode(argsStr) as Map<String, dynamic>;
            } catch (_) {
              args = <String, dynamic>{};
            }
            setState(() => _history.add(AIMessage('tool', '调用工具: $name ${_shortArgs(args)}')));
            _autoScrollToBottom();
            final toolResp = await _handleToolCall(name, args);
            conv.add(AIMessage('tool', jsonEncode(toolResp), name: name, toolCallId: tc['id'] as String?));
          }
          continue; // next step
        } catch (e) {
          // fallthrough to non-stream
        }

        // Fallback 1: non-stream with tools
        try {
          final resp = await client.chat(messages: conv, tools: tools);
          final msg = (resp['choices'] as List).first['message'] as Map<String, dynamic>;
          final content = msg['content']?.toString();
          final toolCalls = (msg['tool_calls'] as List?)?.cast<Map<String, dynamic>>();
          if (content != null && content.trim().isNotEmpty) {
            setState(() => _history.add(AIMessage('assistant', content)));
            await _autoCreateScriptFromContent(content);
          }
          if (toolCalls == null || toolCalls.isEmpty) break;
          conv.add(AIMessage('assistant', content ?? '', toolCalls: toolCalls));
          for (final call in toolCalls) {
            final func = call['function'] as Map<String, dynamic>;
            final name = func['name'] as String? ?? '';
            final raw = func['arguments'];
            Map<String, dynamic> args;
            try {
              args = raw is String ? (jsonDecode(raw) as Map<String, dynamic>) : (raw as Map<String, dynamic>);
            } catch (_) {
              args = <String, dynamic>{};
            }
            setState(() => _history.add(AIMessage('tool', '调用工具: $name ${_shortArgs(args)}')));
            _autoScrollToBottom();
            final toolResp = await _handleToolCall(name, args);
            conv.add(AIMessage('tool', jsonEncode(toolResp), name: name, toolCallId: call['id'] as String?));
          }
          continue; // next step
        } catch (e) {
          // Fallback 2: non-stream without tools
          try {
            final resp = await client.chat(messages: conv, tools: null);
            final msg = (resp['choices'] as List).first['message'] as Map<String, dynamic>;
            final content = msg['content']?.toString();
            if (content != null && content.trim().isNotEmpty) {
              setState(() => _history.add(AIMessage('assistant', content)));
              await _autoCreateScriptFromContent(content);
            }
            break; // no tools to loop
          } catch (e) {
            setState(() => _history.add(AIMessage('assistant', '出错了：$e')));
            break;
          }
        }
      }

      // Tools disabled path
      try {
        String streamed = '';
        setState(() => _history.add(AIMessage('assistant', '')));
        final idx = _history.length - 1;
        await for (final delta in client.chatStream(messages: conv, tools: tools)) {
          streamed += delta;
          if (!mounted) break;
          _throttledSetState(() {
            if (_history.length > idx) {
              _history[idx] = AIMessage('assistant', streamed);
            }
          });
          _autoScrollToBottom();
        }
        if (mounted) {
          setState(() {
            if (_history.length > idx) {
              _history[idx] = AIMessage('assistant', streamed);
            }
          });
        }
        if (streamed.trim().isNotEmpty) {
          conv.add(AIMessage('assistant', streamed));
          await _autoCreateScriptFromContent(streamed);
        }
        break;
      } catch (e) {
        // Fallback: non-stream plain text
        try {
          final resp = await client.chat(messages: conv, tools: null);
          final msg = (resp['choices'] as List).first['message'] as Map<String, dynamic>;
          final content = msg['content']?.toString();
          if (content != null && content.trim().isNotEmpty) {
            setState(() => _history.add(AIMessage('assistant', content)));
            await _autoCreateScriptFromContent(content);
          }
        } catch (e) {
          setState(() => _history.add(AIMessage('assistant', '出错了：$e')));
        }
        break;
      }
    }
  }

  // Smooth auto-scroll to bottom
  void _autoScrollToBottom() {
    if (_scrollCtrl.hasClients) {
      Future.microtask(() {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
          );
        }
      });
    }
  }

  String _shortArgs(Map<String, dynamic> args) {
    try {
      final s = jsonEncode(args);
      if (s.length <= 80) return s;
      return s.substring(0, 77) + '...';
    } catch (_) {
      return '';
    }
  }

  Future<void> _autoCreateScriptFromContent(String content) async {
    // Auto-create script when the assistant returns a JS code block
    final reg = RegExp(r"```(\\w+)?\n([\s\S]*?)```", multiLine: true);
    final m = reg.firstMatch(content);
    if (m == null) return;
    final lang = (m.group(1) ?? '').toLowerCase();
    if (!(lang == 'js' || lang == 'javascript')) return;
    final code = m.group(2) ?? '';
    final urls = (NetworkTabController.current?.request.get()?.domainPath ?? '*');
    try {
      await AITools.addScript(name: 'AI Script', urls: urls.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(), script: code);
      if (mounted) {
        setState(() => _history.add(AIMessage('tool', '已自动创建脚本: AI Script @ $urls')));
        FlutterToastr.show('脚本已自动创建', context, duration: 2);
      }
    } catch (e) {
      if (mounted) setState(() => _history.add(AIMessage('tool', '创建脚本失败: $e')));
    }
  }

  List<AIToolSpec> _toolSpecs() {
    return [
      AIToolSpec('get_traffic', 'Get summarized traffic entries with optional filters', {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string'},
          'method': {'type': 'string', 'enum': HttpMethod.values.map((e) => e.name).toList()},
          'search_in': {
            'type': 'array',
            'items': {'type': 'string', 'enum': ['url', 'method', 'request_header', 'response_header', 'request_body', 'response_body', 'response_content_type']}
          },
          'status_from': {'type': 'integer'},
          'status_to': {'type': 'integer'},
          'duration_from_ms': {'type': 'integer'},
          'duration_to_ms': {'type': 'integer'},
          'limit': {'type': 'integer', 'default': 20},
          'source': {'type': 'string', 'enum': ['current', 'all'], 'default': 'current'}
        }
      }),
      AIToolSpec('search_traffic', 'Search traffic by conditions and return summarized items with request ids', {
        'type': 'object',
        'properties': {
          'keyword': {'type': 'string'},
          'method': {'type': 'string', 'enum': HttpMethod.values.map((e) => e.name).toList()},
          'search_in': {
            'type': 'array',
            'items': {'type': 'string', 'enum': ['url', 'method', 'request_header', 'response_header', 'request_body', 'response_body', 'response_content_type']}
          },
          'status_from': {'type': 'integer'},
          'status_to': {'type': 'integer'},
          'duration_from_ms': {'type': 'integer'},
          'duration_to_ms': {'type': 'integer'},
          'limit': {'type': 'integer', 'default': 50},
          'source': {'type': 'string', 'enum': ['current', 'all'], 'default': 'current'}
        }
      }),
      AIToolSpec('get_selection', 'Get current selected request/response', {
        'type': 'object',
        'properties': {'include_body': {'type': 'boolean', 'default': false}, 'max_chars': {'type': 'integer', 'default': 5000}}
      }),
      AIToolSpec('get_request_by_id', 'Get request by id', {
        'type': 'object',
        'required': ['request_id'],
        'properties': {'request_id': {'type': 'string'}, 'include_body': {'type': 'boolean', 'default': false}, 'max_chars': {'type': 'integer', 'default': 5000}}
      }),
      AIToolSpec('get_body', 'Get body of request/response', {
        'type': 'object',
        'properties': {'request_id': {'type': 'string'}, 'target': {'type': 'string', 'enum': ['request', 'response'], 'default': 'response'}, 'max_chars': {'type': 'integer', 'default': 20000}}
      }),
      AIToolSpec('get_fields', 'Retrieve specific fields (body/cookies/headers/... combinations)', {
        'type': 'object',
        'required': ['parts'],
        'properties': {'request_id': {'type': 'string'}, 'parts': {'type': 'array', 'items': {'type': 'string'}}, 'max_chars': {'type': 'integer', 'default': 5000}}
      }),
      AIToolSpec('bulk_get_fields', 'Batch get fields for multiple ids', {
        'type': 'object',
        'required': ['request_ids', 'parts'],
        'properties': {'request_ids': {'type': 'array', 'items': {'type': 'string'}}, 'parts': {'type': 'array', 'items': {'type': 'string'}}, 'max_chars': {'type': 'integer', 'default': 3000}}
      }),
      AIToolSpec('list_requests', 'List recent requests metadata with paging', {
        'type': 'object',
        'properties': {'limit': {'type': 'integer', 'default': 50}, 'start_after_id': {'type': 'string'}}
      }),
      AIToolSpec('get_body_range', 'Get slice of body by char/byte range', {
        'type': 'object',
        'properties': {'request_id': {'type': 'string'}, 'target': {'type': 'string', 'enum': ['request', 'response'], 'default': 'response'}, 'unit': {'type': 'string', 'enum': ['char', 'byte'], 'default': 'char'}, 'offset': {'type': 'integer', 'default': 0}, 'length': {'type': 'integer', 'default': 2000}}
      }),
      AIToolSpec('extract_json', 'Extract value from JSON body using dotted path like \$.a.b[0].c', {
        'type': 'object',
        'required': ['path'],
        'properties': {'request_id': {'type': 'string'}, 'target': {'type': 'string', 'enum': ['request', 'response'], 'default': 'response'}, 'path': {'type': 'string'}}
      }),
      AIToolSpec('aggregate_traffic', 'Aggregate traffic by fields', {
        'type': 'object',
        'properties': {
          'group_by': {'type': 'array', 'items': {'type': 'string', 'enum': ['host', 'path', 'status', 'method', 'content_type']}},
          'metric': {'type': 'string', 'enum': ['count', 'avg_duration', 'p95_duration'], 'default': 'count'},
          'keyword': {'type': 'string'},
          'method': {'type': 'string', 'enum': HttpMethod.values.map((e) => e.name).toList()},
          'status_from': {'type': 'integer'},
          'status_to': {'type': 'integer'},
          'duration_from_ms': {'type': 'integer'},
          'duration_to_ms': {'type': 'integer'},
          'limit': {'type': 'integer', 'default': 500},
          'source': {'type': 'string', 'enum': ['current', 'all'], 'default': 'current'}
        }
      }),
      AIToolSpec('get_ws_messages', 'Get recent WebSocket messages', {
        'type': 'object',
        'properties': {'request_id': {'type': 'string'}, 'limit': {'type': 'integer', 'default': 50}, 'direction': {'type': 'string', 'enum': ['any', 'client', 'server'], 'default': 'any'}}
      }),
      AIToolSpec('export_har', 'Export filtered traffic as HAR JSON string', {
        'type': 'object',
        'properties': {'keyword': {'type': 'string'}, 'method': {'type': 'string', 'enum': HttpMethod.values.map((e) => e.name).toList()}, 'status_from': {'type': 'integer'}, 'status_to': {'type': 'integer'}, 'duration_from_ms': {'type': 'integer'}, 'duration_to_ms': {'type': 'integer'}, 'limit': {'type': 'integer', 'default': 100}, 'source': {'type': 'string', 'enum': ['current', 'all'], 'default': 'current'}}
      }),
      AIToolSpec('get_config', 'Get proxy/config info', {'type': 'object', 'properties': {}}),
      AIToolSpec('set_config', 'Set basic proxy config', {
        'type': 'object',
        'properties': {'enable_ssl': {'type': 'boolean'}, 'enabled_http2': {'type': 'boolean'}}
      }),
      AIToolSpec('update_filters', 'Update host whitelist/blacklist', {
        'type': 'object',
        'properties': {
          'whitelist_enabled': {'type': 'boolean'},
          'blacklist_enabled': {'type': 'boolean'},
          'add_whitelist': {'type': 'array', 'items': {'type': 'string'}},
          'remove_whitelist': {'type': 'array', 'items': {'type': 'string'}},
          'add_blacklist': {'type': 'array', 'items': {'type': 'string'}},
          'remove_blacklist': {'type': 'array', 'items': {'type': 'string'}}
        }
      }),
      AIToolSpec('list_rewrite_rules', 'List all rewrite rules', {'type': 'object', 'properties': {}}),
      AIToolSpec('add_rewrite_rule', 'Add a rewrite rule with items', {
        'type': 'object',
        'required': ['url_pattern', 'items'],
        'properties': {
          'url_pattern': {'type': 'string'},
          'type': {
            'type': 'string',
            'enum': RuleType.values.map((e) => e.name).toList(),
            'default': 'responseUpdate'
          },
          'name': {'type': 'string'},
          'enabled': {'type': 'boolean', 'default': true},
          'items': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['type'],
              'properties': {
                'enabled': {'type': 'boolean', 'default': true},
                'type': {
                  'type': 'string',
                  'enum': RewriteType.values.map((e) => e.name).toList()
                },
                'values': {
                  'type': 'object',
                  'properties': {
                    'key': {'type': 'string'},
                    'value': {'type': 'string'},
                    'redirectUrl': {'type': 'string'},
                    'method': {
                      'type': 'string',
                      'enum': HttpMethod.values.map((e) => e.name).toList()
                    },
                    'path': {'type': 'string'},
                    'queryParam': {'type': 'string'},
                    'statusCode': {'type': 'integer'},
                    'headers': {
                      'type': 'object',
                      'additionalProperties': {'type': 'string'}
                    },
                    'body': {'type': 'string'},
                    'bodyType': {'type': 'string', 'enum': ['text', 'file']},
                    'bodyFile': {'type': 'string'}
                  }
                }
              }
            }
          }
        }
      }),
      AIToolSpec('remove_rewrite_rule', 'Remove rewrite rule', {
        'type': 'object',
        'required': ['url_pattern', 'type'],
        'properties': {
          'url_pattern': {'type': 'string'},
          'type': {
            'type': 'string',
            'enum': RuleType.values.map((e) => e.name).toList()
          }
        }
      }),
      AIToolSpec('set_rewrite_enabled', 'Enable/disable request rewrite', {
        'type': 'object',
        'required': ['enabled'],
        'properties': {'enabled': {'type': 'boolean'}}
      }),
      AIToolSpec('list_scripts', 'List scripts', {
        'type': 'object',
        'properties': {'include_content': {'type': 'boolean', 'default': false}}
      }),
      AIToolSpec('add_script', 'Add JavaScript with name/urls/content', {
        'type': 'object',
        'required': ['name', 'urls', 'script'],
        'properties': {'name': {'type': 'string'}, 'urls': {'type': 'array', 'items': {'type': 'string'}}, 'script': {'type': 'string'}}
      }),
      AIToolSpec('update_script', 'Update script', {
        'type': 'object',
        'required': ['name'],
        'properties': {'name': {'type': 'string'}, 'urls': {'type': 'array', 'items': {'type': 'string'}}, 'script': {'type': 'string'}, 'enabled': {'type': 'boolean'}}
      }),
      AIToolSpec('remove_script', 'Remove script by name', {
        'type': 'object',
        'required': ['name'],
        'properties': {'name': {'type': 'string'}}
      }),
      AIToolSpec('set_script_enabled', 'Enable/disable scripts globally', {
        'type': 'object',
        'required': ['enabled'],
        'properties': {'enabled': {'type': 'boolean'}}
      }),
      AIToolSpec('replay_request', 'Replay a request by id', {
        'type': 'object',
        'required': ['request_id'],
        'properties': {'request_id': {'type': 'string'}}
      }),
      AIToolSpec('get_script_template', 'Get default JS template', {'type': 'object', 'properties': {}}),
    ];
  }

  Future<Map<String, dynamic>> _handleToolCall(String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'get_traffic':
      case 'search_traffic':
        var limit = (args['limit'] ?? (name == 'get_traffic' ? 20 : 50)) as int;
        limit = math.min(limit, _settings.maxContextItems);
        final source = (args['source'] ?? 'current') as String;
        final method = args['method'] as String?;
        final statusFrom = args['status_from'] as int?;
        final statusTo = args['status_to'] as int?;
        final durationFrom = args['duration_from_ms'] as int?;
        final durationTo = args['duration_to_ms'] as int?;
        final keyword = args['keyword'] as String?;
        final searchIn = (args['search_in'] as List?)?.cast<String>();
        final list = source == 'all' ? _allRequests() : (widget.getCurrentView?.call() ?? <HttpRequest>[]);
        var search = SearchModel(keyword);
        if (method != null) search.requestMethod = HttpMethod.values.firstWhere((e) => e.name == method, orElse: () => HttpMethod.get);
        search.statusCodeFrom = statusFrom;
        search.statusCodeTo = statusTo;
        search.durationFromMs = durationFrom;
        search.durationToMs = durationTo;
        if (searchIn != null && searchIn.isNotEmpty) search.searchOptions = _mapSearchOptions(searchIn);
        final filtered = AITools.applySearch(list, search);
        final items = AITools.summarize(filtered, limit: limit);
        return {'ok': true, 'items': items.map((e) => e.toJson()).toList(), 'count': items.length, 'request_ids': filtered.take(items.length).map((e) => e.requestId).toList()};
      case 'get_selection':
        final includeBody = (args['include_body'] ?? false) as bool;
        final maxChars = (args['max_chars'] ?? 5000) as int;
        final req = NetworkTabController.current?.request.get();
        final res = NetworkTabController.current?.response.get() ?? req?.response;
        if (req == null && res?.request == null) return {'ok': false, 'error': 'no selection'};
        final r = req ?? res!.request!;
        return {'ok': true, 'request': await _httpRequestToJson(r, includeBody: includeBody, maxChars: maxChars), 'response': res == null ? null : await _httpResponseToJson(res, includeBody: includeBody, maxChars: maxChars)};
      case 'get_request_by_id':
        final id = args['request_id'] as String;
        final includeBody = (args['include_body'] ?? false) as bool;
        final maxChars = (args['max_chars'] ?? 5000) as int;
        final r = _findRequestById(id);
        if (r == null) return {'ok': false, 'error': 'not found'};
        return {'ok': true, 'request': await _httpRequestToJson(r, includeBody: includeBody, maxChars: maxChars), 'response': r.response == null ? null : await _httpResponseToJson(r.response!, includeBody: includeBody, maxChars: maxChars)};
      case 'get_body':
        final id = args['request_id'] as String?;
        final which = (args['target'] ?? 'response') as String;
        final maxChars = (args['max_chars'] ?? 20000) as int;
        HttpRequest? r = id == null ? NetworkTabController.current?.request.get() : _findRequestById(id);
        if (r == null) return {'ok': false, 'error': 'no request'};
        if (which == 'request') {
          final text = await r.decodeBodyString();
          return {'ok': true, 'length': text.length, 'content': text.substring(0, text.length > maxChars ? maxChars : text.length)};
        } else {
          final resp = r.response ?? NetworkTabController.current?.response.get();
          if (resp == null) return {'ok': false, 'error': 'no response'};
          final text = await resp.decodeBodyString();
          return {'ok': true, 'length': text.length, 'content': text.substring(0, text.length > maxChars ? maxChars : text.length)};
        }
      case 'get_fields':
        final id = args['request_id'] as String?;
        final parts = (args['parts'] as List).cast<String>();
        final maxChars = (args['max_chars'] ?? 5000) as int;
        HttpRequest? r = id == null ? NetworkTabController.current?.request.get() : _findRequestById(id);
        if (r == null) return {'ok': false, 'error': 'no request'};
        final resp = r.response ?? NetworkTabController.current?.response.get();
        final out = await _pickFields(r, resp, parts, maxChars);
        return {'ok': true, 'fields': out};
      case 'bulk_get_fields':
        final ids = (args['request_ids'] as List).cast<String>();
        final parts = (args['parts'] as List).cast<String>();
        final maxChars = (args['max_chars'] ?? 3000) as int;
        final map = <String, dynamic>{};
        for (final id in ids) {
          final r = _findRequestById(id);
          if (r == null) { map[id] = {'ok': false, 'error': 'not found'}; continue; }
          final out = await _pickFields(r, r.response, parts, maxChars);
          map[id] = {'ok': true, 'fields': out};
        }
        return {'ok': true, 'results': map};
      case 'list_requests':
        var limit = (args['limit'] ?? 50) as int;
        limit = math.min(limit, _settings.maxContextItems);
        final after = args['start_after_id'] as String?;
        final all = _allRequests();
        int start = 0;
        if (after != null) { final idx = all.indexWhere((e) => e.requestId == after); if (idx >= 0) start = idx + 1; }
        final slice = all.sublist(start, (start + limit) > all.length ? all.length : (start + limit));
        final list = slice.map((r) => {'request_id': r.requestId, 'time': r.requestTime.toIso8601String(), 'method': r.method.name, 'url': r.requestUrl, 'status': r.response?.status.code, 'duration_ms': r.response == null ? null : r.response!.responseTime.difference(r.requestTime).inMilliseconds}).toList();
        return {'ok': true, 'items': list, 'next_after_id': slice.isEmpty ? null : slice.last.requestId};
      case 'get_body_range':
        final id = args['request_id'] as String?;
        final target = (args['target'] ?? 'response') as String;
        final unit = (args['unit'] ?? 'char') as String;
        final offset = (args['offset'] ?? 0) as int;
        final length = (args['length'] ?? 2000) as int;
        HttpRequest? r = id == null ? NetworkTabController.current?.request.get() : _findRequestById(id);
        if (r == null) return {'ok': false, 'error': 'no request'};
        if (target == 'request') {
          if (unit == 'char') { final s = await r.decodeBodyString(); final end = (offset + length) > s.length ? s.length : (offset + length); return {'ok': true, 'content': s.substring(offset.clamp(0, s.length), end)}; }
          final b = r.body ?? []; final end = (offset + length) > b.length ? b.length : (offset + length); final slice = b.sublist(offset.clamp(0, b.length), end); return {'ok': true, 'base64': base64Encode(slice), 'length': slice.length};
        } else {
          final resp = r.response ?? NetworkTabController.current?.response.get(); if (resp == null) return {'ok': false, 'error': 'no response'};
          if (unit == 'char') { final s = await resp.decodeBodyString(); final end = (offset + length) > s.length ? s.length : (offset + length); return {'ok': true, 'content': s.substring(offset.clamp(0, s.length), end)}; }
          final b = resp.body ?? []; final end = (offset + length) > b.length ? b.length : (offset + length); final slice = b.sublist(offset.clamp(0, b.length), end); return {'ok': true, 'base64': base64Encode(slice), 'length': slice.length};
        }
      case 'extract_json':
        final id = args['request_id'] as String?;
        final target = (args['target'] ?? 'response') as String;
        final path = (args['path'] as String).trim();
        HttpRequest? r = id == null ? NetworkTabController.current?.request.get() : _findRequestById(id);
        if (r == null) return {'ok': false, 'error': 'no request'};
        String text;
        if (target == 'request') { text = await r.decodeBodyString(); } else { final resp = r.response ?? NetworkTabController.current?.response.get(); if (resp == null) return {'ok': false, 'error': 'no response'}; text = await resp.decodeBodyString(); }
        try { final data = jsonDecode(text); final val = _jsonPathEval(data, path); return {'ok': true, 'value': val}; } catch (e) { return {'ok': false, 'error': e.toString()}; }
      case 'aggregate_traffic':
        final groupBy = (args['group_by'] as List?)?.cast<String>() ?? <String>[];
        final metric = (args['metric'] ?? 'count') as String;
        var limit = (args['limit'] ?? 500) as int;
        limit = math.min(limit, _settings.maxContextItems);
        final source = (args['source'] ?? 'current') as String;
        final method = args['method'] as String?;
        final statusFrom = args['status_from'] as int?;
        final statusTo = args['status_to'] as int?;
        final durationFrom = args['duration_from_ms'] as int?;
        final durationTo = args['duration_to_ms'] as int?;
        final keyword = args['keyword'] as String?;
        final list = source == 'all'
            ? _allRequests()
            : (widget.getCurrentView?.call() ?? <HttpRequest>[]);
        var search = SearchModel(keyword);
        if (method != null) search.requestMethod = HttpMethod.values.firstWhere((e) => e.name == method, orElse: () => HttpMethod.get);
        search.statusCodeFrom = statusFrom;
        search.statusCodeTo = statusTo;
        search.durationFromMs = durationFrom;
        search.durationToMs = durationTo;
        final filtered = AITools.applySearch(list, search).take(limit).toList();
        final agg = _aggregate(filtered, groupBy, metric);
        return {'ok': true, 'groups': agg};
      case 'get_ws_messages':
        final id = args['request_id'] as String?;
        var limit = (args['limit'] ?? 50) as int;
        limit = math.min(limit, _settings.maxContextItems);
        final direction = (args['direction'] ?? 'any') as String;
        HttpRequest? r = id == null ? NetworkTabController.current?.request.get() : _findRequestById(id);
        if (r == null) return {'ok': false, 'error': 'no request'};
        final frames = <WebSocketFrame>[];
        frames.addAll(r.messages);
        if (r.response != null) frames.addAll(r.response!.messages);
        frames.sort((a, b) => a.time.compareTo(b.time));
        final selected = <Map<String, dynamic>>[];
        for (final f in frames.reversed) {
          if (direction == 'client' && !f.isFromClient) continue;
          if (direction == 'server' && f.isFromClient) continue;
          selected.add({'time': f.time.toIso8601String(), 'from': f.isFromClient ? 'client' : 'server', 'type': f.isText ? 'text' : (f.isBinary ? 'binary' : 'ctrl'), 'length': f.payloadLength, 'text': f.isText ? f.payloadDataAsString : null});
          if (selected.length >= limit) break;
        }
        return {'ok': true, 'items': selected.reversed.toList()};
      case 'export_har':
        var limit = (args['limit'] ?? 100) as int;
        limit = math.min(limit, _settings.maxContextItems);
        final source = (args['source'] ?? 'current') as String;
        final method = args['method'] as String?;
        final statusFrom = args['status_from'] as int?;
        final statusTo = args['status_to'] as int?;
        final durationFrom = args['duration_from_ms'] as int?;
        final durationTo = args['duration_to_ms'] as int?;
        final keyword = args['keyword'] as String?;
        final list = source == 'all'
            ? _allRequests()
            : (widget.getCurrentView?.call() ?? <HttpRequest>[]);
        var search = SearchModel(keyword);
        if (method != null) search.requestMethod = HttpMethod.values.firstWhere((e) => e.name == method, orElse: () => HttpMethod.get);
        search.statusCodeFrom = statusFrom;
        search.statusCodeTo = statusTo;
        search.durationFromMs = durationFrom;
        search.durationToMs = durationTo;
        final filtered = AITools.applySearch(list, search).take(limit).toList();
        final har = await Har.writeJson(filtered, title: 'AI Export');
        return {'ok': true, 'har': har};
      case 'get_config':
        final cfg = await Configuration.instance;
        final rwm = await RequestRewriteManager.instance;
        final sm = await ScriptManager.instance;
        return {'ok': true, 'proxy': {'port': cfg.port, 'enable_ssl': cfg.enableSsl, 'enable_system_proxy': cfg.enableSystemProxy, 'enabled_http2': cfg.enabledHttp2}, 'filters': {'whitelist_enabled': HostFilter.whitelist.enabled, 'whitelist': HostFilter.whitelist.toJson()['list'], 'blacklist_enabled': HostFilter.blacklist.enabled, 'blacklist': HostFilter.blacklist.toJson()['list']}, 'rewrite': {'enabled': rwm.enabled, 'rule_count': rwm.rules.length}, 'scripts': {'enabled': sm.enabled, 'count': sm.list.length}};
      case 'set_config':
        final cfg = await Configuration.instance;
        if (args.containsKey('enable_ssl')) cfg.enableSsl = args['enable_ssl'] as bool;
        if (args.containsKey('enabled_http2')) cfg.enabledHttp2 = args['enabled_http2'] as bool;
        await cfg.flushConfig();
        return {'ok': true, 'port': cfg.port, 'enable_ssl': cfg.enableSsl, 'enabled_http2': cfg.enabledHttp2};
      case 'update_filters':
        final cfg = await Configuration.instance;
        final wEnabled = args['whitelist_enabled'] as bool?;
        final bEnabled = args['blacklist_enabled'] as bool?;
        final addW = (args['add_whitelist'] as List?)?.cast<String>() ?? [];
        final rmW = (args['remove_whitelist'] as List?)?.cast<String>() ?? [];
        final addB = (args['add_blacklist'] as List?)?.cast<String>() ?? [];
        final rmB = (args['remove_blacklist'] as List?)?.cast<String>() ?? [];
        if (wEnabled != null) HostFilter.whitelist.enabled = wEnabled;
        if (bEnabled != null) HostFilter.blacklist.enabled = bEnabled;
        for (final p in addW) HostFilter.whitelist.add(p);
        for (final p in rmW) HostFilter.whitelist.remove(p);
        for (final p in addB) HostFilter.blacklist.add(p);
        for (final p in rmB) HostFilter.blacklist.remove(p);
        await cfg.flushConfig();
        return {'ok': true, 'filters': {'whitelist_enabled': HostFilter.whitelist.enabled, 'whitelist': HostFilter.whitelist.toJson()['list'], 'blacklist_enabled': HostFilter.blacklist.enabled, 'blacklist': HostFilter.blacklist.toJson()['list']}};
      case 'list_rewrite_rules':
        final mgr = await RequestRewriteManager.instance;
        return {'ok': true, 'config': await mgr.toFullJson()};
      case 'add_rewrite_rule':
        final urlPattern = (args['url_pattern'] as String).trim();
        final typeStr = (args['type'] as String? ?? 'responseUpdate').trim();
        final ruleName = (args['name'] as String?)?.trim();
        final ruleEnabled = (args['enabled'] as bool?) ?? true;
        final itemsAny = (args['items'] as List?);
        if (urlPattern.isEmpty) return {'ok': false, 'error': 'url_pattern required'};
        if (itemsAny == null || itemsAny.isEmpty) return {'ok': false, 'error': 'items required'};
        var type = RuleType.fromName(typeStr.isEmpty ? 'responseUpdate' : typeStr);

        // Normalize items to expected {enabled, type, values:{...}} shape and expand convenience fields
        String _canonType(String s, RuleType ruleType) {
          final x = s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          // bool isResp = ruleType == RuleType.responseReplace || ruleType == RuleType.responseUpdate;
          // bool isReq = ruleType == RuleType.requestReplace || ruleType == RuleType.requestUpdate;
          if (x.contains('responsestatus') || x == 'status' || x == 'setstatus' || x == 'statuscode' || x == 'setstatuscode') {
            return 'replaceResponseStatus';
          }
          if (x.contains('responseheader') || x == 'headers' || x == 'setheader' || x == 'setheaders' || x == 'header' || x == 'updateheaders') {
            return 'updateHeader';
          }
          if (x.contains('responsebody') || x == 'body' || x == 'setbody' || x == 'content' || x == 'text' || x == 'updatebody') {
            return 'updateBody';
          }
          if (x.contains('requestheader')) return 'updateHeader';
          if (x.contains('requestbody')) return 'updateBody';
          // default by rule
          return 'updateBody';
        }

        final normed = <Map<String, dynamic>>[];
        bool wantsUpdate = false;
        for (final raw in itemsAny) {
          if (raw is! Map) continue;
          final m = Map<String, dynamic>.from(raw);
          // type
          final tRaw = (m['type'] as String?) ?? '';
          final t = _canonType(tRaw, type);
          m['type'] = t;
          // enabled default true
          if (m['enabled'] is! bool) m['enabled'] = true;
          // build values
          Map<String, dynamic> v;
          if (m['values'] is Map) {
            v = Map<String, dynamic>.from(m['values'] as Map);
          } else {
            v = <String, dynamic>{};
            for (final k in List.of(m.keys)) {
              if (k == 'type' || k == 'enabled' || k == 'values') continue;
              v[k] = m.remove(k);
            }
          }
          // derive updateBody pattern from before/after | original/modified if present
          if (t == 'updateBody') {
            final before = (v['before'] ?? v['original'] ?? '') as String;
            final after = (v['after'] ?? v['modified'] ?? '') as String;
            final key = (v['key'] ?? '') as String;
            final hasBA = before.trim().isNotEmpty && after.isNotEmpty;
            if (key.trim().isEmpty && hasBA) {
              final escaped = RegExp.escape(before);
              v['key'] = escaped;
              v['value'] = after;
            }
            if ((v['key'] as String?)?.trim().isNotEmpty == true) wantsUpdate = true;
          }
          // aliases
          if (!v.containsKey('statusCode')) {
            if (v['status'] != null) v['statusCode'] = v['status'];
            if (v['status_code'] != null) v['statusCode'] = v['status_code'];
          }
          if (!v.containsKey('headers')) {
            if (v['header'] is Map) v['headers'] = v['header'];
            if (v['response_headers'] is Map) v['headers'] = v['response_headers'];
            if (v['response_header'] is Map) v['headers'] = v['response_header'];
          }
          if (!v.containsKey('body') && v['content'] is String) v['body'] = v['content'];
          if (!v.containsKey('bodyFile') && v['body_file'] is String) v['bodyFile'] = v['body_file'];
          if (!v.containsKey('bodyType') && v['body_type'] is String) v['bodyType'] = v['body_type'];

          // attach values back
          m['values'] = v;
          normed.add(m);

          // Expand combined convenience: split status/headers into their own items if present
          if (v['statusCode'] != null) {
            normed.add({
              'enabled': true,
              'type': 'replaceResponseStatus',
              'values': {'statusCode': v['statusCode']}
            });
          }
          if (v['headers'] is Map) {
            final headers = Map<String, String>.from(v['headers'] as Map);
            // convert to updateHeader operations for each header
            headers.forEach((hk, hv) {
              final keyPattern = '^' + RegExp.escape(hk) + r':.*\$';
              final newLine = '$hk: $hv';
              normed.add({
                'enabled': true,
                'type': 'updateHeader',
                'values': {'key': keyPattern, 'value': newLine}
              });
            });
          }
        }

        // Force update rule type when doing body updates
        if (wantsUpdate) {
          type = (type == RuleType.requestReplace || type == RuleType.requestUpdate)
              ? RuleType.requestUpdate
              : RuleType.responseUpdate;
        }

        if (normed.isEmpty) return {'ok': false, 'error': 'invalid items'};
        final items = normed.map((e) => RewriteItem.fromJson(e)).toList();
        final urlShort = Uri.tryParse(urlPattern)?.path ?? urlPattern;
        final finalName = (ruleName == null || ruleName.isEmpty)
            ? 'AI ${type.name} $urlShort @ ${DateTime.now().toIso8601String()}'
            : ruleName;
        await AITools.addRewriteRule(urlPattern: urlPattern, type: type, items: items, name: finalName, enabled: ruleEnabled);
        return {'ok': true, 'name': finalName, 'count': items.length};
      case 'remove_rewrite_rule':
        final urlPattern = args['url_pattern'] as String;
        final typeStr = args['type'] as String;
        final mgr = await RequestRewriteManager.instance;
        final type = RuleType.fromName(typeStr);
        final toRemove = <int>[];
        for (var i = 0; i < mgr.rules.length; i++) { final r = mgr.rules[i]; if (r.url == urlPattern && r.type == type) toRemove.add(i); }
        if (toRemove.isEmpty) return {'ok': false, 'error': 'not found'};
        await mgr.removeIndex(toRemove.reversed.toList());
        await mgr.flushRequestRewriteConfig();
        return {'ok': true, 'removed': toRemove.length};
      case 'set_rewrite_enabled':
        final enabled = args['enabled'] as bool;
        final mgr = await RequestRewriteManager.instance;
        mgr.enabled = enabled;
        await mgr.flushRequestRewriteConfig();
        return {'ok': true};
      case 'list_scripts':
        final includeContent = (args['include_content'] ?? false) as bool;
        final mgr = await ScriptManager.instance;
        final list = <Map<String, dynamic>>[];
        for (final it in mgr.list) { list.add({'name': it.name, 'enabled': it.enabled, 'urls': it.urls, if (includeContent) 'script': await mgr.getScript(it)}); }
        return {'ok': true, 'enabled': mgr.enabled, 'list': list};
      case 'add_script':
        final name = args['name'] as String;
        final urls = (args['urls'] as List).cast<String>();
        final script = args['script'] as String;
        await AITools.addScript(name: name, urls: urls, script: script);
        return {'ok': true};
      case 'update_script':
        final name = args['name'] as String;
        final urls = (args['urls'] as List?)?.cast<String>();
        final script = args['script'] as String?;
        final enabledArg = args['enabled'] as bool?;
        final mgr = await ScriptManager.instance;
        final idx = mgr.list.indexWhere((e) => e.name == name);
        if (idx < 0) {
          if (script == null) return {'ok': false, 'error': 'not found and no script provided'};
          await AITools.addScript(name: name, urls: urls ?? ['*'], script: script);
          if (enabledArg != null) { final item2 = mgr.list.firstWhere((e) => e.name == name); item2.enabled = enabledArg; await mgr.flushConfig(); }
          return {'ok': true, 'created': true};
        } else {
          final item = mgr.list[idx];
          if (urls != null) item.urls = urls;
          if (script != null) await mgr.updateScript(item, script);
          if (enabledArg != null) item.enabled = enabledArg;
          await mgr.flushConfig();
          return {'ok': true, 'updated': true};
        }
      case 'remove_script':
        final name = args['name'] as String;
        final mgr = await ScriptManager.instance;
        final idx = mgr.list.indexWhere((e) => e.name == name);
        if (idx < 0) return {'ok': false, 'error': 'not found'};
        await mgr.removeScript(idx);
        await mgr.flushConfig();
        return {'ok': true};
      case 'set_script_enabled':
        final enabled = args['enabled'] as bool;
        final mgr = await ScriptManager.instance;
        mgr.enabled = enabled;
        await mgr.flushConfig();
        return {'ok': true};
      case 'replay_request':
        final id = args['request_id'] as String;
        final req = _findRequestById(id);
        if (req == null) return {'ok': false, 'error': 'not found'};
        final copy = req.copy(uri: req.requestUrl);
        final proxyInfo = widget.proxyServer.isRunning ? ProxyInfo.of('127.0.0.1', widget.proxyServer.port) : null;
        final resp = await HttpClients.proxyRequest(copy, proxyInfo: proxyInfo);
        return {'ok': true, 'status': resp.status.code, 'reason': resp.status.reasonPhrase, 'length': resp.contentLength};
      case 'get_script_template':
        return {'ok': true, 'template': ScriptManager.template};
      default:
        return {'ok': false, 'error': 'unknown tool'};
    }
  }

  Set<Option> _mapSearchOptions(List<String> keys) {
    final set = <Option>{};
    for (final k in keys) {
      switch (k) {
        case 'url': set.add(Option.url); break;
        case 'method': set.add(Option.method); break;
        case 'request_header': set.add(Option.requestHeader); break;
        case 'response_header': set.add(Option.responseHeader); break;
        case 'request_body': set.add(Option.requestBody); break;
        case 'response_body': set.add(Option.responseBody); break;
        case 'response_content_type': set.add(Option.responseContentType); break;
      }
    }
    if (set.isEmpty) set.add(Option.url);
    return set;
  }

  List<HttpRequest> _allRequests() => widget.getAllRequests?.call() ?? <HttpRequest>[];

  HttpRequest? _findRequestById(String id) {
    for (final r in _allRequests()) { if (r.requestId == id) return r; }
    return null;
  }

  Future<Map<String, dynamic>> _httpRequestToJson(HttpRequest r, {bool includeBody = false, int maxChars = 5000}) async {
    final map = r.toJson();
    map['requestId'] = r.requestId;
    if (includeBody) { final text = await r.decodeBodyString(); map['body'] = text.substring(0, text.length > maxChars ? maxChars : text.length); } else { map.remove('body'); }
    return map;
  }

  Future<Map<String, dynamic>> _httpResponseToJson(HttpResponse resp, {bool includeBody = false, int maxChars = 5000}) async {
    final map = resp.toJson();
    if (includeBody) { final text = await resp.decodeBodyString(); map['body'] = text.substring(0, text.length > maxChars ? maxChars : text.length); } else { map.remove('body'); }
    return map;
  }

  Future<Map<String, dynamic>> _pickFields(HttpRequest r, HttpResponse? resp, List<String> parts, int maxChars) async {
    final result = <String, dynamic>{};
    for (final p in parts) {
      try {
        if (p == 'request.url') result[p] = r.requestUrl;
        else if (p == 'request.method') result[p] = r.method.name;
        else if (p == 'request.path') result[p] = r.path;
        else if (p == 'request.query') result[p] = r.queries;
        else if (p == 'request.headers') result[p] = r.headers.toJson();
        else if (p.startsWith('request.header:')) { final name = p.substring('request.header:'.length); result[p] = r.headers.getList(name) ?? []; }
        else if (p == 'request.cookies') { result[p] = r.cookies; }
        else if (p == 'request.content_type') { result[p] = r.headers.contentType; }
        else if (p == 'request.charset') { result[p] = r.charset; }
        else if (p == 'request.body') { final text = await r.decodeBodyString(); result[p] = text.substring(0, text.length > maxChars ? maxChars : text.length); }
        else if (p == 'response.status_code') { result[p] = resp?.status.code; }
        else if (p == 'response.reason') { result[p] = resp?.status.reasonPhrase; }
        else if (p == 'response.headers') { result[p] = resp?.headers.toJson(); }
        else if (p.startsWith('response.header:')) { final name = p.substring('response.header:'.length); result[p] = resp?.headers.getList(name) ?? []; }
        else if (p == 'response.cookies') { result[p] = resp?.headers.getList('Set-Cookie') ?? [];
        } else if (p == 'response.content_type') { result[p] = resp?.headers.contentType;
        } else if (p == 'response.charset') { result[p] = resp?.charset;
        } else if (p == 'response.body') {
          if (resp == null) { result[p] = null; } else { final text = await resp.decodeBodyString(); result[p] = text.substring(0, text.length > maxChars ? maxChars : text.length); }
        } else if (p == 'duration_ms') { result[p] = resp == null ? null : resp.responseTime.difference(r.requestTime).inMilliseconds; }
      } catch (e) { result[p] = {'error': e.toString()}; }
    }
    return result;
  }

  List<dynamic> _parsePathTokens(String path) {
    final tokens = <dynamic>[]; var buf = StringBuffer(); int i = 0;
    while (i < path.length) { final ch = path[i]; if (ch == '.') { if (buf.isNotEmpty) { tokens.add(buf.toString()); buf.clear(); } i++; } else if (ch == '[') { if (buf.isNotEmpty) { tokens.add(buf.toString()); buf.clear(); } i++; final idxBuf = StringBuffer(); while (i < path.length && path[i] != ']') { idxBuf.write(path[i]); i++; } if (i < path.length && path[i] == ']') i++; final idx = int.tryParse(idxBuf.toString()); if (idx != null) tokens.add(idx); } else { buf.write(ch); i++; } }
    if (buf.isNotEmpty) tokens.add(buf.toString()); return tokens;
  }

  dynamic _jsonPathEval(dynamic data, String path) {
    var p = path.trim();
    if (p.startsWith('\$.')) p = p.substring(2);
    if (p.startsWith('\$')) p = p.substring(1);
    if (p.isEmpty) return data;
    final tokens = _parsePathTokens(p);
    dynamic cur = data;
    for (final t in tokens) {
      if (t is String) { if (cur is Map && cur.containsKey(t)) { cur = cur[t]; } else { return null; } }
      else if (t is int) { if (cur is List && t >= 0 && t < cur.length) { cur = cur[t]; } else { return null; } }
    }
    return cur;
  }

  List<Map<String, dynamic>> _aggregate(List<HttpRequest> list, List<String> groupBy, String metric) {
    final map = <String, List<int>>{};
    String keyOf(HttpRequest r) {
      final parts = <String>[];
      for (final g in groupBy) {
        switch (g) {
          case 'host': parts.add(r.hostAndPort?.host ?? Uri.parse(r.requestUrl).host); break;
          case 'path': parts.add(r.path); break;
          case 'status': parts.add((r.response?.status.code ?? 0).toString()); break;
          case 'method': parts.add(r.method.name); break;
          case 'content_type': parts.add(r.response?.headers.contentType ?? ''); break;
        }
      }
      return parts.join('|');
    }
    for (final r in list) { final k = groupBy.isEmpty ? 'all' : keyOf(r); map.putIfAbsent(k, () => <int>[]); final d = r.response == null ? null : r.response!.responseTime.difference(r.requestTime).inMilliseconds; if (d != null) map[k]!.add(d); }
    final out = <Map<String, dynamic>>[];
    for (final entry in map.entries) { final durations = entry.value..sort(); final count = durations.length; double avg = 0; if (count > 0) { avg = durations.reduce((a, b) => a + b) / count; } int p95 = 0; if (count > 0) { final idx = ((count - 1) * 0.95).round(); p95 = durations[idx]; } final item = <String, dynamic>{'group': entry.key, 'count': count, 'avg_duration': avg.round(), 'p95_duration': p95}; switch (metric) { case 'count': item['_metric'] = count; break; case 'avg_duration': item['_metric'] = item['avg_duration']; break; case 'p95_duration': item['_metric'] = p95; break; } out.add(item); }
    out.sort((a, b) => (b['_metric'] as num).compareTo(a['_metric'] as num));
    return out;
  }

  Future<void> _createScript(String code) async {
    final nameCtrl = TextEditingController(text: 'AI Script');
    final urlsCtrl = TextEditingController(text: NetworkTabController.current?.request.get()?.domainPath ?? '*');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.code,
                size: 20,
                color: Theme.of(ctx).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            const Text('创建脚本', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SettingField(
                label: '名称',
                icon: Icons.label,
                child: TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _SettingField(
                label: 'URL 匹配(逗号分隔)',
                icon: Icons.link,
                child: TextField(
                  controller: urlsCtrl,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final urls = urlsCtrl.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      await AITools.addScript(name: nameCtrl.text.trim(), urls: urls, script: code);
      if (mounted) FlutterToastr.show('脚本已创建', context, duration: 2);
    }
  }

  Future<void> _openRewriteEditor() async {
    final req = NetworkTabController.current?.request.get();
    final res = NetworkTabController.current?.response.get();
    if (req == null && res?.request == null) { FlutterToastr.show('未选中请求', context, duration: 2); return; }
    final url = (req ?? res!.request!).domainPath;
    final type = req != null ? RuleType.requestReplace : RuleType.responseReplace;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.tune,
                size: 20,
                color: Theme.of(ctx).colorScheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            const Text('打开重写编辑器', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ],
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '为当前选择的URL创建/编辑重写规则:',
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(ctx).colorScheme.onSurface.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceVariant.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                url,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Theme.of(ctx).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final mgr = await RequestRewriteManager.instance;
    final rule = mgr.getRequestRewriteRule(req ?? res!.request!, type);
    final items = type == RuleType.requestReplace ? RewriteItem.fromRequest(req ?? res!.request!) : RewriteItem.fromResponse(res ?? (req!.response!));
    await mgr.addRule(rule, items);
    await mgr.flushRequestRewriteConfig();
    if (mounted) FlutterToastr.show('已创建/更新规则，可在"请求重写"中编辑', context, duration: 3);
  }
}

class _MessageBubble extends StatelessWidget {
  final String content;
  final bool isUser;
  final ThemeData theme;

  const _MessageBubble({
    required this.content,
    required this.isUser,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final isStreaming = !isUser && content.isEmpty;

    return Container(
      decoration: BoxDecoration(
        gradient: isUser
            ? LinearGradient(
                colors: [
                  theme.colorScheme.primaryContainer.withOpacity(0.4),
                  theme.colorScheme.primaryContainer.withOpacity(0.2),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : LinearGradient(
                colors: [
                  theme.colorScheme.secondaryContainer.withOpacity(0.4),
                  theme.colorScheme.secondaryContainer.withOpacity(0.2),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isUser
              ? theme.colorScheme.primary.withOpacity(0.15)
              : theme.colorScheme.secondary.withOpacity(0.15),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: (isUser ? theme.colorScheme.primary : theme.colorScheme.secondary)
                .withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
            spreadRadius: 0,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: isStreaming
            ? _TypingIndicator(theme: theme)
            : _buildMarkdownContent(),
      ),
    );
  }

  Widget _buildMarkdownContent() {
    return MarkdownBody(
      data: content,
      selectable: true,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          fontSize: 14,
          height: 1.6,
          color: theme.colorScheme.onSurface,
          letterSpacing: 0.3,
        ),
        h1: TextStyle(
          fontSize: 22,
          height: 1.4,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
        h2: TextStyle(
          fontSize: 20,
          height: 1.4,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
        h3: TextStyle(
          fontSize: 18,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
        code: TextStyle(
          fontSize: 13,
          fontFamily: 'monospace',
          backgroundColor: theme.colorScheme.surfaceVariant.withOpacity(0.5),
          color: theme.colorScheme.secondary,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: theme.dividerColor.withOpacity(0.2),
            width: 1,
          ),
        ),
        codeblockPadding: const EdgeInsets.all(16),
        blockquote: TextStyle(
          fontSize: 14,
          color: theme.colorScheme.onSurface.withOpacity(0.8),
          fontStyle: FontStyle.italic,
        ),
        blockquoteDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: theme.colorScheme.primary,
              width: 4,
            ),
          ),
        ),
        blockquotePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        listBullet: TextStyle(
          fontSize: 14,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
        tableHead: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.primary,
        ),
        tableBody: TextStyle(
          fontSize: 14,
          color: theme.colorScheme.onSurface,
        ),
        a: TextStyle(
          fontSize: 14,
          color: theme.colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
        em: TextStyle(
          fontSize: 14,
          fontStyle: FontStyle.italic,
          color: theme.colorScheme.onSurface,
        ),
        strong: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurface,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: theme.dividerColor,
              width: 1,
            ),
          ),
        ),
      ),
      extensionSet: md.ExtensionSet(
        md.ExtensionSet.gitHubFlavored.blockSyntaxes,
        [
          md.EmojiSyntax(),
          ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
        ],
      ),
      onTapLink: (text, href, title) {
        if (href != null) {
          Clipboard.setData(ClipboardData(text: href));
        }
      },
    );
  }

  _CodeBlock? _extractCodeBlock(String text) {
    final reg = RegExp(r"```(\w+)?\n([\s\S]*?)```", multiLine: true);
    final m = reg.firstMatch(text);
    if (m == null) return null;
    final lang = (m.group(1) ?? '').toLowerCase();
    final code = m.group(2) ?? '';
    return _CodeBlock(lang, code);
  }
}

class _CodeBlock {
  final String lang;
  final String code;
  _CodeBlock(this.lang, this.code);
}

class _SettingField extends StatelessWidget {
  final String label;
  final IconData icon;
  final Widget child;

  const _SettingField({
    required this.label,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  final bool compact;

  const _LabeledField({required this.label, required this.child, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      SizedBox(width: 120, child: Text('$label:')),
      const SizedBox(width: 8),
      Expanded(child: compact ? Align(alignment: Alignment.centerLeft, child: child) : child),
    ]);
  }
}

class _ToolCallBubble extends StatelessWidget {
  final String content;
  const _ToolCallBubble({required this.content});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.surfaceVariant.withOpacity(0.6),
            theme.colorScheme.surfaceVariant.withOpacity(0.3),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.2),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.primary.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  theme.colorScheme.primary.withOpacity(0.15),
                  theme.colorScheme.secondary.withOpacity(0.15),
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.build_outlined,
              size: 16,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              content,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: theme.colorScheme.onSurface.withOpacity(0.85),
                letterSpacing: 0.2,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Animated entry widget for messages with fade and slide animations
class _AnimatedMessageEntry extends StatefulWidget {
  final Widget child;
  final int index;

  const _AnimatedMessageEntry({
    super.key,
    required this.child,
    required this.index,
  });

  @override
  State<_AnimatedMessageEntry> createState() => _AnimatedMessageEntryState();
}

class _AnimatedMessageEntryState extends State<_AnimatedMessageEntry>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
    ));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.8, curve: Curves.easeOutCubic),
    ));

    _scaleAnimation = Tween<double>(
      begin: 0.85,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.8, curve: Curves.elasticOut),
    ));

    // Stagger animation based on index for smoother appearance
    Future.delayed(Duration(milliseconds: widget.index * 30), () {
      if (mounted) {
        _controller.forward();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(
        position: _slideAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Typing indicator animation for streaming messages
class _TypingIndicator extends StatefulWidget {
  final ThemeData theme;

  const _TypingIndicator({required this.theme});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.start,
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final delay = index * 0.2;
              final value = (_controller.value - delay).clamp(0.0, 1.0);
              final curve = Curves.easeInOutSine.transform(value);
              final scale = 0.6 + 0.8 * (1 - (curve * 2 - 1).abs());
              final opacity = (0.3 + 0.7 * (1 - (curve * 2 - 1).abs())).clamp(0.3, 1.0);
              final offsetY = -6 * (1 - (curve * 2 - 1).abs()).clamp(0.0, 1.0);

              return Transform.translate(
                offset: Offset(0, offsetY),
                child: Transform.scale(
                  scale: scale,
                  child: Container(
                    margin: EdgeInsets.only(right: index < 2 ? 6 : 0),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          widget.theme.colorScheme.primary.withOpacity(opacity),
                          widget.theme.colorScheme.secondary.withOpacity(opacity * 0.8),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: widget.theme.colorScheme.primary.withOpacity(opacity * 0.4),
                          blurRadius: 4,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}

/// Empty state widget shown when there are no messages
class _EmptyStateWidget extends StatelessWidget {
  final ThemeData theme;

  const _EmptyStateWidget({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    theme.colorScheme.primary.withOpacity(0.1),
                    theme.colorScheme.secondary.withOpacity(0.1),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.psychology_outlined,
                size: 64,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 32),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                _SuggestionChip(
                  icon: Icons.search,
                  label: '分析流量',
                  theme: theme,
                ),
                _SuggestionChip(
                  icon: Icons.code,
                  label: '创建脚本',
                  theme: theme,
                ),
                _SuggestionChip(
                  icon: Icons.tune,
                  label: '配置规则',
                  theme: theme,
                ),
                _SuggestionChip(
                  icon: Icons.help_outline,
                  label: '使用帮助',
                  theme: theme,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Suggestion chip for empty state
class _SuggestionChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final ThemeData theme;

  const _SuggestionChip({
    required this.icon,
    required this.label,
    required this.theme,
  });

  @override
  State<_SuggestionChip> createState() => _SuggestionChipState();
}

class _SuggestionChipState extends State<_SuggestionChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isHovered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.05,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _controller.forward();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _controller.reverse();
      },
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            gradient: _isHovered
                ? LinearGradient(
                    colors: [
                      widget.theme.colorScheme.primaryContainer.withOpacity(0.6),
                      widget.theme.colorScheme.secondaryContainer.withOpacity(0.6),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: _isHovered ? null : widget.theme.colorScheme.surfaceVariant.withOpacity(0.5),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _isHovered
                  ? widget.theme.colorScheme.primary.withOpacity(0.3)
                  : widget.theme.dividerColor.withOpacity(0.2),
              width: 1.5,
            ),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: widget.theme.colorScheme.primary.withOpacity(0.15),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.icon,
                size: 18,
                color: widget.theme.colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  color: widget.theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
