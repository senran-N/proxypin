
import 'package:proxypin/network/components/manager/request_rewrite_manager.dart';
import 'package:proxypin/network/components/manager/rewrite_rule.dart';
import 'package:proxypin/network/components/manager/script_manager.dart';
import 'package:proxypin/network/http/http.dart';
import 'package:proxypin/ui/component/model/search_model.dart';

class TrafficSummaryItem {
  final DateTime time;
  final String method;
  final String url;
  final int? status;
  final int? durationMs;
  final String? reqContentType;
  final String? resContentType;
  final String? reqSnippet;
  final String? resSnippet;

  TrafficSummaryItem(
      {required this.time,
      required this.method,
      required this.url,
      this.status,
      this.durationMs,
      this.reqContentType,
      this.resContentType,
      this.reqSnippet,
      this.resSnippet});

  Map<String, dynamic> toJson() => {
        'time': time.toIso8601String(),
        'method': method,
        'url': url,
        if (status != null) 'status': status,
        if (durationMs != null) 'duration_ms': durationMs,
        if (reqContentType != null) 'request_content_type': reqContentType,
        if (resContentType != null) 'response_content_type': resContentType,
        if (reqSnippet != null) 'request_snippet': reqSnippet,
        if (resSnippet != null) 'response_snippet': resSnippet,
      };
}

class AITools {
  static List<TrafficSummaryItem> summarize(List<HttpRequest> list, {int limit = 20}) {
    final items = <TrafficSummaryItem>[];
    final take = list.length > limit ? list.sublist(list.length - limit) : list;
    for (final req in take) {
      final res = req.response;
      final duration = res == null ? null : res.responseTime.difference(req.requestTime).inMilliseconds;
      items.add(TrafficSummaryItem(
        time: req.requestTime,
        method: req.method.name,
        url: req.requestUrl,
        status: res?.status.code,
        durationMs: duration,
        reqContentType: req.contentType.name,
        resContentType: res?.contentType.name,
        reqSnippet: _firstChars(req.bodyAsString, 300),
        resSnippet: _firstChars(res?.bodyAsString, 300),
      ));
    }
    return items;
  }

  static String makeTextSummary(List<TrafficSummaryItem> items) {
    final b = StringBuffer();
    b.writeln('Traffic summary (latest ${items.length}):');
    for (final it in items) {
      b.writeln('- [${it.time.toIso8601String()}] ${it.method} ${it.url} ${it.status ?? ''} ${it.durationMs ?? ''}ms');
      if ((it.reqSnippet ?? '').isNotEmpty) b.writeln('  req: ${_oneLine(it.reqSnippet!)}');
      if ((it.resSnippet ?? '').isNotEmpty) b.writeln('  res: ${_oneLine(it.resSnippet!)}');
    }
    return b.toString();
  }

  static List<HttpRequest> applySearch(List<HttpRequest> source, SearchModel search) {
    final out = <HttpRequest>[];
    for (final r in source) {
      if (search.filter(r, r.response)) out.add(r);
    }
    return out;
  }

  static Future<void> addRewriteRule({
    required String urlPattern,
    required RuleType type,
    required List<RewriteItem> items,
    String? name,
    bool enabled = true,
  }) async {
    final mgr = await RequestRewriteManager.instance;
    // Upsert: if a rule with same url + type exists, update it instead of adding duplicates
    for (var i = 0; i < mgr.rules.length; i++) {
      final r = mgr.rules[i];
      if (r.url == urlPattern && r.type == type) {
        final updated = RequestRewriteRule(url: urlPattern, type: type, name: name ?? r.name, enabled: enabled);
        updated.rewritePath = r.rewritePath; // preserve path for items file
        await mgr.updateRule(i, updated, items);
        await mgr.flushRequestRewriteConfig();
        return;
      }
    }
    final rule = RequestRewriteRule(url: urlPattern, type: type, name: name, enabled: enabled);
    await mgr.addRule(rule, items);
    await mgr.flushRequestRewriteConfig();
  }

  static Future<void> addScript({
    required String name,
    required List<String> urls,
    required String script,
  }) async {
    final mgr = await ScriptManager.instance;
    final item = ScriptItem(true, name, urls);
    await mgr.addScript(item, script);
    await mgr.flushConfig();
  }

  static String _firstChars(String? s, int n) {
    if (s == null) return '';
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? t.substring(0, n) : t;
  }

  static String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
