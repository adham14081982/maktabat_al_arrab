import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../core/models/reader_palette.dart';
import '../../core/services/library_service.dart' show Library;

/// Runs in a background isolate: scanning a 300-page book must not stutter the
/// page turn that is still animating behind the sheet.
///
/// The message and the result are plain maps of primitives, which is all
/// `compute` can carry across an isolate boundary.
List<Map<String, Object>> searchPagesInIsolate(Map<String, Object> message) {
  final pages = (message['pages'] as List).cast<String>();
  final query = Library.normalizeArabic(message['query'] as String).trim();
  final limit = message['limit'] as int? ?? 60;
  if (query.isEmpty) return const [];

  final hits = <Map<String, Object>>[];
  for (var i = 0; i < pages.length; i++) {
    final page = pages[i];
    if (page.trim().isEmpty) continue;

    final normalized = Library.normalizeArabic(page);
    final idx = normalized.indexOf(query);
    if (idx < 0) continue;

    // Normalisation is length-preserving for the substitutions used here
    // (one rune in, one rune out), so the index maps back onto the original.
    final start = (idx - 60).clamp(0, page.length);
    final end = (idx + query.length + 90).clamp(0, page.length);
    hits.add({
      'page': i,
      'excerpt': page
          .substring(start, end)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim(),
    });
    if (hits.length >= limit) break;
  }
  return hits;
}

/// Bottom sheet that searches inside the book currently open.
///
/// Spec §7 asks for in-book search; the library-wide search screen answers a
/// different question ("which of my 293 books mentions X"), and jumping back
/// to the reader from there loses the page you were on.
class InBookSearchSheet extends StatefulWidget {
  final List<String> pages;
  final ReaderPalette palette;
  final ValueChanged<int> onSelect;

  const InBookSearchSheet({
    super.key,
    required this.pages,
    required this.palette,
    required this.onSelect,
  });

  @override
  State<InBookSearchSheet> createState() => _InBookSearchSheetState();
}

class _InBookSearchSheetState extends State<InBookSearchSheet> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  List<Map<String, Object>>? _hits;
  bool _busy = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _run(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _hits = null;
        _busy = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _lastQuery = q;
    });

    final result = await compute(searchPagesInIsolate, <String, Object>{
      'pages': widget.pages,
      'query': q,
      'limit': 60,
    });

    if (!mounted || _lastQuery != q) return;
    setState(() {
      _hits = result;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final hits = _hits;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.62,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _run,
                      onChanged: (v) {
                        if (v.trim().isEmpty) _run('');
                      },
                      style: TextStyle(
                        fontFamily: 'Amiri',
                        fontSize: 17,
                        color: palette.ink,
                      ),
                      decoration: InputDecoration(
                        hintText: 'ابحث داخل هذا الكتاب…',
                        hintStyle: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 14,
                          color: palette.ink.withValues(alpha: 0.45),
                        ),
                        prefixIcon: Icon(
                          Icons.search,
                          size: 20,
                          color: palette.ink.withValues(alpha: 0.5),
                        ),
                        filled: true,
                        fillColor: palette.ink.withValues(alpha: 0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: Icon(Icons.close, color: palette.ink, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            if (_busy)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            Expanded(
              child: hits == null
                  ? _hint(palette)
                  : hits.isEmpty
                      ? _empty(palette)
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          itemCount: hits.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            color: palette.ink.withValues(alpha: 0.08),
                          ),
                          itemBuilder: (context, i) {
                            final hit = hits[i];
                            final page = hit['page'] as int;
                            return ListTile(
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor:
                                    palette.ink.withValues(alpha: 0.07),
                                child: Text(
                                  '${page + 1}',
                                  textDirection: TextDirection.ltr,
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: palette.ink.withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                              title: Text(
                                hit['excerpt'] as String,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'Amiri',
                                  fontSize: 15,
                                  height: 1.6,
                                  color: palette.ink,
                                ),
                              ),
                              onTap: () => widget.onSelect(page),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hint(ReaderPalette palette) => Center(
        child: Text(
          'اكتب كلمة أو جملة. البحث يتجاهل التشكيل\n'
          'ويوحّد الألف والهمزة والتاء المربوطة.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 13,
            height: 1.7,
            color: palette.ink.withValues(alpha: 0.45),
          ),
        ),
      );

  Widget _empty(ReaderPalette palette) => Center(
        child: Text(
          'لا نتائج في هذا الكتاب.',
          style: TextStyle(
            fontFamily: 'Cairo',
            fontSize: 14,
            color: palette.ink.withValues(alpha: 0.5),
          ),
        ),
      );
}
