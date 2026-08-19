import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// THROWAWAY SPIKE — not the product, not the design system, no tokens.
///
/// This screen schedules nothing itself. Every alarm is armed in Kotlin, because
/// the measurement has to survive the death of this process. All Dart does is
/// press the button and read the CSV back afterwards.
void main() => runApp(const SpikeApp());

const _channel = MethodChannel('com.timeapp.alarm_spike/spike');

class SpikeApp extends StatelessWidget {
  const SpikeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Alarm Spike',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2E7D32),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: const SpikeHome(),
      );
}

class SpikeHome extends StatefulWidget {
  const SpikeHome({super.key});
  @override
  State<SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<SpikeHome> with WidgetsBindingObserver {
  Map<String, dynamic> _status = {};
  String _log = '';
  String _lastAction = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final s = await _channel.invokeMapMethod<String, dynamic>('status');
    final l = await _channel.invokeMethod<String>('readLog');
    if (!mounted) return;
    setState(() {
      _status = s ?? {};
      _log = l ?? '';
    });
  }

  Future<void> _scheduleIn(Duration d) async {
    final at = DateTime.now().add(d);
    await _scheduleAt(at);
  }

  Future<void> _scheduleAt(DateTime at) async {
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'scheduleAt',
      {'epochMillis': at.millisecondsSinceEpoch},
    );
    final failures = (res ?? {}).entries.where((e) => e.value != 'ok').toList();
    setState(() {
      _lastAction = failures.isEmpty
          ? 'Armed 4 variants for ${_hhmmss(at)}'
          : 'Armed with FAILURES: ${failures.map((e) => "${e.key}=${e.value}").join(", ")}';
    });
    await _refresh();
  }

  /// The overnight run. Picks the next occurrence of the chosen wall time, so
  /// "6:30" tapped at 23:00 means tomorrow morning, not seven hours ago.
  Future<void> _scheduleAtWallTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 6, minute: 30),
    );
    if (t == null) return;
    final now = DateTime.now();
    var at = DateTime(now.year, now.month, now.day, t.hour, t.minute);
    if (!at.isAfter(now)) at = at.add(const Duration(days: 1));
    await _scheduleAt(at);
  }

  String _hhmmss(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final rows = _parseLog(_log);
    final fires = rows.where((r) => r.event == 'FIRED').toList().reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarm Spike'),
        actions: [
          IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _statusCard(),
          const SizedBox(height: 12),
          _scheduleCard(),
          const SizedBox(height: 12),
          _resultsCard(fires, rows),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final canExact = _status['canScheduleExact'] == true;
    final battOpt = _status['battOptIgnored'] == true;
    final notif = _status['notificationsGranted'] == true;
    final nextAlarm = (_status['nextAlarmClock'] as int?) ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_status['manufacturer'] ?? '?'} ${_status['model'] ?? ''} · API ${_status['sdkInt'] ?? '?'}',
                style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            _flag('Exact alarms allowed', canExact,
                'SCHEDULE_EXACT_ALARM — without this, two of four variants fail'),
            _flag('Battery unrestricted', battOpt,
                'Power allowlist — also an independent route to exact alarms'),
            _flag('Notifications allowed', notif, 'Only affects visibility, not the log'),
            if (nextAlarm > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'System next alarm clock: ${_hhmmss(DateTime.fromMillisecondsSinceEpoch(nextAlarm))}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 4, children: [
              _btn('Exact alarm', () => _call('openExactAlarmSettings')),
              _btn('Battery', () => _call('openBatteryOptimization')),
              _btn('Autostart', () => _call('openAutostart')),
              _btn('Notifications', () => _call('requestNotifications')),
              _btn('App info', () => _call('openAppDetails')),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _scheduleCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Arm all four variants at one instant',
                  style: Theme.of(context).textTheme.titleMedium),
              const Text(
                'ALARM_CLOCK · EXACT_IDLE · INEXACT_IDLE · WORKMANAGER',
                style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: [
                _btn('+2 min', () => _scheduleIn(const Duration(minutes: 2))),
                _btn('+15 min', () => _scheduleIn(const Duration(minutes: 15))),
                _btn('+60 min', () => _scheduleIn(const Duration(minutes: 60))),
                _btn('At time…', _scheduleAtWallTime),
                _btn('Cancel all', () async {
                  await _call('cancelAll');
                  setState(() => _lastAction = 'Cancelled');
                }),
              ]),
              if (_lastAction.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_lastAction,
                      style: TextStyle(
                          color: _lastAction.contains('FAIL')
                              ? Colors.orange
                              : Colors.greenAccent)),
                ),
            ],
          ),
        ),
      );

  Widget _resultsCard(List<_Row> fires, List<_Row> all) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text('Results',
                        style: Theme.of(context).textTheme.titleMedium)),
                IconButton(
                  tooltip: 'Copy whole CSV',
                  icon: const Icon(Icons.copy),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _log));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('CSV copied')));
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Clear log',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await _call('clearLog');
                    await _refresh();
                  },
                ),
              ]),
              if (fires.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No fires recorded yet.'),
                )
              else
                ...fires.map(_fireRow),
              const Divider(),
              Text('Every event (${all.length})',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Colors.black26,
                child: SelectableText(
                  _log.isEmpty ? '(empty)' : _log,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                ),
              ),
              const SizedBox(height: 6),
              Text('${_status['logPath'] ?? ''}',
                  style: const TextStyle(fontSize: 10, color: Colors.white38)),
            ],
          ),
        ),
      );

  Widget _fireRow(_Row r) {
    final d = double.tryParse(r.delaySeconds) ?? 0;
    final Color c = d.abs() <= 5
        ? Colors.greenAccent
        : d.abs() <= 60
            ? Colors.lightGreen
            : d.abs() <= 600
                ? Colors.orange
                : Colors.redAccent;
    final sign = d >= 0 ? '+' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(
          width: 132,
          child: Text(r.variant,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
        SizedBox(
          width: 96,
          child: Text('$sign${d.toStringAsFixed(1)}s',
              style: TextStyle(
                  color: c, fontWeight: FontWeight.bold, fontSize: 13)),
        ),
        Expanded(
          child: Text('idle=${r.idle} scr=${r.interactive}',
              style: const TextStyle(fontSize: 11, color: Colors.white54)),
        ),
      ]),
    );
  }

  Widget _flag(String label, bool ok, String hint) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.cancel,
              size: 18, color: ok ? Colors.greenAccent : Colors.redAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13)),
                Text(hint,
                    style: const TextStyle(fontSize: 10, color: Colors.white38)),
              ],
            ),
          ),
        ]),
      );

  Widget _btn(String label, VoidCallback onTap) =>
      OutlinedButton(onPressed: onTap, child: Text(label));

  Future<void> _call(String method) async {
    await _channel.invokeMethod(method);
    await _refresh();
  }
}

class _Row {
  _Row(this.event, this.variant, this.delaySeconds, this.idle, this.interactive);
  final String event;
  final String variant;
  final String delaySeconds;
  final String idle;
  final String interactive;
}

List<_Row> _parseLog(String csv) {
  final lines = csv.trim().split('\n');
  if (lines.length < 2) return const [];
  return lines.skip(1).where((l) => l.trim().isNotEmpty).map((l) {
    final p = l.split(',');
    String at(int i) => i < p.length ? p[i] : '';
    return _Row(at(2), at(3), at(6), at(7), at(10));
  }).toList();
}
