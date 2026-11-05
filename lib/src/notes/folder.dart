/// A folder in the sidebar. Folders nest, and the tab strip groups open tabs
/// by folder, so a folder is also a tab group.
class Folder {
  Folder({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.parentId,
    this.expanded = true,
    this.tabsCollapsed = false,
    this.unknownFields = const {},
  });

  final String id;
  String name;

  /// The folder this one sits in, or null at the top level.
  String? parentId;

  /// Whether the sidebar shows what is inside.
  bool expanded;

  /// Whether the tab strip folds this folder's tabs into its label.
  bool tabsCollapsed;

  DateTime createdAt;
  DateTime updatedAt;

  /// Fields a newer GPad synced for this folder that this one doesn't
  /// know, kept as they came and synced back unchanged.
  Map<String, Object?> unknownFields;

  /// [name], or "Untitled folder" if it has been cleared.
  String get displayName => name.trim().isEmpty ? 'Untitled folder' : name;
}
