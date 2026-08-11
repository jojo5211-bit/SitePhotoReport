import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Restore soft-deleted photos back to unclassified.
class RestoreDeletedScreen extends StatefulWidget {
  const RestoreDeletedScreen({super.key});
  @override
  State<RestoreDeletedScreen> createState() => _RestoreDeletedScreenState();
}

class _RestoreDeletedScreenState extends State<RestoreDeletedScreen> {
  List<Map<String, dynamic>> _deleted = [];
  final Set<String> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = context.read<AppState>().store!;
    final deleted = await store.deletedPhotos();
    if (!mounted) return;
    setState(() {
      _deleted = deleted;
      _selected.clear();
      _loading = false;
    });
  }

  Future<void> _restore(List<String> ids) async {
    if (ids.isEmpty) return;
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    final count = await store.restorePhotos(ids);
    messenger.showSnackBar(SnackBar(content: Text('已復原 $count 張照片至未分類')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('復原已刪除照片'),
        actions: [
          if (_selected.isNotEmpty)
            TextButton(
              onPressed: () => _restore(_selected.toList()),
              child: const Text('復原選取', style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _deleted.isEmpty
          ? const Center(
              child: Text('沒有已刪除的照片', style: TextStyle(color: Colors.grey)),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text(
                        '共 ${_deleted.length} 張（原始檔仍保留）',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => _restore(
                          _deleted.map((d) => d['id'].toString()).toList(),
                        ),
                        child: const Text('復原全部'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 6,
                          crossAxisSpacing: 6,
                          childAspectRatio: 0.8,
                        ),
                    itemCount: _deleted.length,
                    itemBuilder: (ctx, i) {
                      final photo = _deleted[i];
                      final id = photo['id'].toString();
                      final thumbPath = context
                          .read<AppState>()
                          .store!
                          .thumbnailFile(
                            (photo['thumbnail_rel_path'] ?? '').toString(),
                          )
                          .path;
                      final selected = _selected.contains(id);
                      return GestureDetector(
                        onTap: () => setState(() {
                          if (selected) {
                            _selected.remove(id);
                          } else {
                            _selected.add(id);
                          }
                        }),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: File(thumbPath).existsSync()
                                  ? Image.file(
                                      File(thumbPath),
                                      fit: BoxFit.cover,
                                    )
                                  : Container(color: const Color(0xFFC8D8E0)),
                            ),
                            Positioned(
                              top: 4,
                              left: 4,
                              child: Icon(
                                selected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                color: selected
                                    ? AppColors.primary
                                    : Colors.white,
                                size: 24,
                              ),
                            ),
                          ],
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
