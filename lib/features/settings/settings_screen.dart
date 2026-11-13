import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/providers.dart';
import '../../core/models/reader_settings.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/common_widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(readerSettingsProvider);
    final libraryAsync = ref.watch(libraryProvider);

    final bookCount = libraryAsync.maybeWhen(
      data: (lib) => lib.books.length,
      orElse: () => 0,
    );

    final sectionCount = libraryAsync.maybeWhen(
      data: (lib) => lib.sections.length,
      orElse: () => 0,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // App info header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.seriesAccent('standalone_novels').withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(AppConstants.goldHex).withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.menu_book,
                  size: 48,
                  color: AppTheme.seriesAccent('standalone_novels'),
                ),
                const SizedBox(height: 12),
                Text(
                  AppConstants.appName,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  AppConstants.author,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                const OrnamentalDivider(),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _InfoChip(
                      icon: Icons.book_outlined,
                      label: 'كتاب',
                      value: bookCount.toString(),
                    ),
                    _InfoChip(
                      icon: Icons.category_outlined,
                      label: 'قسم',
                      value: sectionCount.toString(),
                    ),
                    const _InfoChip(
                      icon: Icons.tag_outlined,
                      label: 'إصدار',
                      value: AppConstants.version,
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),
          const OrnamentalDivider(),
          const SizedBox(height: 24),

          // Reading settings section
          Text(
            'إعدادات القراءة',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),

          // Font size
          _SettingSliderRow(
            label: 'حجم الخط',
            icon: Icons.text_fields,
            value: settings.fontSize,
            min: 12,
            max: 28,
            divisions: 16,
            displayValue: settings.fontSize.round().toString(),
            onChanged: (v) =>
                ref.read(readerSettingsProvider.notifier).updateFontSize(v),
          ),

          const SizedBox(height: 12),

          // Line spacing
          _SettingSliderRow(
            label: 'تباعد الأسطر',
            icon: Icons.format_line_spacing,
            value: settings.lineSpacing,
            min: 1.0,
            max: 3.0,
            divisions: 20,
            displayValue: settings.lineSpacing.toStringAsFixed(1),
            onChanged: (v) =>
                ref.read(readerSettingsProvider.notifier).updateLineSpacing(v),
          ),

          const SizedBox(height: 12),

          // Font family
          Text('نوع الخط', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _FontChip(
                label: 'أميري',
                family: 'Amiri',
                selected: settings.fontFamily == 'Amiri',
                onSelect: (fam) => ref
                    .read(readerSettingsProvider.notifier)
                    .updateFontFamily(fam),
              ),
              _FontChip(
                label: 'القاهرة',
                family: 'Cairo',
                selected: settings.fontFamily == 'Cairo',
                onSelect: (fam) => ref
                    .read(readerSettingsProvider.notifier)
                    .updateFontFamily(fam),
              ),
              _FontChip(
                label: 'ريم كوفي',
                family: 'ReemKufi',
                selected: settings.fontFamily == 'ReemKufi',
                onSelect: (fam) => ref
                    .read(readerSettingsProvider.notifier)
                    .updateFontFamily(fam),
              ),
            ],
          ),

          const SizedBox(height: 24),
          const OrnamentalDivider(),
          const SizedBox(height: 24),

          // ── Page-turn direction ──
          // (added) Horizontal flip or vertical scroll, shared by every book.
          Text('اتجاه تصفح الصفحات', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<ReadingAxis>(
            segments: const [
              ButtonSegment(
                value: ReadingAxis.horizontal,
                label: Text('أفقي'),
                icon: Icon(Icons.swap_horiz, size: 18),
              ),
              ButtonSegment(
                value: ReadingAxis.vertical,
                label: Text('رأسي'),
                icon: Icon(Icons.swap_vert, size: 18),
              ),
            ],
            selected: {settings.readingAxis},
            onSelectionChanged: (selection) => ref
                .read(readerSettingsProvider.notifier)
                .updateReadingAxis(selection.first),
            showSelectedIcon: false,
          ),

          const SizedBox(height: 16),

          // ── Double-page scan handling ──
          // Relevant to image-mode (scanned) books only; text books paginate
          // by font size instead.
          Text('الصفحات المزدوجة (للكتب المصوَّرة)',
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<DoublePageSplitMode>(
            segments: const [
              ButtonSegment(value: DoublePageSplitMode.never, label: Text('بدون')),
              ButtonSegment(
                  value: DoublePageSplitMode.auto, label: Text('تلقائي')),
              ButtonSegment(
                  value: DoublePageSplitMode.always, label: Text('دائمًا')),
            ],
            selected: {settings.splitMode},
            onSelectionChanged: (selection) => ref
                .read(readerSettingsProvider.notifier)
                .updateSplitMode(selection.first),
            showSelectedIcon: false,
          ),

          const SizedBox(height: 16),

          // ── فلتر ليلي للحواف المصوَّرة ──
          _ToggleRow(
            label: 'الفلتر الليلي للصفحات المصوَّرة',
            icon: Icons.invert_colors_outlined,
            value: settings.scanNightFilter,
            onChanged: () => ref
                .read(readerSettingsProvider.notifier)
                .toggleScanNightFilter(),
          ),

          const SizedBox(height: 24),
          const OrnamentalDivider(),
          const SizedBox(height: 24),

          // Appearance toggles
          Text(
            'المظهر',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),

          _ToggleRow(
            label: 'الوضع الليلي',
            icon: Icons.nights_stay_outlined,
            value: settings.nightMode,
            onChanged: () => ref
                .read(readerSettingsProvider.notifier)
                .toggleNightMode(),
          ),
          _ToggleRow(
            label: 'تأثير قلب الصفحات',
            icon: Icons.flip,
            value: settings.pageFlipEffect,
            onChanged: () => ref
                .read(readerSettingsProvider.notifier)
                .togglePageFlipEffect(),
          ),

          const SizedBox(height: 24),
          const OrnamentalDivider(),
          const SizedBox(height: 24),

          // Feedback toggles
          Text(
            'التفاعل',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),

          _ToggleRow(
            label: 'اهتزاز عند قلب الصفحة',
            icon: Icons.vibration_outlined,
            value: settings.hapticFeedback,
            onChanged: () => ref
                .read(readerSettingsProvider.notifier)
                .toggleHapticFeedback(),
          ),
          _ToggleRow(
            label: 'صوت قلب الورق',
            icon: Icons.volume_up_outlined,
            value: settings.pageFlipSound,
            onChanged: () => ref
                .read(readerSettingsProvider.notifier)
                .togglePageFlipSound(),
          ),

          const SizedBox(height: 32),

          // About section
          const OrnamentalDivider(),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'تطبيق شخصي غير منشور\n${AppConstants.author}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: const Color(AppConstants.goldHex), size: 24),
        const SizedBox(height: 4),
        Text(value, style: Theme.of(context).textTheme.labelLarge),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

class _SettingSliderRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String displayValue;
  final ValueChanged<double> onChanged;

  const _SettingSliderRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.displayValue,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Icon(icon, color: const Color(AppConstants.goldHex)),
            const SizedBox(width: 12),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const Spacer(),
            Text(displayValue, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _FontChip extends StatelessWidget {
  final String label;
  final String family;
  final bool selected;
  final ValueChanged<String> onSelect;

  const _FontChip({
    required this.label,
    required this.family,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontFamily: family)),
      selected: selected,
      onSelected: (_) => onSelect(family),
      selectedColor: const Color(AppConstants.goldHex).withValues(alpha: 0.3),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final VoidCallback onChanged;

  const _ToggleRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(AppConstants.goldHex)),
      title: Text(label, style: Theme.of(context).textTheme.labelLarge),
      trailing: Switch(
        value: value,
        onChanged: (_) => onChanged(),
        // (الكود القديم يستخدمه) — activeColor deprecated → activeThumbColor
        activeTrackColor: const Color(AppConstants.goldHex).withValues(alpha: 0.4),
        activeThumbColor: const Color(AppConstants.goldHex),
      ),
    );
  }
}
