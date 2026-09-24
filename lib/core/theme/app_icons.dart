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

  // ---- the five product pillars (UI-RULES.md §6.12) ----
  //
  // The bottom bar names the app's pillars, not the three delegation stances
  // (those are now sub-navigation inside Plan). Each carries the outline/filled
  // pair the §6.6 filled-selected rule needs. `navPlan` is the delegation hub —
  // deliberately the calendar-check glyph, distinct from `navSchedule`
  // (`event`), which now names only the My Schedule *sub-tab* inside Plan.
  static const IconData navPlan = Icons.event_note_outlined;
  static const IconData navPlanSelected = Icons.event_note;
  static const IconData navTrack = track; // timer_outlined
  static const IconData navTrackSelected = trackSelected; // timer
  static const IconData navStats = Icons.bar_chart_outlined;
  static const IconData navStatsSelected = Icons.bar_chart;

  /// A run of consecutive days — the group's shared streak (and any streak
  /// header). The fire glyph is the near-universal "streak" convention.
  static const IconData streak = Icons.local_fire_department_outlined;
  static const IconData navYou = Icons.person_outline;
  static const IconData navYouSelected = Icons.person;

  /// The docked centre **voice FAB** (§6.12) — one mic glyph for the whole
  /// speak-to-create affordance spanning Track and Plan. Not a nav destination,
  /// so it has no filled/outline pair.
  static const IconData voice = Icons.mic_none_outlined;

  /// The ACTIVE mic while a voice capture is listening (S6) — filled, because it
  /// is a live state, not the at-rest affordance the [voice] FAB is.
  static const IconData voiceListening = Icons.mic;

  /// "I'm done talking" — stop the current voice capture and take the result.
  static const IconData voiceStop = Icons.stop_circle_outlined;

  /// "Type instead" — the always-present fallback from any voice flow to the
  /// identical manual entry (S6). The mic is never the only way in.
  static const IconData typeInstead = Icons.keyboard_outlined;

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
  static const IconData close = Icons.close;
  static const IconData bullet = Icons.circle;
  static const IconData search = Icons.search;
  static const IconData signIn = Icons.login;
  static const IconData signOut = Icons.logout;

  /// Join an existing group by code. Distinct from [signIn], which used the
  /// same `Icons.login` glyph until this file existed.
  static const IconData joinGroup = Icons.group_add_outlined;

  /// Take someone else out of a group you own.
  ///
  /// A bin glyph is *correct* here in a way it never is on [archive]: this
  /// really does change what the other person sees, and the copy rule cuts both
  /// ways — softening a destructive act is the same dishonesty as harshening a
  /// reversible one. The person can rejoin with the code; nothing else survives.
  static const IconData removeMember = Icons.person_remove_outlined;

  /// Take YOURSELF out of a group.
  ///
  /// Distinct from [removeMember] per rule 1 — leaving and ejecting someone are
  /// different acts with different blast radii — and distinct from [signOut],
  /// which ends a *session* rather than a relationship. Those two shared
  /// `Icons.logout` in every draft of this screen until the vocabulary forced
  /// the question.
  static const IconData leaveGroup = Icons.group_remove_outlined;

  /// Give up a planner grant you hold over someone — "stop planning for them".
  ///
  /// Deliberately not [withdrawn], which retracts a single *item*. Ending a
  /// standing permission and taking back one plan are different facts, and
  /// letting them share a glyph is exactly the trap rule 1 exists to close.
  static const IconData stopPlanning = Icons.event_busy_outlined;

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

  /// The chevron on a collapsible day-section header — points DOWN when the
  /// section is collapsed, rotated UP (180°) when expanded. A distinct concept
  /// from [openRow] (drill sideways into a row): this is vertical expand/collapse
  /// in place. See CollapsibleDayGroups.
  static const IconData expandGroup = Icons.keyboard_arrow_down;

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

  // ---- reminders (the local reminder layer) ----

  /// A reminder — the notification this phone fires when one of your items is
  /// due. Deliberately not [pending], which is a *schedule item's* status, and
  /// not [time], which is the picker glyph: "a reminder" and "a clock" are
  /// different concepts (rule 1).
  static const IconData reminders = Icons.notifications_active_outlined;

  /// Timing precision — the exact-alarm permission and anything naming it.
  ///
  /// Distinct from [reminders]: whether you get reminded at all and whether you
  /// get reminded *on time* are two separate permissions with two separate
  /// system screens, and a user who has one and not the other must be able to
  /// tell which is which. The spike measured that gap at 0.6s versus 110s.
  static const IconData exactTiming = Icons.alarm_on_outlined;

  /// The EMERGENCY item tier (#5) and its separate grant — a plan a friend can
  /// set that fires WITHOUT the target's per-item approval. Line work; the §2.7
  /// orange-fill firewall governs status colour, not this glyph.
  static const IconData emergency = Icons.notification_important_outlined;

  /// Discard a diagnostic log. A bin is honest here, unlike on [archive]: this
  /// really does destroy the data and nothing references it.
  static const IconData clearLog = Icons.delete_sweep_outlined;

  // ---- permissions onboarding (first-run) ----

  /// The permissions setup flow, as a destination and its own header. Not
  /// [appLock] or any status glyph: this names "the OS permissions this app
  /// needs", a distinct concept from any single permission below.
  static const IconData permissions = Icons.verified_user_outlined;

  /// A permission that is currently GRANTED, in the onboarding checklist.
  ///
  /// Deliberately none of [approved] / [done] / [selected]: those are facts
  /// about a schedule item or a chosen row in the delegation loop, and rule 1
  /// keeps "the OS granted us this permission" as its own concept. Outlined, per
  /// rule 2 — it is a resting confirmation, not a selection.
  static const IconData granted = Icons.check_circle_outline;

  /// The battery / Doze exemption, wherever it is named.
  static const IconData battery = Icons.battery_saver;

  /// OEM autostart — letting the app launch itself so a reminder can fire after
  /// the process was killed. A launch glyph, distinct from [reminders].
  static const IconData autostart = Icons.rocket_launch_outlined;

  /// The full-screen-intent permission — a reminder ringing over whatever is on
  /// screen. Distinct from [reminders] (whether you are notified at all) and
  /// [exactTiming] (whether on time): this is whether it takes over the screen.
  static const IconData ringOverApps = Icons.fullscreen;

  // ---- language practice (the chatbot feature) ----

  /// The language-practice feature's own entry (the You hub, the account menu).
  /// Names the activity, not "chatbot".
  static const IconData languagePractice = Icons.translate;

  /// Send the composed message. Not [add]: composing and creating are different
  /// acts, and only one of them is a schedule item.
  static const IconData send = Icons.send;

  /// The retrieval index had no confident match, so the bot answered with its
  /// fallback. A quiet marker on a real reply — deliberately NOT [error] or
  /// [warning], because nothing failed and the orange fill those imply is
  /// reserved for state the user must act on (§2.7).
  static const IconData noMatch = Icons.help_outline;

  /// The model that runs the bot **on this phone** — the setup destination and
  /// anything naming it. A chip glyph, because the fact worth conveying is
  /// "this lives on the device", not "this was downloaded".
  static const IconData offlineModel = Icons.memory;

  /// Fetching that model over the network. Distinct from [offlineModel]: the
  /// thing and the act of getting it are two concepts (rule 1), and only one of
  /// them needs a connection.
  static const IconData modelDownload = Icons.cloud_download_outlined;

  /// The model is installed and verified — usable with no network.
  ///
  /// Deliberately not [done] or [approved]: those are facts about a *schedule
  /// item* in the delegation loop, and this file is the one place that
  /// distinction is kept honest. Not [selected] either, which is filled and
  /// means "this row is the current choice" (rule 2).
  static const IconData modelReady = Icons.offline_pin_outlined;

  /// Where a service lives — the editable address of the practice backend, and
  /// the control that opens it. Scoped to the HTTP implementation and deleted
  /// with it; an on-device engine has no address.
  static const IconData serviceAddress = Icons.dns_outlined;

  // ---- social profiles, friends and privacy ----

  /// The friends list, as a destination.
  ///
  /// Deliberately NOT [group] / [navGroups], which draw the same Material
  /// "people" glyph. A group is the delegation container the whole core loop
  /// runs inside; a friend is a person-to-person tie that grants nothing on its
  /// own. Letting them share a glyph would say the two are the same thing,
  /// which is the exact confusion the social layer had to be designed around.
  static const IconData friends = Icons.people_alt_outlined;

  /// Ask someone to be friends.
  ///
  /// Distinct from [joinGroup], which is `group_add` — joining a group and
  /// befriending a person are different acts with different consequences, and
  /// rule 1 gives them different glyphs.
  static const IconData addFriend = Icons.person_add_alt_1_outlined;

  /// Accept an incoming request — an explicit tick.
  ///
  /// A plain check, deliberately: the accept/decline pair on a pending request
  /// must read as the universal ✓/✗ decision controls (the earlier
  /// `how_to_reg` person-glyph did not), and this is the one control whose whole
  /// job is "yes". Still not [approved] — that is the schedule-item fact in the
  /// delegation loop, a different agreement — this file keeps them distinct.
  static const IconData acceptFriend = Icons.check_rounded;

  /// Decline an incoming request, or withdraw one you sent — an explicit cross.
  /// The ✗ half of the accept/decline pair; also used for withdrawing a pending
  /// outgoing request (clearing a pending thing, either direction). Not
  /// [rejected], for the same reason [acceptFriend] is not [approved].
  static const IconData declineFriend = Icons.close_rounded;

  /// End a friendship you already have.
  ///
  /// Distinct from [declineFriend] (refusing one that never started) and from
  /// [removeMember] (ejecting someone from a group you own). Three different
  /// severances with three different blast radii.
  static const IconData removeFriend = Icons.person_remove_alt_1_outlined;

  /// Block a user. The bin-glyph reasoning from [removeMember] applies in
  /// reverse: this is genuinely severe and the glyph must not soften it.
  static const IconData block = Icons.block;

  /// Lift a block. A distinct concept from [block] — reversibility is the
  /// point, so it does not share the glyph.
  static const IconData unblock = Icons.lock_reset;

  /// Report a profile picture for moderation.
  ///
  /// Not [warning], whose orange fill is reserved for state the user must act
  /// on (§2.7). Reporting is something the user chooses to do, not something
  /// waiting on them.
  static const IconData report = Icons.flag_outlined;

  /// The privacy toggle when the profile is PUBLIC — visible to anyone signed
  /// in. Filled, per rule 2: public is the active, opted-into state.
  static const IconData privacyPublic = Icons.visibility;

  /// The privacy toggle when the profile is PRIVATE — friends only. This is the
  /// default, i.e. the state at rest, so it is the outlined one.
  static const IconData privacyPrivate = Icons.visibility_off_outlined;

  /// A username / handle, wherever one is shown or edited.
  static const IconData username = Icons.alternate_email;

  /// The free-text "about you" field.
  static const IconData bio = Icons.notes_outlined;

  /// Choose or replace a profile picture.
  static const IconData editPhoto = Icons.add_a_photo_outlined;

  /// Remove the uploaded picture, falling back to the account photo. Not
  /// [clearLog], which destroys data — this only unsets a field, and the object
  /// is deleted as a consequence rather than as the point.
  static const IconData removePhoto = Icons.hide_image_outlined;

  /// A profile as a destination — "view this person".
  ///
  /// Distinct from [account], which is filled and means "your own account menu"
  /// in every AppBar. Looking at someone else's profile is not that.
  static const IconData viewProfile = Icons.badge_outlined;

  /// The stats section header, and a stat tile with no value yet.
  ///
  /// Not [navActivity] (`insights`), which names the planner's own tab. A
  /// profile statistic and the Activity feed are different things.
  static const IconData stats = Icons.leaderboard_outlined;

  /// Nobody in the friends list yet.
  ///
  /// Distinct from [friends] for the reason [emptyArchive] is distinct from
  /// [archive]: "your friends" and "you have no friends yet" are opposite
  /// messages and must not share a glyph.
  static const IconData emptyFriends = Icons.person_search_outlined;

  /// No friend requests waiting. Distinct again from [emptyFriends] — an empty
  /// inbox and an empty roster are different emptinesses.
  static const IconData emptyRequests = Icons.mark_email_read_outlined;

  /// A profile that cannot be reached — blocked in either direction, or a
  /// username that resolves to nobody. One glyph for all three on purpose: the
  /// user must not be able to tell a block from a missing account, which is
  /// exactly what `ProfileRelation.blockedBy` documents.
  static const IconData profileUnavailable = Icons.no_accounts_outlined;

  // ---- the calendar (UI-RULES.md §6.10) ----

  /// The calendar screen as a *destination* — the My Schedule entry and the
  /// screen's own identity.
  ///
  /// Deliberately not [date] (`calendar_today`), which is the *pick a date*
  /// control on the schedule builder, and not [navSchedule] (`event`), which
  /// names the My Schedule tab. "Go and look at the calendar", "choose a day"
  /// and "your approved items" are three concepts, and rule 1 gives them three
  /// glyphs.
  static const IconData calendar = Icons.calendar_month_outlined;

  /// The three view modes, on the segmented toggle. Outlined per rule 2 — the
  /// segmented button carries selection itself, so fill weight is not being
  /// asked to encode it a second time.
  static const IconData viewMonth = Icons.calendar_view_month_outlined;
  static const IconData viewWeek = Icons.calendar_view_week_outlined;
  static const IconData viewDay = Icons.calendar_view_day_outlined;

  /// Jump back to today. Distinct from [calendar] and from [date]: this is a
  /// movement, not a place and not a choice.
  static const IconData today = Icons.today_outlined;

  /// Page to the previous / next month, week or day.
  ///
  /// `keyboard_arrow_*` rather than `chevron_*` on purpose. [openRow] is already
  /// `chevron_right`, and rule 1 is literal — a glyph means exactly one thing in
  /// this app. "Drill into this row" and "move to next month" are different
  /// concepts, so they get different glyphs even though both are arrowheads.
  static const IconData previousPeriod = Icons.keyboard_arrow_left;
  static const IconData nextPeriod = Icons.keyboard_arrow_right;

  /// A day with nothing on it.
  ///
  /// A third emptiness, alongside [emptyGeneric] and [emptyArchive], for the
  /// same reason those two are separate: "your inbox is empty", "you have
  /// archived nothing" and "this day is free" are different messages. A free day
  /// is a good thing, which is exactly what the other two glyphs fail to say.
  static const IconData emptyDay = Icons.event_available_outlined;

  // ---- time-tracking (the Track pillar) ----

  /// The Track pillar and its account-popup entry, outlined / filled per the
  /// §6.6 nav convention (the filled form is for the future bottom-bar slot).
  static const IconData track = Icons.timer_outlined;
  static const IconData trackSelected = Icons.timer;

  /// The Track pillar's bottom-right "log time" create action.
  static const IconData logTime = Icons.more_time_outlined;

  /// A logged entry's duration, and its optional time-of-day range.
  static const IconData duration = Icons.hourglass_bottom_outlined;

  /// Editing and deleting an owned entry.
  static const IconData edit = Icons.edit_outlined;
  static const IconData delete = Icons.delete_outline;

  /// "You have logged no time yet" — a fourth emptiness, distinct from the
  /// inbox / archive / free-day ones (§emptyGeneric).
  static const IconData emptyTrack = Icons.timelapse_outlined;

  // ---- the You hub (account pillar) ----

  /// The You pillar / account destination, and its list rows: editing your
  /// profile, and the account block. Reuses [account] for the pillar itself.
  static const IconData editProfile = Icons.person_outline;
  static const IconData devMenu = Icons.build_outlined;

  /// The first-run orientation tour, as a replayable entry in the You hub
  /// ("How this app works"). A compass/explore glyph — "show me around" — and
  /// distinct from [permissions] (the OS-permission flow), [noMatch]
  /// (`help_outline`, the chatbot fallback marker) and [languagePractice]:
  /// re-touring the UI is its own concept (rule 1).
  static const IconData walkthrough = Icons.explore_outlined;

  /// Appearance follows the device, or is explicitly light/dark. These are
  /// distinct concepts because the three-way picker states a source as well as
  /// a result.
  static const IconData themeSystem = Icons.brightness_auto_outlined;
  static const IconData themeLight = Icons.light_mode_outlined;
  static const IconData themeDark = Icons.dark_mode_outlined;

  /// Step backward / forward through the orientation tour's coach marks.
  ///
  /// Distinct from [previousPeriod]/[nextPeriod] (calendar paging) and [openRow]
  /// (drill into a row) per rule 1 — moving between tour explanations is its own
  /// concept. A plain directional arrow, not a chevron.
  static const IconData stepBack = Icons.arrow_back;
  static const IconData stepForward = Icons.arrow_forward;

  // ---- dev-only scaffolding (lib/dev is governed too — §6.6) ----

  static const IconData devPanels = warning;
  static const IconData devCards = Icons.view_agenda_outlined;
}
