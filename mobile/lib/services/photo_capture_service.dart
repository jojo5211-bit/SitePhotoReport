import 'package:image_picker/image_picker.dart';

/// Thin wrapper over image_picker for camera capture and gallery picking.
class PhotoCaptureService {
  final ImagePicker _picker = ImagePicker();

  /// Capture a single photo with the camera. Returns the file path or null.
  Future<String?> takePhoto() async {
    final xfile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 95,
    );
    return xfile?.path;
  }

  /// Pick multiple photos from the gallery. Returns file paths.
  Future<List<String>> pickFromGallery() async {
    final xfiles = await _picker.pickMultiImage(imageQuality: 95);
    return xfiles.map((x) => x.path).toList();
  }
}
