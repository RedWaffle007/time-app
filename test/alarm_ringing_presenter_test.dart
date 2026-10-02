import 'package:flutter_test/flutter_test.dart';
import 'package:time_app/features/reminders/application/alarm_ringing_presenter.dart';
import 'package:time_app/features/reminders/data/alarm_sound.dart';
import 'package:time_app/routing/app_router.dart';

/// R5 (2026-10-02, Xiaomi report): an alarm rang with only its tone and
/// nothing on screen. The open app now shows the ringing alarm itself.
class _Sound implements AlarmSound {
  String? ringing;
  void Function(String)? listener;

  @override
  Future<String?> ringingItem() async => ringing;

  @override
  void onRinging(void Function(String itemId)? listener) =>
      this.listener = listener;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Sound sound;
  late List<String> opened;
  Uri? here;

  AlarmRingingPresenter presenter() => AlarmRingingPresenter(
    sound: sound,
    open: opened.add,
    currentLocation: () => here,
  );

  setUp(() {
    sound = _Sound();
    opened = [];
    here = Uri.parse('/plan');
  });

  test('a ring that starts while the app is open shows its alarm', () {
    presenter().start();
    sound.listener!('item-1');
    expect(opened, ['item-1']);
  });

  test('opening or resuming the app mid-ring shows that alarm', () async {
    sound.ringing = 'item-2';
    await presenter().checkNow();
    expect(opened, ['item-2']);
  });

  test('nothing ringing: nothing opens', () async {
    await presenter().checkNow();
    expect(opened, isEmpty);
  });

  test('never opens the alarm already on screen', () async {
    here = Uri.parse(Routes.alarmForItem('item-3'));
    sound.ringing = 'item-3';
    final p = presenter()..start();
    await p.checkNow();
    sound.listener!('item-3');
    expect(opened, isEmpty);
  });

  test('a different alarm on screen still gives way to the ringing one', () {
    here = Uri.parse(Routes.alarmForItem('old'));
    presenter().show('new');
    expect(opened, ['new']);
  });

  test('dispose stops listening', () {
    presenter()
      ..start()
      ..dispose();
    expect(sound.listener, isNull);
  });
}
