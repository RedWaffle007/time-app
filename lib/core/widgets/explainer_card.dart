import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

/// A short, persistent description of a screen's purpose.
///
/// It sits outside async content so the explanation remains visible while the
/// feed is loading, empty, or showing a retry state.
class ExplainerCard extends StatelessWidget {
  const ExplainerCard(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: Space.cardPadding,
        child: SizedBox(
          width: double.infinity,
          child: Text(message, style: context.text.bodyMedium),
        ),
      ),
    );
  }
}
