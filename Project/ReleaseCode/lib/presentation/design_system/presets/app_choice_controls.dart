import 'package:flutter/material.dart';

import '../base/base_choice_controls.dart';
import '../../../configuration/presentation/controls/check_option_values.dart';
import '../../../configuration/presentation/controls/segmented_selector_values.dart';
import '../../../configuration/presentation/controls/select_field_values.dart';
import '../../../configuration/presentation/theme/theme_values.dart';
import '../../app_localizations.dart';

class AppSelectOption<T> extends BaseSelectOption<T> {
  const AppSelectOption(super.value, super.label, {super.enabled});
}

class AppSelectField<T> extends StatelessWidget {
  final T? value;
  final String label;
  final String? helper;
  final List<AppSelectOption<T>> options;
  final ValueChanged<T?>? onChanged;
  const AppSelectField({
    super.key,
    required this.value,
    required this.label,
    this.helper,
    required this.options,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BaseSelectField<T>(
      value: value,
      label: label,
      helper: helper,
      options: options,
      onChanged: onChanged,
      minimumHeight: SelectFieldValues.minimumHeight,
      minimumAccessibleTargetSize:
          SelectFieldValues.minimumAccessibleTargetSize,
      horizontalPadding: SelectFieldValues.horizontalPadding,
      verticalPadding: SelectFieldValues.verticalPadding,
      radius: SelectFieldValues.radius,
      borderWidth: SelectFieldValues.borderWidth,
      borderColor: scheme.outline,
      focusedBorderColor: scheme.primary,
      textStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: SelectFieldValues.textFontSize,
        fontWeight: FontWeight.values[SelectFieldValues.textFontWeightIndex],
      ),
      labelStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: SelectFieldValues.labelFontSize,
        fontWeight: FontWeight.values[SelectFieldValues.labelFontWeightIndex],
      ),
      helperStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: SelectFieldValues.helperFontSize,
        fontWeight: FontWeight.values[SelectFieldValues.helperFontWeightIndex],
      ),
    );
  }
}

class AppCheckOption extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool? value;
  final bool toggle;
  final bool tristate;
  final bool bulkControl;
  final ValueChanged<bool?>? onChanged;
  const AppCheckOption({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.toggle = false,
    this.tristate = false,
    this.bulkControl = false,
  });
  @override
  Widget build(BuildContext context) {
    final effectiveTitle = !bulkControl
        ? title
        : value == true
        ? context.tr('全部取消', 'Clear all')
        : value == null
        ? context.tr('全选（已选择部分）', 'Select all (partially selected)')
        : context.tr('全选', 'Select all');
    final effectiveSubtitle = !bulkControl
        ? subtitle
        : value == true
        ? context.tr(
            '当前已全部选择，点击后全部取消',
            'All items are selected. Activate to clear all.',
          )
        : value == null
        ? context.tr(
            '当前已选择部分，点击后选择全部',
            'Some items are selected. Activate to select all.',
          )
        : context.tr(
            '当前未选择，点击后选择全部',
            'No items are selected. Activate to select all.',
          );
    final option = BaseCheckOption(
      title: effectiveTitle,
      subtitle: effectiveSubtitle,
      value: value,
      toggle: toggle,
      tristate: tristate,
      onChanged: onChanged,
      horizontalPadding: bulkControl
          ? CheckOptionValues.bulkHorizontalPadding
          : CheckOptionValues.horizontalPadding,
      verticalPadding: CheckOptionValues.verticalPadding,
      minimumVerticalPadding: CheckOptionValues.minimumVerticalPadding,
      minimumAccessibleTargetSize:
          CheckOptionValues.minimumAccessibleTargetSize,
      horizontalDensity: CheckOptionValues.horizontalDensity,
      verticalDensity: CheckOptionValues.verticalDensity,
      titleStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: CheckOptionValues.titleFontSize,
        fontWeight:
            FontWeight.values[bulkControl
                ? CheckOptionValues.bulkTitleFontWeightIndex
                : CheckOptionValues.titleFontWeightIndex],
      ),
      subtitleStyle: TextStyle(
        fontFamily: ThemeValues.fontFamily,
        fontSize: CheckOptionValues.subtitleFontSize,
        fontWeight:
            FontWeight.values[CheckOptionValues.subtitleFontWeightIndex],
      ),
    );
    if (!bulkControl) return option;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: context.tr('批量选择控制', 'Bulk selection control'),
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CheckOptionValues.bulkRadius),
          side: BorderSide(
            color: scheme.outlineVariant,
            width: CheckOptionValues.bulkBorderWidth,
          ),
        ),
        child: option,
      ),
    );
  }
}

class AppSegmentOption<T> extends BaseSegmentOption<T> {
  const AppSegmentOption(super.value, super.label, {super.icon});
}

class AppSegmentedSelector<T> extends StatelessWidget {
  final T value;
  final List<AppSegmentOption<T>> options;
  final ValueChanged<T>? onChanged;
  final String semanticLabel;
  const AppSegmentedSelector({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.semanticLabel,
  });
  @override
  Widget build(BuildContext context) => BaseSegmentedSelector<T>(
    value: value,
    options: options,
    onChanged: onChanged,
    minimumHeight: SegmentedSelectorValues.minimumHeight,
    minimumAccessibleTargetSize:
        SegmentedSelectorValues.minimumAccessibleTargetSize,
    horizontalPadding: SegmentedSelectorValues.horizontalPadding,
    verticalPadding: SegmentedSelectorValues.verticalPadding,
    radius: SegmentedSelectorValues.radius,
    borderWidth: SegmentedSelectorValues.borderWidth,
    iconSize: SegmentedSelectorValues.iconSize,
    fontSize: SegmentedSelectorValues.fontSize,
    fontWeight: FontWeight.values[SegmentedSelectorValues.fontWeightIndex],
    semanticLabel: semanticLabel,
    fontFamily: ThemeValues.fontFamily,
  );
}
