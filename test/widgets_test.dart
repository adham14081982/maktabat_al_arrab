import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maktabat_al_arrab/core/constants/app_constants.dart';
import 'package:maktabat_al_arrab/core/theme/app_theme.dart';
import 'package:maktabat_al_arrab/widgets/common_widgets.dart';

void main() {
  group('AppTheme', () {
    test('Light theme has correct primary color', () {
      final theme = AppTheme.lightTheme;
      expect(theme.colorScheme.primary, const Color(AppConstants.leatherBrownHex));
    });

    test('Dark theme has correct primary color', () {
      final theme = AppTheme.darkTheme;
      expect(theme.colorScheme.primary, const Color(AppConstants.goldHex));
    });

    test('Series accent colors are correct', () {
      expect(AppTheme.seriesAccent('ma_wara_al_tabia'), const Color(AppConstants.maWaraAccent));
      expect(AppTheme.seriesAccent('fantazia'), const Color(AppConstants.fantaziaAccent));
      expect(AppTheme.seriesAccent('safari'), const Color(AppConstants.safariAccent));
      expect(AppTheme.seriesAccent('standalone_novels'), const Color(AppConstants.standaloneAccent));
      expect(AppTheme.seriesAccent('translations'), const Color(AppConstants.translationsAccent));
      expect(AppTheme.seriesAccent('unknown'), const Color(AppConstants.goldHex));
    });
  });

  group('CommonWidgets', () {
    testWidgets('EmptyState displays message', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(message: 'رسالة فارغة'),
          ),
        ),
      );

      expect(find.text('رسالة فارغة'), findsOneWidget);
    });

    testWidgets('OrnamentalDivider renders', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: OrnamentalDivider(),
          ),
        ),
      );

      expect(find.byType(OrnamentalDivider), findsOneWidget);
    });

    testWidgets('BookCover renders with placeholder for null cover', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: BookCover(
              coverPath: null,
              title: 'كتاب تجريبي',
            ),
          ),
        ),
      );

      expect(find.byType(BookCover), findsOneWidget);
      expect(find.text('كتاب تجريبي'), findsOneWidget);
    });

    testWidgets('SectionHeader displays title and subtitle', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionHeader(
              title: 'عنوان القسم',
              subtitle: 'وصف القسم',
            ),
          ),
        ),
      );

      expect(find.text('عنوان القسم'), findsOneWidget);
      expect(find.text('وصف القسم'), findsOneWidget);
    });
  });

  group('AppConstants', () {
    test('App name is correct', () {
      expect(AppConstants.appName, 'مكتبة العرّاب');
    });

    test('Hive box names are defined', () {
      expect(AppConstants.settingsBox, 'settings');
      expect(AppConstants.progressBox, 'reading_progress');
      expect(AppConstants.bookmarksBox, 'bookmarks');
    });

    test('Default settings values are sensible', () {
      expect(AppConstants.defaultFontSize, 18.0);
      expect(AppConstants.defaultFontFamily, 'Amiri');
      expect(AppConstants.defaultLineSpacing, 1.8);
      expect(AppConstants.defaultNightMode, false);
    });
  });
}
