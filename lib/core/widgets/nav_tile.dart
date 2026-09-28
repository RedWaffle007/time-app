import 'package:flutter/material.dart';

import '../theme/app_icons.dart';
import '../theme/app_theme.dart';
import '../theme/dataviz_tokens.dart';
import '../theme/status_style.dart';

/// One navigation row: a flat outlined card (§6.1) with a leading icon, an
/// optional pending-count badge (the one orange the app trusts, §2.7) and a
/// chevron. Used by your profile's links and by Settings (Batch H1–H2).
class NavTile extends StatelessWidget {
  const NavTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.badgeCount = 0,
    this.showChevron = true,
    this.subtitle,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int badgeCount;
  final bool showChevron;

  /// One muted line under the label, when the row needs explaining.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final leading = Icon(icon, color: context.colors.onSurfaceVariant);
    return Card(
      child: ListTile(
        leading: badgeCount > 0
            ? PendingCountBadge(count: badgeCount, child: leading)
            : leading,
        title: Text(
          label,
          style: context.text.titleMedium?.copyWith(
            color: context.colors.categoricalAccentFor(label),
          ),
        ),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle!,
                style: context.text.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
        trailing: showChevron ? const Icon(AppIcons.openRow) : null,
        onTap: onTap,
      ),
    );
  }
}
