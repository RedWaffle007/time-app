// GENERATED from Flutter's MaterialLocalizations (flutter 3.44.6) for the F1
// fix, 2026-09-26. Regenerate if a Flutter upgrade adds members — the
// compiler reports any member it misses, so it cannot silently drift.
// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';

/// Every Material string/format from [_base] unchanged, EXCEPT the clock:
/// the time-of-day format follows the PHONE's 12/24-hour setting (item F1).
///
/// Why: Flutter only exposes "forced 24-hour". When that is off, the Material
/// time picker falls back to the LANGUAGE's default, which is 24-hour for e.g.
/// English (UK/India) — so a phone set to 12-hour still got a 24-hour picker.
class DeviceClockMaterialLocalizations implements MaterialLocalizations {
  DeviceClockMaterialLocalizations(this._base, {required this.use24Hour});

  final MaterialLocalizations _base;

  /// The phone's own clock setting.
  final bool use24Hour;

  @override
  TimeOfDayFormat timeOfDayFormat({bool alwaysUse24HourFormat = false}) {
    if (use24Hour) return TimeOfDayFormat.HH_colon_mm;
    final native = _base.timeOfDayFormat();
    return hourFormat(of: native) == HourFormat.h
        ? native
        : TimeOfDayFormat.h_colon_mm_space_a;
  }

  @override
  String formatHour(TimeOfDay timeOfDay, {bool alwaysUse24HourFormat = false}) {
    if (use24Hour) {
      return _base.formatHour(timeOfDay, alwaysUse24HourFormat: true);
    }
    final hour = timeOfDay.hourOfPeriod == 0 ? 12 : timeOfDay.hourOfPeriod;
    return _base.formatDecimal(hour);
  }

  @override
  String formatTimeOfDay(
    TimeOfDay timeOfDay, {
    bool alwaysUse24HourFormat = false,
  }) {
    if (use24Hour) {
      return _base.formatTimeOfDay(timeOfDay, alwaysUse24HourFormat: true);
    }
    final native = _base.timeOfDayFormat();
    if (hourFormat(of: native) == HourFormat.h) {
      return _base.formatTimeOfDay(timeOfDay);
    }
    final period = timeOfDay.period == DayPeriod.am
        ? _base.anteMeridiemAbbreviation
        : _base.postMeridiemAbbreviation;
    return '${formatHour(timeOfDay)}:${_base.formatMinute(timeOfDay)} $period';
  }

  @override
  String get openAppDrawerTooltip => _base.openAppDrawerTooltip;

  @override
  String get backButtonTooltip => _base.backButtonTooltip;

  @override
  String get clearButtonTooltip => _base.clearButtonTooltip;

  @override
  String get closeButtonTooltip => _base.closeButtonTooltip;

  @override
  String get deleteButtonTooltip => _base.deleteButtonTooltip;

  @override
  String get moreButtonTooltip => _base.moreButtonTooltip;

  @override
  String get nextMonthTooltip => _base.nextMonthTooltip;

  @override
  String get previousMonthTooltip => _base.previousMonthTooltip;

  @override
  String get firstPageTooltip => _base.firstPageTooltip;

  @override
  String get lastPageTooltip => _base.lastPageTooltip;

  @override
  String get nextPageTooltip => _base.nextPageTooltip;

  @override
  String get previousPageTooltip => _base.previousPageTooltip;

  @override
  String get showMenuTooltip => _base.showMenuTooltip;

  @override
  String aboutListTileTitle(String applicationName) =>
      _base.aboutListTileTitle(applicationName);

  @override
  String get licensesPageTitle => _base.licensesPageTitle;

  @override
  String licensesPackageDetailText(int licenseCount) =>
      _base.licensesPackageDetailText(licenseCount);

  @override
  String pageRowsInfoTitle(
    int firstRow,
    int lastRow,
    int rowCount,
    bool rowCountIsApproximate,
  ) => _base.pageRowsInfoTitle(
    firstRow,
    lastRow,
    rowCount,
    rowCountIsApproximate,
  );

