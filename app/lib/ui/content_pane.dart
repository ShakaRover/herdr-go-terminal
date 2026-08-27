import 'package:flutter/widgets.dart';

/// Keeps single-column content readable on iPad while still filling compact
/// widths such as iPhone and iPad Split View.
const contentPaneMaxWidth = 720.0;

EdgeInsets contentPanePadding(
  BuildContext context,
  EdgeInsets padding, {
  double maxWidth = contentPaneMaxWidth,
}) {
  final extra = (MediaQuery.sizeOf(context).width - maxWidth) / 2;
  return extra > 0
      ? EdgeInsets.fromLTRB(
          padding.left + extra,
          padding.top,
          padding.right + extra,
          padding.bottom,
        )
      : padding;
}

class ContentPane extends StatelessWidget {
  const ContentPane({
    super.key,
    required this.child,
    this.maxWidth = contentPaneMaxWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
