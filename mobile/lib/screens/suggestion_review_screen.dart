import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Review AI / offline classification suggestions: accept or reject each.
/// Matches the desktop SuggestionDialog (accept selected / accept all / reject).
class SuggestionReviewScreen extends StatefulWidget {
  final String description;
  const SuggestionReviewScreen({super.key, required this.description});

  static Future<void> show(BuildContext context, {String description = ''}) {
    return Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SuggestionReviewScreen(description: description),
      ),
    );
  }

  @override
  State<SuggestionReviewScreen> createState() => _SuggestionReviewScreenState();
}

class _SuggestionReviewScreenState extends State<SuggestionReviewScreen> {
  List<Map<String, dynamic>> _suggestions = [];
  final Set<String> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    final suggestions = await store.suggestions();
    if (!mounted) return;
    setState(() {
      _suggestions = suggestions;
      _selected.clear();
      _loading = false;
    });
  }

  Future<void> _acceptSelected() async {
    if (_selected.isEmpty) return;
    final store = context.read<AppState>().store!;
    await store.acceptSuggestions(_selected.toList());
    _load();
  }

  Future<void> _acceptAll() async {
    final store = context.read<AppState>().store!;
    await store.acceptSuggestions(
      _suggestions.map((s) => s['id'].toString()).toList(),
    );
    _load();
  }

  Future<void> _rejectSelected() async {
    if (_selected.isEmpty) return;
    final store = context.read<AppState>().store!;
    await store.rejectSuggestions(_selected.toList());
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('自動分類建議'),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: _acceptSelected,
              child: const Text('接受選取', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _suggestions.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.check_circle,
                    size: 64,
                    color: AppColors.success,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '沒有待處理的建議',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回'),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                if (widget.description.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: AppColors.sepPillBg,
                    child: Text(
                      widget.description,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.sepPillText,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '${_suggestions.length} 筆建議',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: _acceptAll,
                        child: const Text('接受全部'),
                      ),
                      TextButton(
                        onPressed: _selected.isEmpty ? null : _rejectSelected,
                        child: const Text(
                          '退回選取',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: _suggestions.length,
                    itemBuilder: (ctx, i) {
                      final s = _suggestions[i];
                      final id = s['id'].toString();
                      final selected = _selected.contains(id);
                      final confidence = (s['confidence'] ?? 0) as double;
                      final filename = (s['original_filename'] ?? '')
                          .toString();
                      final section = (s['section_name'] ?? '?').toString();
                      final slot = (s['slot_name'] ?? '?').toString();
                      final reason = (s['reason'] ?? '').toString();
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: CheckboxListTile(
                          value: selected,
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selected.add(id);
                            } else {
                              _selected.remove(id);
                            }
                          }),
                          title: Text(
                            filename,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(
                                    Icons.arrow_forward,
                                    size: 14,
                                    color: AppColors.primary,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '$section / $slot',
                                    style: const TextStyle(
                                      color: AppColors.primary,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '${(confidence * 100).toInt()}%',
                                    style: TextStyle(
                                      color: confidence >= 0.55
                                          ? AppColors.success
                                          : AppColors.warning,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              if (reason.isNotEmpty)
                                Text(
                                  reason,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
