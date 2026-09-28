import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Where a highlighted card is brought to: a fifth of the way down the list,
/// the same alignment every deep-link reveal passes to `ensureVisible`.
const kHighlightAlignment = 0.2;

/// Frames a landed card is still watched for, because a day group opening or
/// a section loading above it can move it after the first reveal.
const kHighlightSettleFrames = 8;

/// Whether the card at [context] sits where the reveal puts it, or as near as
/// the list's ends allow.
///
/// Not "some of it is on screen" (device report 2026-09-28): a card peeking a
/// few pixels at the bottom edge, or behind the nav bar, passed that test and
/// the user had to scroll to the plan they had tapped. The target is clamped to
/// the scroll range, so a card near either end still counts once the list is
/// as far as it goes.
bool isHighlightRevealed(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return false;
  final viewport = RenderAbstractViewport.maybeOf(box);
  final position = Scrollable.maybeOf(context)?.position;
  if (viewport == null ||
      position == null ||
      !position.hasPixels ||
      !position.hasContentDimensions) {
    return false;
  }
  final target = viewport
      .getOffsetToReveal(box, kHighlightAlignment)
      .offset
      .clamp(position.minScrollExtent, position.maxScrollExtent);
  return (position.pixels - target).abs() <= 1;
}
