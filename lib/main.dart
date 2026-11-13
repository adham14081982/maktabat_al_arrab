import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/services/storage_service.dart';
import 'core/services/library_source.dart';
import 'core/providers/providers.dart';
import 'features/splash/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Decide where the books come from before any widget reads them: the
  // imported folder on this device, or the assets bundled in the APK.
  await LibrarySource.init();

  // Initialize Hive for local storage
  await Hive.initFlutter();

  // Open Hive boxes
  await Hive.openBox(AppConstants.settingsBox);
  await Hive.openBox(AppConstants.progressBox);
  await Hive.openBox(AppConstants.bookmarksBox);

  // Initialize storage service with opened boxes
  StorageService.instance.init();

  runApp(
    const ProviderScope(
      child: MaktabatAlArrabApp(),
    ),
  );
}

class MaktabatAlArrabApp extends ConsumerWidget {
  const MaktabatAlArrabApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      title: 'مكتبة العرّاب',
      debugShowCheckedModeBanner: false,

      // RTL Arabic
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child!,
        );
      },

      // Antique library theme
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,

      // Start with splash screen
      home: const SplashScreen(),
    );
  }
}
