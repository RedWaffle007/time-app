import 'package:flutter/material.dart';

/// **The one icon vocabulary** (UI-RULES.md §6.6).
///
/// Same shape, and the same reason, as `status_style.dart`: before this file
/// existed there were 47 `Icons.*` literals across 17 screens and no rule about
/// which glyph meant what. Three of them were actively contradictory —
/// `Icons.check` was the Approved badge AND the Done badge AND "this row is
/// selected"; `Icons.inbox_outlined` meant both "there is nothing here" and "go
/// to your queue"; `Icons.login` meant both sign-in and join-a-group.
///
/// **Names are semantic, never glyph-named.** [pending], never `schedule`. Same
/// reasoning as `attention` versus `tertiary`: the call site reads the meaning,
/// so the glyph can be re-picked without touching a screen.
///
/// Two rules govern what goes in here:
///
///   1. **One concept, one glyph.** If you need an icon for something new, add
///      the concept — do not reuse a neighbour because it looks close enough.
///   2. **Filled = selected or active. Outlined = available or at rest.** Only
///      the nav bar has a selected state, so nav destinations carry both
///      variants and everything else is outlined. Fill weight is not available
///      to encode anything else.
///
/// Icons never carry an inline colour at a call site — see the table in §6.6.
abstract final class AppIcons {
  // ---- status and outcome (consumed by status_style.dart) ----

  /// Waiting on the target to decide.
  ///
  /// NOT `Icons.schedule`: that is the same drawing as `Icons.access_time`, so
  /// the Pending badge and the time picker were rendering an identical glyph
  /// under two names — rule 1 in reverse.
  static const IconData pending = Icons.pending_outlined;

  /// The target agreed to the plan.
  static const IconData approved = Icons.check;

  /// The target did the thing. Distinct from [approved]: agreeing and doing are
  /// two different facts, and the whole accountability loop turns on the gap.
  static const IconData done = Icons.task_alt;

  static const IconData rejected = Icons.close;
  static const IconData skipped = Icons.skip_next;
  static const IconData cancelled = Icons.remove_circle_outline;
  static const IconData withdrawn = Icons.undo;

  // ---- navigation destinations (the only place rule 2 has both variants) ----

  static const IconData navGroups = Icons.group_outlined;
  static const IconData navGroupsSelected = Icons.group;
  static const IconData navSchedule = Icons.event_outlined;
  static const IconData navScheduleSelected = Icons.event;
  static const IconData navActivity = Icons.insights_outlined;
  static const IconData navActivitySelected = Icons.insights;

  // ---- objects ----

  /// A person — the target of a plan, or yourself.
  ///
  /// One glyph for both. The schedule builder used to draw `person_outline` for
  /// "Myself" and `person` for everyone else, making fill weight mean
  /// *self vs other* — a convention that exists nowhere else and that no user
  /// could decode. The label already says which; the glyph does not repeat it.
  static const IconData person = Icons.person_outline;

  /// A group, everywhere it is not a nav destination.
  static const IconData group = Icons.group_outlined;

  static const IconData inviteCode = Icons.key;
  static const IconData timezone = Icons.public;
  static const IconData date = Icons.calendar_today;
  static const IconData time = Icons.access_time;
  static const IconData quietHoursStart = Icons.bedtime_outlined;
  static const IconData quietHoursEnd = Icons.wb_sunny_outlined;
  static const IconData account = Icons.account_circle;

  /// The app lock, wherever it is named — the setting and the lock screen.
  ///
  /// Outlined, per rule 2: the lock screen is a state of the app, but this glyph
  /// is not encoding *selected vs not*, it is naming a thing. Nothing here has a
  /// second variant to contrast with.
  static const IconData appLock = Icons.lock_outline;

  /// The action that opens it. Distinct from [appLock]: "the lock" and "open the
  /// lock" are different concepts, and rule 1 gives them different glyphs.
  static const IconData unlock = Icons.lock_open_outlined;

  // ---- actions ----

  static const IconData add = Icons.add;
  static const IconData copy = Icons.copy;
  static const IconData share = Icons.share;
  static const IconData retry = Icons.refresh;
  static const IconData search = Icons.search;
  static const IconData signIn = Icons.login;
  static const IconData signOut = Icons.logout;

  /// Join an existing group by code. Distinct from [signIn], which used the
  /// same `Icons.login` glyph until this file existed.
  static const IconData joinGroup = Icons.group_add_outlined;

  /// Hide a settled item from your own views (Group D). Never "delete" — the
  /// record is untouched and the other party is unaffected, and the glyph has
  /// to say so as plainly as the label does. A bin icon here would be a lie in
  /// exactly the way the copy rule forbids.
  static const IconData archive = Icons.archive_outlined;

  /// Put an archived item back. Distinct concept, distinct glyph — reversibility
  /// is the point of the feature, so it does not share [archive]'s.
  static const IconData unarchive = Icons.unarchive_outlined;

  /// Secondary actions on a card, folded into a menu.
  ///
  /// Cards live in scrollable lists, where an always-visible inline action
  /// invites a mis-tap mid-scroll. Anything that is not the card's primary
  /// action belongs behind this.
  static const IconData overflow = Icons.more_vert;

  /// Drill into a row.
  static const IconData openRow = Icons.chevron_right;

  /// This row is the current choice. Filled, per rule 2 — and deliberately not
  /// [approved], which means "the target agreed", a different fact entirely.
  static const IconData selected = Icons.check_circle;

  // ---- destinations and feedback states ----

  /// The approvals queue as a *place you are being sent to*.
  ///
  /// Deliberately not [emptyGeneric]'s inbox: "there is nothing here" and "go to
  /// your queue" are opposite messages and shared one glyph before this file.
  static const IconData approvals = Icons.assignment_turned_in_outlined;

  /// Default empty state — nothing in this container yet (UI-RULES.md §6.5).
  static const IconData emptyGeneric = Icons.inbox_outlined;

  /// The Archived view with nothing in it.
  ///
  /// Deliberately not [archive]: "hide this item" and "you have hidden nothing"
  /// are opposite messages, and letting them share a glyph is the same mistake
  /// `inbox_outlined` made for [emptyGeneric] versus [approvals].
  static const IconData emptyArchive = Icons.inventory_2_outlined;

  static const IconData error = Icons.error_outline;
  static const IconData timeout = Icons.hourglass_empty;
  static const IconData notificationsOff = Icons.notifications_off_outlined;

  /// The warning panel's icon (UI-RULES.md §6.3).
  ///
  /// The underlying glyph is Material's `warning_amber_rounded`. That name is a
  /// Material naming artifact and has **nothing** to do with the amber banned in
  /// §2.4 — the icon renders in `onAttentionContainer` on the attention fill.
  /// Naming the concept `warning` is exactly so no call site types "amber".
  static const IconData warning = Icons.warning_amber_rounded;

  // ---- dev-only scaffolding (lib/dev is governed too — §6.6) ----

  static const IconData devPanels = warning;
  static const IconData devCards = Icons.view_agenda_outlined;
}
