import 'package:flutter/material.dart';

/// Numbering options dialog — remembers last settings across invocations
/// (matches the desktop NumberingDialog behavior).
class NumberingDialog extends StatefulWidget {
  const NumberingDialog({super.key});

  /// Show the dialog and return numbering options, or null if cancelled.
  static Future<NumberingOptions?> show(BuildContext context) {
    return showDialog<NumberingOptions>(
      context: context,
      builder: (_) => const NumberingDialog(),
    );
  }

  @override
  State<NumberingDialog> createState() => _NumberingDialogState();
}

class NumberingOptions {
  final String position;
  final String color;
  final int size;
  final bool transparent;
  NumberingOptions(this.position, this.color, this.size, this.transparent);
}

class _NumberingDialogState extends State<NumberingDialog> {
  // Persist across dialog opens (static, like desktop _last_settings).
  static String _position = 'top_right';
  static String _color = '#D32F2F';
  static int _size = 72;
  static bool _transparent = false;

  static const _positions = {
    'top_right': '右上',
    'top_left': '左上',
    'bottom_right': '右下',
    'bottom_left': '左下',
  };
  static const _colors = {
    '#D32F2F': '紅色',
    '#1565C0': '藍色',
    '#212121': '黑色',
    '#2E7D32': '綠色',
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('照片編號設定'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            value: _position,
            decoration: const InputDecoration(labelText: '編號位置'),
            items: _positions.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (v) => setState(() => _position = v!),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _color,
            decoration: const InputDecoration(labelText: '編號顏色'),
            items: _colors.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (v) => setState(() => _color = v!),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('編號大小'),
              const SizedBox(width: 12),
              Expanded(
                child: Slider(
                  value: _size.toDouble(),
                  min: 16,
                  max: 200,
                  divisions: 46,
                  label: '$_size px',
                  onChanged: (v) => setState(() => _size = v.round()),
                ),
              ),
              SizedBox(width: 48, child: Text('$_size px')),
            ],
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('底色透明'),
            value: _transparent,
            onChanged: (v) => setState(() => _transparent = v ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            NumberingOptions(_position, _color, _size, _transparent),
          ),
          child: const Text('套用'),
        ),
      ],
    );
  }
}
