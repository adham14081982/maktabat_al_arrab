/// Represents a book in the library
class Book {
  final String id;
  final String title;
  final String series;       // section ID: ma_wara_al_tabia, fantazia, etc.
  final int pageCount;
  final String? cover;       // asset path to cover image
  final String contentMode;  // "image", "text", or "hybrid" (image + OCR text)
  final double qualityScore;
  final String jsonFile;     // path to detailed book JSON

  const Book({
    required this.id,
    required this.title,
    required this.series,
    required this.pageCount,
    this.cover,
    required this.contentMode,
    required this.qualityScore,
    required this.jsonFile,
  });

  factory Book.fromJson(Map<String, dynamic> json) {
    return Book(
      id: json['id'] as String,
      title: json['title'] as String,
      series: json['series'] as String,
      pageCount: (json['page_count'] as num?)?.toInt() ?? 0,
      cover: json['cover'] as String?,
      contentMode: json['content_mode'] as String? ?? 'text',
      qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
      jsonFile: json['json_file'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'series': series,
        'page_count': pageCount,
        'cover': cover,
        'content_mode': contentMode,
        'quality_score': qualityScore,
        'json_file': jsonFile,
      };
}

/// Detailed book data loaded from individual book JSON
class BookDetail {
  final String id;
  final String title;
  final String originalFilename;
  final int pageCount;
  final String? cover;
  final double qualityScore;
  final String contentMode;    // "image", "text", or "hybrid"
  final List<Chapter> chapters;
  final List<String> images;   // image paths for image-mode books

  /// Per-page OCR text for hybrid books: `[{image, text, confidence}]`,
  /// aligned with the page-image order. Empty for image/text books.
  final List<OcrPage> ocrPages;
  final String series;
  final String? zipAsset;      // asset zip containing page images (image mode)

  const BookDetail({
    required this.id,
    required this.title,
    required this.originalFilename,
    required this.pageCount,
    this.cover,
    required this.qualityScore,
    required this.contentMode,
    required this.chapters,
    required this.images,
    required this.ocrPages,
    required this.series,
    this.zipAsset,
  });

  /// Whether the book carries per-page OCR text (hybrid mode).
  bool get hasOcrText => ocrPages.any((p) => p.text.trim().isNotEmpty);

  factory BookDetail.fromJson(Map<String, dynamic> json) {
    return BookDetail(
      id: json['id'] as String,
      title: json['title'] as String,
      originalFilename: json['original_filename'] as String? ?? '',
      pageCount: (json['page_count'] as num?)?.toInt() ?? 0,
      cover: json['cover'] as String?,
      qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
      contentMode: json['content_mode'] as String? ?? 'text',
      chapters: (json['chapters'] as List?)
              ?.map((c) => Chapter.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
      images: (json['images'] as List?)?.cast<String>() ?? [],
      ocrPages: (json['ocr_pages'] as List?)
              ?.map((p) => OcrPage.fromJson(p as Map<String, dynamic>))
              .toList() ??
          [],
      series: json['series'] as String? ?? '',
      zipAsset: json['zip_asset'] as String?,
    );
  }
}

/// One page's OCR result inside a hybrid book.
class OcrPage {
  final String image;   // page-image file name inside the book zip
  final String text;

  /// Mean word confidence (0-100) reported by the engine. Null on pages the
  /// reviewer corrected manually (they are treated as exact).
  final double? confidence;

  const OcrPage({
    required this.image,
    required this.text,
    this.confidence,
  });

  factory OcrPage.fromJson(Map<String, dynamic> json) {
    return OcrPage(
      image: json['image'] as String? ?? '',
      text: json['text'] as String? ?? '',
      confidence: (json['confidence'] as num?)?.toDouble(),
    );
  }
}

/// Represents a chapter within a book
class Chapter {
  final String title;
  final String text;

  const Chapter({
    required this.title,
    required this.text,
  });

  factory Chapter.fromJson(Map<String, dynamic> json) {
    return Chapter(
      title: json['title'] as String? ?? '',
      text: json['text'] as String? ?? '',
    );
  }
}
