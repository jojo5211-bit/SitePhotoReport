import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'settings_service.dart';

/// Result of a single AI classification.
class ClassifyResult {
  final String section;
  final String slot;
  final double confidence;
  final String reason;
  ClassifyResult(this.section, this.slot, this.confidence, this.reason);
}

/// OpenAI-compatible vision classifier, matching the desktop app's vision.py.
/// Supports few-shot examples (user-confirmed placements) and capture-date hints.
class VisionClassifier {
  final ApiProfile profile;
  VisionClassifier(this.profile);

  String get _chatUrl {
    final ep = profile.endpoint.replaceAll(RegExp(r'/+$'), '');
    if (ep.endsWith('/chat/completions')) return ep;
    return '$ep/chat/completions';
  }

  Future<ClassifyResult> classify(
    File imageFile,
    List<Map<String, dynamic>> sections, {
    List<Map<String, dynamic>> examples = const [],
    String capturedAt = '',
  }) async {
    final bytes = await imageFile.readAsBytes();
    final b64 = base64Encode(bytes);
    final mime = imageFile.path.toLowerCase().endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';

    // Rich candidate list with descriptions.
    final candidateLines = <String>[];
    for (final section in sections) {
      final desc = (section['description'] ?? '').toString().trim();
      final slotDescs = <String>[];
      for (final slot in (section['slots'] as List)) {
        final note = (slot['default_caption'] ?? '').toString().trim();
        slotDescs.add(
          note.isEmpty ? slot['name'].toString() : '${slot['name']}（$note）',
        );
      }
      var line = '- 項目：${section['name']}';
      if (desc.isNotEmpty) line += '（$desc）';
      line += '；可用欄位：${slotDescs.join(', ')}';
      candidateLines.add(line);
    }

    var examplesBlock = '';
    if (examples.isNotEmpty) {
      final lines = examples
          .take(5)
          .map((e) => '  範例：「${e['filename']}」→ ${e['section']} / ${e['slot']}')
          .join('\n');
      examplesBlock = '\n\n使用者已確認的分類範例（請參考其判斷邏輯）：\n$lines';
    }

    var dateHint = '';
    if (capturedAt.isNotEmpty) {
      dateHint = '\n這張照片的拍攝時間：$capturedAt（可作為施工階段的輔助判斷）';
    }

    final prompt =
        '''你是工程照片整理助手。請根據照片內容，從下列既有項目與欄位中選出最適合的一組。
不要創造新項目。請只回傳 JSON，不要 Markdown：
{"section": "項目名稱", "slot": "欄位名稱", "confidence": 0.0, "reason": "簡短原因"}

既有候選：
${candidateLines.join('\n')}$dateHint$examplesBlock

若無法判斷，section 與 slot 請填空字串，confidence 小於 0.55。''';

    final payload = {
      'model': profile.visionModel.isNotEmpty
          ? profile.visionModel
          : profile.model,
      'temperature': 0,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': prompt},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:$mime;base64,$b64', 'detail': 'low'},
            },
          ],
        },
      ],
    };

    // Retry with exponential backoff on 429 / network errors (like desktop).
    const maxRetries = 3;
    Object? lastError;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      try {
        final resp = await http
            .post(
              Uri.parse(_chatUrl),
              headers: {
                'Authorization': 'Bearer ${profile.apiKey}',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 60));
        if (resp.statusCode == 429 && attempt < maxRetries - 1) {
          await Future.delayed(Duration(seconds: 2 * (1 << attempt)));
          lastError = 'HTTP 429 限速';
          continue;
        }
        if (resp.statusCode != 200) {
          throw Exception(
            '視覺 API HTTP ${resp.statusCode}：${resp.body.substring(0, resp.body.length.clamp(0, 300))}',
          );
        }
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return _parse(body);
      } on SocketException catch (e) {
        lastError = e;
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(seconds: 2 * (1 << attempt)));
          continue;
        }
        rethrow;
      }
    }
    throw Exception('視覺 API 重試失敗：$lastError');
  }

  ClassifyResult _parse(Map<String, dynamic> body) {
    final choices = body['choices'] as List? ?? [];
    if (choices.isEmpty) return ClassifyResult('', '', 0, '無回應');
    var content = (choices[0]['message']?['content'] ?? '').toString().trim();
    // Strip markdown fences.
    content = content.replaceAll(
      RegExp(r'^```(?:json)?\s*', caseSensitive: false),
      '',
    );
    content = content.replaceAll(RegExp(r'\s*```$'), '');
    var json = <String, dynamic>{};
    try {
      json = jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      final start = content.indexOf('{');
      final end = content.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          json =
              jsonDecode(content.substring(start, end + 1))
                  as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    var confidence = 0.0;
    final rawConf = json['confidence'];
    if (rawConf is num) {
      confidence = rawConf.toDouble();
      if (confidence > 1) confidence /= 100;
      confidence = confidence.clamp(0.0, 1.0);
    }
    return ClassifyResult(
      (json['section'] ?? '').toString().trim(),
      (json['slot'] ?? '').toString().trim(),
      confidence,
      (json['reason'] ?? 'AI 視覺分類建議').toString().trim(),
    );
  }
}
