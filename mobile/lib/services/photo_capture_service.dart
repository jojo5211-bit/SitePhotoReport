import 'package:image_picker/image_picker.dart';

import 'gallery_save_service.dart';

/// Thin wrapper over image_picker for camera capture and gallery picking.
class PhotoCaptureService {
  final ImagePicker _picker = ImagePicker();
  final GallerySaveService _gallery = GallerySaveService();

  /// Capture a single photo with the camera. Returns the file path or null.
  Future<String?> takePhoto() async {
    final xfile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 95,
    );
    return xfile?.path;
  }

  /// Save the already-imported project original as a second copy in the
  /// phone's built-in photo gallery. A denied gallery permission never
  /// prevents the project copy from being saved.
  Future<bool> saveToDeviceGallery(String path) {
    return _gallery.saveImage(path);
  }

  /// Pick multiple photos from the gallery. Returns file paths.
  Future<List<String>> pickFromGallery() async {
    final xfiles = await _picker.pickMultiImage(imageQuality: 95);
    return xfiles.map((x) => x.path).toList();
  }
}
