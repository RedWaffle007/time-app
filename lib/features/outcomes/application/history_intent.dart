import 'package:flutter_riverpod/flutter_riverpod.dart';

class HistoryIntent {
  const HistoryIntent({required this.seq, this.itemId});

  final int seq;
  final String? itemId;
}

class HistoryIntentNotifier extends Notifier<HistoryIntent?> {
  int _seq = 0;

  @override
  HistoryIntent? build() => null;

  void open() => state = HistoryIntent(seq: ++_seq);

  void highlightItem(String itemId) =>
      state = HistoryIntent(seq: ++_seq, itemId: itemId);
}

final historyIntentProvider =
    NotifierProvider<HistoryIntentNotifier, HistoryIntent?>(
      HistoryIntentNotifier.new,
    );
