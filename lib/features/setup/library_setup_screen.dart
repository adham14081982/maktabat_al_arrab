import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/providers/providers.dart';
import '../../core/services/library_source.dart';
import '../home/home_screen.dart';

/// First-run screen when the APK carries no books.
///
/// The library is a single `maktabat_library.zip` produced by
/// `scripts/pack_library.py`. The user copies it to the phone once and imports
/// it here; extraction runs in the app's private storage, so no storage
/// permission is needed on Android 11+.
class LibrarySetupScreen extends ConsumerStatefulWidget {
  const LibrarySetupScreen({super.key});

  @override
  ConsumerState<LibrarySetupScreen> createState() => _LibrarySetupScreenState();
}

class _LibrarySetupScreenState extends ConsumerState<LibrarySetupScreen> {
  bool _busy = false;
  double _progress = 0;
  String _stage = '';
  String? _error;

  Future<void> _pickAndImport() async {
    setState(() {
      _error = null;
      _busy = true;
      _progress = 0;
      _stage = 'اختيار الملف…';
    });

    File? archive;
    try {
      final files = await FilePicker.pickFiles(
        dialogTitle: 'اختر ملف المكتبة',
        type: FileType.any,
      );
      final path = files.isEmpty ? null : files.first.path;
      if (path == null) {
        setState(() => _busy = false);
        return;
      }
      archive = File(path);

      setState(() => _stage = 'قراءة الأرشيف…');
      await LibrarySource.importArchive(
        archive,
        onProgress: (p, name) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _stage = 'استخراج ${(p * 100).toStringAsFixed(0)}٪';
          });
        },
      );

      // The whole library just changed underneath the providers.
      ref.invalidate(libraryServiceProvider);
      ref.invalidate(libraryProvider);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } on FormatException catch (e) {
      setState(() {
        _error = 'هذا الملف ليس مكتبة صالحة (${e.message}).';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = 'تعذّر الاستيراد: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(AppConstants.goldHex);
    const leather = Color(AppConstants.leatherBrownHex);
    const parchment = Color(AppConstants.parchmentHex);

    return Scaffold(
      backgroundColor: parchment,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 148,
                  height: 148,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: leather.withValues(alpha: 0.25),
                        blurRadius: 28,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/icon/app_icon.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.menu_book,
                        size: 72,
                        color: leather,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  'مكتبة العرّاب',
                  style: TextStyle(
                    fontFamily: 'ReemKufi',
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                    color: leather,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'د. أحمد خالد توفيق',
                  style: TextStyle(
                    fontFamily: 'Amiri',
                    fontSize: 17,
                    color: leather.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 36),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: gold.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        _busy
                            ? _stage
                            : 'لتفعيل المكتبة، انقل ملف maktabat_library.zip '
                                'إلى الهاتف ثم اختره من هنا.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontFamily: 'Amiri',
                          fontSize: 16,
                          height: 1.7,
                          color: leather,
                        ),
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 20),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: _progress == 0 ? null : _progress,
                            minHeight: 8,
                            backgroundColor: gold.withValues(alpha: 0.2),
                            valueColor: const AlwaysStoppedAnimation(gold),
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _pickAndImport,
                          icon: const Icon(Icons.folder_open),
                          label: Text(
                            _busy ? 'جارٍ الاستيراد…' : 'اختيار ملف المكتبة',
                            style: const TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: leather,
                            foregroundColor: parchment,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 18),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 14,
                      color: Color(AppConstants.crimsonHex),
                    ),
                  ),
                ],
                const SizedBox(height: 26),
                Text(
                  'يُستورد مرة واحدة فقط. المكتبة تُخزَّن داخل مساحة التطبيق '
                  'الخاصة، فلا تحتاج أي أذونات.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    height: 1.6,
                    color: leather.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
