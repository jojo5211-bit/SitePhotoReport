import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/settings_service.dart';
import '../services/vision_classifier.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import 'suggestion_review_screen.dart';

/// AI auto-classification screen: runs vision API over unclassified photos,
/// shows progress, then opens the suggestion review dialog.
class AiClassifyScreen extends StatefulWidget {
  const AiClassifyScreen({super.key});
  @override
  State<AiClassifyScreen> createState() => _AiClassifyScreenState();
}

class _AiClassifyScreenState extends State<AiClassifyScreen> {
  final _settings = SettingsService();
  bool _running = false;
  int _done = 0;
  int _total = 0;
  int _failed = 0;
  String _status = '';

  Future<void> _run() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final profile = await _settings.activeProfile();
    // No API configured → fall back to offline filename-based classification
    // (matches the desktop app's behavior).
    if (profile == null) {
      final count = await store.createSuggestions();
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('已用檔名關鍵字產生 $count 筆建議（未設定 API）')),
      );
      await SuggestionReviewScreen.show(
        navigator.context,
        description: '目前沒有設定視覺 API；這次使用檔名關鍵字產生建議，接受後才會移動照片。',
      );
      navigator.pop();
      return;
    }

    final photos = await store.unclassifiedPhotos();
    if (photos.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('沒有未分類照片')));
      return;
    }

    // Build section list with slots + descriptions for the prompt.
    final sections = <Map<String, dynamic>>[];
    for (final sec in await store.sections()) {
      final slots = await store.slots(sec['id'].toString());
      sections.add({
        'name': sec['name'],
        'description': sec['description'] ?? '',
        'slots': slots,
      });
    }
    final examples = await store.confirmedExamples(limit: 5);

    final classifier = VisionClassifier(profile);
    setState(() {
      _running = true;
      _done = 0;
      _total = photos.length;
      _failed = 0;
      _status = '準備中…';
    });

    final results = <Map<String, dynamic>>[];
    for (final photo in photos) {
      final photoId = photo['id'].toString();
      final previewRel = (photo['preview_rel_path'] ?? '').toString();
      final file = store.previewFile(previewRel);
      final captured = (photo['captured_at'] ?? '').toString();
      if (!mounted) return;
      setState(() => _status = '分析 ${photo['original_filename']}…');
      try {
        if (!await file.exists()) throw Exception('預覽檔不存在');
        final result = await classifier.classify(
          file,
          sections,
          examples: examples,
          capturedAt: captured,
        );
        results.add({
          'photo_id': photoId,
          'section': result.section,
          'slot': result.slot,
          'confidence': result.confidence,
          'reason': result.reason,
        });
      } catch (_) {
        _failed++;
      }
      if (!mounted) return;
      setState(() => _done++);
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _status = '完成';
    });

    // Save suggestions + auto-place confident ones.
    final (added, autoPlaced) = await store.addAiSuggestions(results);
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('AI 分析 $added 張，自動放入 $autoPlaced 張，$_failed 張失敗')),
    );
    // Open the suggestion review screen so the user can accept/reject the rest.
    await SuggestionReviewScreen.show(
      navigator.context,
      description: 'AI 已把信心度 ≥ 0.55 的照片自動放入欄位。\n其餘建議請逐筆確認，接受後才會移動照片。',
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 自動分類')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.auto_awesome, size: 64, color: AppColors.primary),
            const SizedBox(height: 16),
            const Text(
              'AI 視覺分類',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '使用視覺模型分析未分類照片，\n自動建議項目／欄位。\n信心度 ≥ 0.55 會自動放入。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            if (_running) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: _total == 0 ? 0 : _done / _total,
                  minHeight: 8,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '$_done / $_total  $_status',
                style: const TextStyle(fontSize: 13),
              ),
            ] else
              ElevatedButton.icon(
                onPressed: _run,
                icon: const Icon(Icons.play_arrow),
                label: const Text('開始分類'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 14,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
