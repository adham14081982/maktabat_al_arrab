/// Represents a book section (series category)
class Section {
  final String id;
  final String title;
  final String subtitle;
  final String colorAccent;
  final String icon;

  const Section({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.colorAccent,
    required this.icon,
  });

  factory Section.fromJson(Map<String, dynamic> json) {
    return Section(
      id: json['id'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String,
      colorAccent: json['color_accent'] as String,
      icon: json['icon'] as String,
    );
  }
}
