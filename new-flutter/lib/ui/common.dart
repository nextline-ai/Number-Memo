import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/models.dart';
import '../services/catalog_service.dart';

void showMessage(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<void> attempt(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) showMessage(context, success);
  } catch (error) {
    if (context.mounted) showMessage(context, '$error');
  }
}

Future<void> openWebsite(BuildContext context, String address) async {
  final uri = Uri.tryParse(address);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty) {
    showMessage(context, '올바른 웹 주소가 아닙니다.');
    return;
  }
  await attempt(context, () async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw Exception('브라우저를 열 수 없습니다.');
    }
  });
}

Map<String, String> imageHeaders(CatalogItem item) => {
  'User-Agent': CatalogService.userAgent,
  'Referer': item.mode == LibraryMode.books
      ? '${Uri.tryParse(item.sourceUrl)?.origin ?? 'https://hitomi.la'}/reader/${item.remoteId}.html'
      : item.sourceUrl,
};

class CatalogArtwork extends StatelessWidget {
  const CatalogArtwork({
    super.key,
    required this.item,
    this.fit = BoxFit.cover,
  });
  final CatalogItem item;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: color.surfaceContainerHighest,
      child: Center(
        child: Icon(
          item.mode == LibraryMode.books
              ? Icons.menu_book_rounded
              : Icons.image_outlined,
          size: 44,
          color: color.onSurfaceVariant.withValues(alpha: .45),
        ),
      ),
    );
    if (item.thumbnailUrl.isEmpty) return placeholder;
    return Image.network(
      item.thumbnailUrl,
      headers: imageHeaders(item),
      fit: fit,
      errorBuilder: (_, _, _) => placeholder,
      loadingBuilder: (_, child, progress) =>
          progress == null ? child : placeholder,
    );
  }
}

class CatalogCard extends StatelessWidget {
  const CatalogCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.saved,
    this.onSave,
    this.selected = false,
    this.selectionMode = false,
    this.onSelect,
  });
  final CatalogItem item;
  final VoidCallback onTap;
  final bool saved;
  final VoidCallback? onSave;
  final bool selected, selectionMode;
  final VoidCallback? onSelect;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selectionMode ? selected : null,
    child: Card(
      margin: EdgeInsets.zero,
      shape: selected && selectionMode
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      child: InkWell(
        onTap: selectionMode ? onSelect : onTap,
        onLongPress: onSelect ?? onSave,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CatalogArtwork(item: item),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton.filledTonal(
                      tooltip: selectionMode
                          ? (selected ? '선택 해제' : '작품 선택')
                          : (saved ? '저장됨' : '보관함에 저장'),
                      onPressed: selectionMode ? onSelect : onSave,
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        selectionMode
                            ? (selected
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded)
                            : (saved
                                  ? Icons.bookmark_rounded
                                  : Icons.bookmark_border_rounded),
                      ),
                    ),
                  ),
                  if (item.pageCount > 0)
                    Positioned(
                      left: 10,
                      bottom: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .65),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '${item.pageCount}p',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                item.artists.isNotEmpty
                    ? item.artists.join(', ')
                    : '#${item.remoteId ?? item.id}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Builds cards only for the visible rows and the scroll view's cache extent.
class CatalogSliverGrid extends StatelessWidget {
  const CatalogSliverGrid({
    super.key,
    required this.items,
    required this.columns,
    required this.isSaved,
    required this.onOpen,
    required this.onSave,
    this.selectionMode = false,
    this.isSelected,
    this.onSelect,
  });
  final List<CatalogItem> items;
  final int columns;
  final bool Function(CatalogItem) isSaved;
  final void Function(CatalogItem) onOpen, onSave;
  final bool selectionMode;
  final bool Function(CatalogItem)? isSelected;
  final ValueChanged<CatalogItem>? onSelect;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final count = ((constraints.crossAxisExtent + 16) / 176).floor().clamp(
        1,
        columns,
      );
      final width = (constraints.crossAxisExtent - (count - 1) * 16) / count;
      return SliverGrid.builder(
        itemCount: items.length,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: count,
          mainAxisSpacing: 18,
          crossAxisSpacing: 16,
          mainAxisExtent: width * 1.22 + 94,
        ),
        itemBuilder: (context, index) => CatalogCard(
          key: ValueKey(items[index].id),
          item: items[index],
          saved: isSaved(items[index]),
          onTap: () => onOpen(items[index]),
          onSave: () => onSave(items[index]),
          selectionMode: selectionMode,
          selected: isSelected?.call(items[index]) ?? false,
          onSelect: onSelect == null ? null : () => onSelect!(items[index]),
        ),
      );
    },
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                icon,
                size: 38,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.65,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return Center(child: content);
        return SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: content),
          ),
        );
      },
    );
  }
}

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String action = '삭제',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

// Matches native-ios AppDatabase.curatedFolderColors.
const folderColors = [
  0xff2563eb,
  0xff059669,
  0xffea580c,
  0xffe11d48,
  0xff7c3aed,
  0xff0891b2,
  0xffd97706,
  0xffdb2777,
  0xff4f46e5,
  0xff0d9488,
  0xff65a30d,
  0xffc026d3,
  0xffdc2626,
  0xff9333ea,
  0xff0284c7,
  0xffb45309,
  0xff16a34a,
  0xfff97316,
  0xff6366f1,
  0xff14b8a6,
  0xff84cc16,
  0xffec4899,
  0xffa855f7,
  0xff3b82f6,
  0xff10b981,
  0xfff59e0b,
  0xffef4444,
  0xff64748b,
];