  @override
  String get rowsPerPageTitle => _base.rowsPerPageTitle;

  @override
  String tabLabel({required int tabIndex, required int tabCount}) =>
      _base.tabLabel(tabIndex: tabIndex, tabCount: tabCount);

  @override
  String selectedRowCountTitle(int selectedRowCount) =>
      _base.selectedRowCountTitle(selectedRowCount);

  @override
  String get cancelButtonLabel => _base.cancelButtonLabel;

  @override
  String get closeButtonLabel => _base.closeButtonLabel;

  @override
  String get continueButtonLabel => _base.continueButtonLabel;

  @override
  String get copyButtonLabel => _base.copyButtonLabel;

  @override
  String get cutButtonLabel => _base.cutButtonLabel;

  @override
  String get scanTextButtonLabel => _base.scanTextButtonLabel;

  @override
  String get okButtonLabel => _base.okButtonLabel;

  @override
  String get pasteButtonLabel => _base.pasteButtonLabel;

  @override
  String get selectAllButtonLabel => _base.selectAllButtonLabel;

  @override
  String get lookUpButtonLabel => _base.lookUpButtonLabel;

  @override
  String get searchWebButtonLabel => _base.searchWebButtonLabel;

  @override
  String get shareButtonLabel => _base.shareButtonLabel;

  @override
  String get viewLicensesButtonLabel => _base.viewLicensesButtonLabel;

  @override
  String get anteMeridiemAbbreviation => _base.anteMeridiemAbbreviation;

  @override
  String get postMeridiemAbbreviation => _base.postMeridiemAbbreviation;

  @override
  String get timePickerHourModeAnnouncement =>
      _base.timePickerHourModeAnnouncement;

  @override
  String get timePickerMinuteModeAnnouncement =>
      _base.timePickerMinuteModeAnnouncement;

  @override
  String get modalBarrierDismissLabel => _base.modalBarrierDismissLabel;

  @override
  String get menuDismissLabel => _base.menuDismissLabel;

  @override
  String get drawerLabel => _base.drawerLabel;

  @override
  String get popupMenuLabel => _base.popupMenuLabel;

  @override
  String get menuBarMenuLabel => _base.menuBarMenuLabel;

  @override
  String get dialogLabel => _base.dialogLabel;

  @override
  String get alertDialogLabel => _base.alertDialogLabel;

  @override
  String get searchFieldLabel => _base.searchFieldLabel;

  @override
  String get currentDateLabel => _base.currentDateLabel;

  @override
  String get selectedDateLabel => _base.selectedDateLabel;

  @override
  String get scrimLabel => _base.scrimLabel;

  @override
  String get bottomSheetLabel => _base.bottomSheetLabel;

  @override
  String scrimOnTapHint(String modalRouteContentName) =>
      _base.scrimOnTapHint(modalRouteContentName);

  @override
  ScriptCategory get scriptCategory => _base.scriptCategory;

  @override
  String formatDecimal(int number) => _base.formatDecimal(number);

  @override
  String formatMinute(TimeOfDay timeOfDay) => _base.formatMinute(timeOfDay);

  @override
  String formatYear(DateTime date) => _base.formatYear(date);

  @override
  String formatCompactDate(DateTime date) => _base.formatCompactDate(date);

  @override
  String formatShortDate(DateTime date) => _base.formatShortDate(date);

  @override
  String formatMediumDate(DateTime date) => _base.formatMediumDate(date);

  @override
  String formatFullDate(DateTime date) => _base.formatFullDate(date);

  @override
  String formatMonthYear(DateTime date) => _base.formatMonthYear(date);

  @override
  String formatShortMonthDay(DateTime date) => _base.formatShortMonthDay(date);

  @override
  DateTime? parseCompactDate(String? inputString) =>
      _base.parseCompactDate(inputString);

  @override
  List<String> get narrowWeekdays => _base.narrowWeekdays;

  @override
  int get firstDayOfWeekIndex => _base.firstDayOfWeekIndex;

  @override
  String get dateSeparator => _base.dateSeparator;

