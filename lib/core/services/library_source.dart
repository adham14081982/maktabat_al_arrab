import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Where the library actually lives.
///
/// Two modes, one API:
///
///  * **bundled** — everything sits in `assets/` inside the APK (the old,
///    861 MB build). `_root` is null and reads go through `rootBundle`.
///  * **external** — the user imported `maktabat_library.zip` and it was
///    extracted into the app's support directory. Reads go through `dart:io`.
///
/// Every path handed to this class is relative to the library root, e.g.
/// `books/book_001.zip` or `covers/book_001.webp`, and is identical in both
/// modes. That is what lets the rest of the app stay unaware of the switch.
class LibrarySource {
  LibrarySource._();

  static Directory? _root;

  /// Marker written only after a *complete* extraction, so an interrupted
  /// import is never mistaken for a working library.
  static const String markerFile = '.library-ready';

  /// Folder name inside the app support directory.
  static const String folderName = 'library';

  static bool get isExternal => _root != null;
  static String? get externalPath => _root?.path;

  /// Root of the app's private storage, where the imported library lives.
  static Future<Directory> libraryDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/$folderName');
  }

  /// Attach an already-imported library if this device has one.
  /// Returns true when the app is running from external storage.
  static Future<bool> init() async {
    try {
      final dir = await libraryDir();
      if (await File('${dir.path}/$markerFile').exists()) {
        _root = dir;
        return true;
      }
    } catch (_) {
      // Storage unreadable — fall back to the bundled assets.
    }
    _root = null;
    return false;
  }

  /// Forget the external library (used by «إزالة المكتبة» in settings).
  static Future<void> detach() async {
    _root = null;
    try {
      final dir = await libraryDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Nothing to clean up.
    }
  }

  static String _strip(String rel) =>
      rel.startsWith('assets/') ? rel.substring('assets/'.length) : rel;

  /// Read a UTF-8 text file from the library.
  static Future<String> readText(String rel) {
    final path = _strip(rel);
    final root = _root;
    if (root == null) return rootBundle.loadString('assets/$path');
    return File('${root.path}/$path').readAsString();
  }

  /// Read raw bytes (used for the per-book page zips).
  static Future<Uint8List> readBytes(String rel) async {
    final path = _strip(rel);
    final root = _root;
    if (root == null) {
      final data = await rootBundle.load('assets/$path');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    return File('${root.path}/$path').readAsBytes();
  }

  /// An [ImageProvider] for a cover, valid in both modes.
  static ImageProvider image(String rel) {
    final path = _strip(rel);
    final root = _root;
    if (root == null) return AssetImage('assets/$path');
    return FileImage(File('${root.path}/$path'));
  }

  /// True when the file exists in the active library.
  static Future<bool> exists(String rel) async {
    final path = _strip(rel);
    final root = _root;
    if (root == null) {
      try {
        await rootBundle.load('assets/$path');
        return true;
      } catch (_) {
        return false;
      }
    }
    return File('${root.path}/$path').exists();
  }

  // ------------------------------------------------------------- import ----

  /// Extract an archive produced by `scripts/pack_library.py`.
  ///
  /// Extraction goes to a sibling staging folder and is only promoted to the
  /// real library folder once every entry is written and the marker exists —
  /// a phone that dies mid-import keeps its previous library intact.
  ///
  /// The archive is read lazily through [InputFileStream], so peak memory is
  /// one entry (the largest book zip, ~12 MB), not the whole 861 MB.
  static Future<void> importArchive(
    File archive, {
    required void Function(double progress, String label) onProgress,
  }) async {
    final target = await libraryDir();
    final staging = Directory('${target.path}.importing');
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);

    InputFileStream? input;
    try {
      input = InputFileStream(archive.path);
      final decoder = ZipDecoder();
      final zip = decoder.decodeBuffer(input);
      final entries = zip.files.where((f) => f.isFile).toList();
      final total = entries.length;

      for (var i = 0; i < total; i++) {
        final entry = entries[i];
        final name = entry.name.replaceAll('\\', '/');

        // Refuse absolute paths and traversal: an archive is untrusted input.
        if (name.startsWith('/') || name.contains('..')) continue;

        final outPath = '${staging.path}/$name';
        final slash = outPath.lastIndexOf('/');
        if (slash > 0) {
          await Directory(outPath.substring(0, slash)).create(recursive: true);
        }
        entry.writeContent(OutputFileStream(outPath), freeMemory: true);

        if (i % 20 == 0 || i == total - 1) {
          onProgress((i + 1) / total, name);
          // Let the frame that shows progress actually paint.
          await Future<void>.delayed(Duration.zero);
        }
      }

      await File('${staging.path}/$markerFile')
          .writeAsString(DateTime.now().toIso8601String());

      // An archive that lacks the index is not a library — refuse it before it
      // replaces a working one.
      if (!await File('${staging.path}/library.json').exists()) {
        throw const FormatException('library.json غير موجود في الملف');
      }

      if (await target.exists()) await target.delete(recursive: true);
      await staging.rename(target.path);
      _root = target;
    } finally {
      input?.close();
      // A failed import must not leave gigabytes of half-extracted pages.
      if (await staging.exists()) {
        try {
          await staging.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// Total bytes already extracted, for the «مساحة المكتبة» row in settings.
  static Future<int> installedBytes() async {
    final dir = _root;
    if (dir == null) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }
}
