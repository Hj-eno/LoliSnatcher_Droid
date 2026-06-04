/// A node in an Eagle library's folder tree (from `/api/folder/list`).
class EagleFolder {
  const EagleFolder({
    required this.id,
    required this.name,
    required this.children,
  });

  factory EagleFolder.fromJson(Map<String, dynamic> json) {
    final dynamic rawChildren = json['children'];
    return EagleFolder(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      children: rawChildren is List
          ? rawChildren
                .whereType<Map<String, dynamic>>()
                .map(EagleFolder.fromJson)
                .toList()
          : const [],
    );
  }

  final String id;
  final String name;
  final List<EagleFolder> children;

  bool get hasChildren => children.isNotEmpty;
}
