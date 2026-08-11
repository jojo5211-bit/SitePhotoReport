import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import '../services/report_exporter.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';

/// Export screen: PDF report (preview/share/print) and CSV index.
class ExportScreen extends StatefulWidget {
  const ExportScreen({super.key});
  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  bool _showDate = true;
  bool _showFilename = true;
  bool _showCaption = true;
  bool _showLocation = true;
  bool _showNumber = true;
  ReportLayout _layout = ReportLayout.auto;
  PdfTemplate _template = PdfTemplate.modern;
  bool _busy = false;

  Future<void> _exportPdf() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final exporter = ReportExporter(store);
      final bytes = await exporter.buildPdf(
        showDate: _showDate,
        showFilename: _showFilename,
        showCaption: _showCaption,
        showLocation: _showLocation,
        showNumber: _showNumber,
        layout: _layout,
        template: _template,
      );
      final project = await store.project();
      final name = (project['report_title'] ?? project['name'] ?? 'report')
          .toString();
      final outputDir = Directory(p.join(store.root, 'exports'));
      await outputDir.create(recursive: true);
      final outputPath = await _nextAvailablePath(outputDir.path, name, 'pdf');
      final file = File(outputPath);
      await file.writeAsBytes(bytes, flush: true);
      if (mounted) {
        await _showPostExportActions(file, bytes);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('匯出失敗：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _nextAvailablePath(
    String directory,
    String rawName,
    String extension,
  ) async {
    final cleaned = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final base = cleaned.isEmpty ? 'report' : cleaned;
    var candidate = p.join(directory, '$base.$extension');
    var index = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(directory, '${base}_$index.$extension');
      index++;
    }
    return candidate;
  }

  Future<void> _showPostExportActions(File file, Uint8List bytes) async {
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('PDF 已儲存'),
        content: Text('已存到工程的 exports 資料夾：\n${file.path}\n\n請選擇下一步：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'close'),
            child: const Text('關閉'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'open'),
            icon: const Icon(Icons.open_in_new),
            label: const Text('用其他 App 開啟'),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, 'share'),
            icon: const Icon(Icons.share),
            label: const Text('分享給他人'),
          ),
        ],
      ),
    );
    if (!mounted || action == null || action == 'close') return;
    if (action == 'share') {
      await Printing.sharePdf(bytes: bytes, filename: p.basename(file.path));
      return;
    }
    final result = await OpenFilex.open(file.path);
    if (!mounted || result.type == ResultType.done) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('找不到可開啟PDF的App：${result.message}')));
  }

  Future<void> _previewPdf() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final exporter = ReportExporter(store);
      final bytes = await exporter.buildPdf(
        showDate: _showDate,
        showFilename: _showFilename,
        showCaption: _showCaption,
        showLocation: _showLocation,
        showNumber: _showNumber,
        layout: _layout,
        template: _template,
      );
      if (!mounted) return;
      // In-app PDF preview (CJK font is embedded so Chinese renders correctly).
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(title: const Text('PDF 預覽')),
            body: PdfPreview(
              build: (_) => bytes,
              canChangeOrientation: false,
              canChangePageFormat: false,
              allowSharing: true,
              allowPrinting: true,
              loadingWidget: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('PDF 頁面載入中…'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('預覽失敗：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv() async {
    final store = context.read<AppState>().store!;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final exporter = ReportExporter(store);
      final csv = await exporter.buildCsv();
      final project = await store.project();
      final name = (project['name'] ?? 'report').toString();
      final outputDir = Directory(p.join(store.root, 'exports'));
      await outputDir.create(recursive: true);
      final outputPath = await _nextAvailablePath(
        outputDir.path,
        '${name}_照片清冊',
        'csv',
      );
      final file = File(outputPath);
      // Prepend BOM so Excel reads UTF-8 correctly.
      await file.writeAsBytes([0xEF, 0xBB, 0xBF, ...csv.codeUnits]);
      messenger.showSnackBar(
        SnackBar(content: Text('CSV 已存到工程 exports 資料夾：${file.path}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('匯出失敗：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppState>().store!;
    return Scaffold(
      appBar: AppBar(title: const Text('匯出報告')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              // Numbering status summary (matches desktop export dialog).
              FutureBuilder<List<Map<String, dynamic>>>(
                future: store.slotNumberSummary(),
                builder: (ctx, snap) {
                  final rows = snap.data ?? [];
                  if (rows.isEmpty) return const SizedBox();
                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '照片編號狀態',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...rows.map((r) {
                            final numbered = (r['numbered'] ?? 0) as int;
                            final hasNumber = numbered > 0;
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Icon(
                                    hasNumber
                                        ? Icons.check_circle
                                        : Icons.remove_circle_outline,
                                    size: 16,
                                    color: hasNumber
                                        ? AppColors.success
                                        : Colors.grey,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '${r['section_name']}／${r['slot_name']}',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  Text(
                                    hasNumber ? '$numbered 張已編號' : '無編號',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: hasNumber
                                          ? AppColors.success
                                          : AppColors.warning,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const Text(
                '報告內容',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              _toggle(
                '顯示拍攝日期',
                _showDate,
                (v) => setState(() => _showDate = v),
              ),
              _toggle(
                '顯示檔名',
                _showFilename,
                (v) => setState(() => _showFilename = v),
              ),
              _toggle(
                '顯示照片說明',
                _showCaption,
                (v) => setState(() => _showCaption = v),
              ),
              _toggle(
                '顯示施工位置',
                _showLocation,
                (v) => setState(() => _showLocation = v),
              ),
              _toggle(
                '照片下方顯示編號',
                _showNumber,
                (v) => setState(() => _showNumber = v),
              ),
              const Divider(height: 32),
              const Text(
                'PDF版型',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<ReportLayout>(
                value: _layout,
                decoration: const InputDecoration(
                  labelText: '照片排版方式',
                  border: OutlineInputBorder(),
                ),
                items: ReportLayout.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.label),
                      ),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _layout = value);
                      },
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '自動排版會保留照片比例：直立照片每頁最多4張，橫向照片每頁最多2張。固定6張會使用2×3排列。所有圖片會自動縮放，不會變形。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<PdfTemplate>(
                value: _template,
                decoration: const InputDecoration(
                  labelText: 'PDF模板',
                  border: OutlineInputBorder(),
                ),
                items: PdfTemplate.values
                    .map(
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value.label),
                      ),
                    )
                    .toList(),
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) setState(() => _template = value);
                      },
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '模板一為黑白省墨版；模板二為清爽藍綠版；模板三為暖棕工程版。可先按 PDF 預覽確認樣式。',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '輸出格式',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              _exportTile(
                Icons.picture_as_pdf,
                'PDF 報告',
                '封面 + 章節 + 照片編號',
                _exportPdf,
              ),
              _exportTile(Icons.visibility, 'PDF 預覽', '先預覽再決定', _previewPdf),
              _exportTile(
                Icons.table_chart,
                'Excel 清冊 (CSV)',
                '照片索引表',
                _exportCsv,
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 22,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          CircularProgressIndicator(),
                          SizedBox(height: 14),
                          Text('PDF 產生中，請稍候…'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _exportTile(
    IconData icon,
    String title,
    String desc,
    VoidCallback onTap,
  ) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: AppColors.primary, size: 32),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(desc),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
