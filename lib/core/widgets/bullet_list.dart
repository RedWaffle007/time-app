import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import '../theme/dataviz_tokens.dart';

/// A consistent, hanging-indent treatment for short explanatory lists.
///
/// The marker is a themed icon rather than a character embedded in text, so
/// wrapping content aligns under the first word and every surface shares the
/// same spacing, size and semantic structural accent.
class BulletList extends StatelessWidget {
  const BulletList({
    super.key,
    required this.items,
    this.semanticLabel = 'Details',
    this.style,
  });

  final List<Widget> items;
  final String semanticLabel;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final markerColor = context.colors.categoricalAccentFor(semanticLabel);
    final textStyle = style ?? context.text.bodyMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < items.length; index++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Space.sm),
                child: Icon(
                  AppIcons.bullet,
                  size: Sizes.bulletMarker,
                  color: markerColor,
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: textStyle,
                  child: items[index],
                ),
              ),
            ],
          ),
          if (index != items.length - 1) const SizedBox(height: Space.sm),
        ],
      ],
    );
  }
}
