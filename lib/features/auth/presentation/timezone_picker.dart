import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../../core/theme/app_icons.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../core/format/zone_ids.dart';

/// A full-screen searchable list of IANA timezone names. Returns the chosen
/// identifier (e.g. "Asia/Karachi") via Navigator.pop, or null if dismissed.
class TimezonePicker extends StatefulWidget {
  const TimezonePicker({super.key});

  @override
  State<TimezonePicker> createState() => _TimezonePickerState();
}

class _TimezonePickerState extends State<TimezonePicker> {
  // One entry per zone, current names only (DECISIONS.md "One name per
  // timezone"): the database also holds ~140 old aliases such as
  // "Asia/Calcutta", which listed every renamed zone twice. Only names the
  // loaded tz data can resolve are offered.
  late final List<String> _allZones = [
    for (final zone in kPickerZones)
      if (tz.timeZoneDatabase.locations.containsKey(zone)) zone,
  ];
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final zones = _query.isEmpty
        ? _allZones
        : _allZones
            .where((z) => z.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose your home timezone'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(Space.md),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(AppIcons.search),
                hintText: 'Search e.g. Karachi, London, New_York',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: zones.length,
              itemBuilder: (context, i) => ListTile(
                title: Text(zones[i]),
                onTap: () => Navigator.of(context).pop(zones[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
