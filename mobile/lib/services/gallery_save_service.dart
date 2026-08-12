import 'package:gal/gal.dart';

/// Saves a camera capture to the device's system photo gallery.
///
/// Project storage remains the source of truth for the report. Gallery saving
/// is a second, non-destructive copy so users can also find the photo in the
/// phone's built-in Photos/Gallery app.
class GallerySaveService {
  Future<bool> saveImage(String path) async {
    try {
      if (!await Gal.hasAccess()) {
        final granted = await Gal.requestAccess();
        if (!granted) return false;
      }
      await Gal.putImage(path);
      return true;
    } on GalException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