  @override
  String get dateHelpText => _base.dateHelpText;

  @override
  String get selectYearSemanticsLabel => _base.selectYearSemanticsLabel;

  @override
  String get unspecifiedDate => _base.unspecifiedDate;

  @override
  String get unspecifiedDateRange => _base.unspecifiedDateRange;

  @override
  String get dateInputLabel => _base.dateInputLabel;

  @override
  String get dateRangeStartLabel => _base.dateRangeStartLabel;

  @override
  String get dateRangeEndLabel => _base.dateRangeEndLabel;

  @override
  String dateRangeStartDateSemanticLabel(String formattedDate) =>
      _base.dateRangeStartDateSemanticLabel(formattedDate);

  @override
  String dateRangeEndDateSemanticLabel(String formattedDate) =>
      _base.dateRangeEndDateSemanticLabel(formattedDate);

  @override
  String get invalidDateFormatLabel => _base.invalidDateFormatLabel;

  @override
  String get invalidDateRangeLabel => _base.invalidDateRangeLabel;

  @override
  String get dateOutOfRangeLabel => _base.dateOutOfRangeLabel;

  @override
  String get saveButtonLabel => _base.saveButtonLabel;

  @override
  String get datePickerHelpText => _base.datePickerHelpText;

  @override
  String get dateRangePickerHelpText => _base.dateRangePickerHelpText;

  @override
  String get calendarModeButtonLabel => _base.calendarModeButtonLabel;

  @override
  String get inputDateModeButtonLabel => _base.inputDateModeButtonLabel;

  @override
  String get timePickerDialHelpText => _base.timePickerDialHelpText;

  @override
  String get timePickerInputHelpText => _base.timePickerInputHelpText;

  @override
  String get timePickerHourLabel => _base.timePickerHourLabel;

  @override
  String get timePickerMinuteLabel => _base.timePickerMinuteLabel;

  @override
  String get invalidTimeLabel => _base.invalidTimeLabel;

  @override
  String get dialModeButtonLabel => _base.dialModeButtonLabel;

  @override
  String get inputTimeModeButtonLabel => _base.inputTimeModeButtonLabel;

  @override
  String get signedInLabel => _base.signedInLabel;

  @override
  String get hideAccountsLabel => _base.hideAccountsLabel;

  @override
  String get showAccountsLabel => _base.showAccountsLabel;

  @override
  String get reorderItemToStart => _base.reorderItemToStart;

  @override
  String get reorderItemToEnd => _base.reorderItemToEnd;

  @override
  String get reorderItemUp => _base.reorderItemUp;

  @override
  String get reorderItemDown => _base.reorderItemDown;

  @override
  String get reorderItemLeft => _base.reorderItemLeft;

  @override
  String get reorderItemRight => _base.reorderItemRight;

  @override
  String remainingTextFieldCharacterCount(int remaining) =>
      _base.remainingTextFieldCharacterCount(remaining);

  @override
  String get refreshIndicatorSemanticLabel =>
      _base.refreshIndicatorSemanticLabel;

  @override
  String get keyboardKeyAlt => _base.keyboardKeyAlt;

  @override
  String get keyboardKeyAltGraph => _base.keyboardKeyAltGraph;

  @override
  String get keyboardKeyBackspace => _base.keyboardKeyBackspace;

  @override
  String get keyboardKeyCapsLock => _base.keyboardKeyCapsLock;

  @override
  String get keyboardKeyChannelDown => _base.keyboardKeyChannelDown;

  @override
  String get keyboardKeyChannelUp => _base.keyboardKeyChannelUp;

  @override
  String get keyboardKeyControl => _base.keyboardKeyControl;

  @override
  String get keyboardKeyDelete => _base.keyboardKeyDelete;

  @override
  String get keyboardKeyEject => _base.keyboardKeyEject;

  @override
  String get keyboardKeyEnd => _base.keyboardKeyEnd;

  @override
  String get keyboardKeyEscape => _base.keyboardKeyEscape;

  @override
  String get keyboardKeyFn => _base.keyboardKeyFn;

