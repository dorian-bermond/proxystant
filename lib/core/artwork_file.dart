import 'dart:io';

import '../data/db/app_database.dart' as db;

/// Whether the artwork's original image file is present on disk.
Future<bool> artworkFileExists(db.Artwork artwork) =>
    File(artwork.localPath).exists();
