import 'dart:io';
import 'package:flutter/material.dart';

/// Full-screen zoomable/pannable image viewer (matches desktop ImageViewerDialog).
class ImageViewerScreen extends StatelessWidget {
  final File file;
  final String title;
  const ImageViewerScreen({super.key, required this.file, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, style: const TextStyle(fontSize: 14)),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6.0,
          child: Image.file(file, fit: BoxFit.contain),
        ),
      ),
    );
  }
}