  @override
  String get keyboardKeyHome => _base.keyboardKeyHome;

  @override
  String get keyboardKeyInsert => _base.keyboardKeyInsert;

  @override
  String get keyboardKeyMeta => _base.keyboardKeyMeta;

  @override
  String get keyboardKeyMetaMacOs => _base.keyboardKeyMetaMacOs;

  @override
  String get keyboardKeyMetaWindows => _base.keyboardKeyMetaWindows;

  @override
  String get keyboardKeyNumLock => _base.keyboardKeyNumLock;

  @override
  String get keyboardKeyNumpad1 => _base.keyboardKeyNumpad1;

  @override
  String get keyboardKeyNumpad2 => _base.keyboardKeyNumpad2;

  @override
  String get keyboardKeyNumpad3 => _base.keyboardKeyNumpad3;

  @override
  String get keyboardKeyNumpad4 => _base.keyboardKeyNumpad4;

  @override
  String get keyboardKeyNumpad5 => _base.keyboardKeyNumpad5;

  @override
  String get keyboardKeyNumpad6 => _base.keyboardKeyNumpad6;

  @override
  String get keyboardKeyNumpad7 => _base.keyboardKeyNumpad7;

  @override
  String get keyboardKeyNumpad8 => _base.keyboardKeyNumpad8;

  @override
  String get keyboardKeyNumpad9 => _base.keyboardKeyNumpad9;

  @override
  String get keyboardKeyNumpad0 => _base.keyboardKeyNumpad0;

  @override
  String get keyboardKeyNumpadAdd => _base.keyboardKeyNumpadAdd;

  @override
  String get keyboardKeyNumpadComma => _base.keyboardKeyNumpadComma;

  @override
  String get keyboardKeyNumpadDecimal => _base.keyboardKeyNumpadDecimal;

  @override
  String get keyboardKeyNumpadDivide => _base.keyboardKeyNumpadDivide;

  @override
  String get keyboardKeyNumpadEnter => _base.keyboardKeyNumpadEnter;

  @override
  String get keyboardKeyNumpadEqual => _base.keyboardKeyNumpadEqual;

  @override
  String get keyboardKeyNumpadMultiply => _base.keyboardKeyNumpadMultiply;

  @override
  String get keyboardKeyNumpadParenLeft => _base.keyboardKeyNumpadParenLeft;

  @override
  String get keyboardKeyNumpadParenRight => _base.keyboardKeyNumpadParenRight;

  @override
  String get keyboardKeyNumpadSubtract => _base.keyboardKeyNumpadSubtract;

  @override
  String get keyboardKeyPageDown => _base.keyboardKeyPageDown;

  @override
  String get keyboardKeyPageUp => _base.keyboardKeyPageUp;

  @override
  String get keyboardKeyPower => _base.keyboardKeyPower;

  @override
  String get keyboardKeyPowerOff => _base.keyboardKeyPowerOff;

  @override
  String get keyboardKeyPrintScreen => _base.keyboardKeyPrintScreen;

  @override
  String get keyboardKeyScrollLock => _base.keyboardKeyScrollLock;

  @override
  String get keyboardKeySelect => _base.keyboardKeySelect;

  @override
  String get keyboardKeyShift => _base.keyboardKeyShift;

  @override
  String get keyboardKeySpace => _base.keyboardKeySpace;
  @override
  String get expandedIconTapHint => _base.expandedIconTapHint;

  @override
  String get collapsedIconTapHint => _base.collapsedIconTapHint;

  @override
  String get expansionTileExpandedHint => _base.expansionTileExpandedHint;

  @override
  String get expansionTileCollapsedHint => _base.expansionTileCollapsedHint;

  @override
  String get expansionTileExpandedTapHint => _base.expansionTileExpandedTapHint;

  @override
  String get expansionTileCollapsedTapHint =>
      _base.expansionTileCollapsedTapHint;

  @override
  String get expandedHint => _base.expandedHint;

  @override
  String get collapsedHint => _base.collapsedHint;
}
