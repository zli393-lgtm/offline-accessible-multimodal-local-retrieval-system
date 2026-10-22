import 'package:flutter/material.dart';

import '../base/base_ellipse_button.dart';
import '../base/base_rect_button.dart';
import '../../../configuration/presentation/controls/action_button_values.dart';
import '../../../configuration/presentation/controls/ellipse_button_values.dart';
import '../../../configuration/presentation/theme/theme_values.dart';

enum AppActionButtonKind { primary, secondary, text, danger }

class AppActionButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final AppActionButtonKind kind;
  final double? width;
  final String? semanticHint;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;

  const AppActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.kind = AppActionButtonKind.primary,
    this.width,
    this.semanticHint,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, border) = switch (kind) {
      AppActionButtonKind.primary => (
        scheme.primary,
        scheme.onPrimary,
        scheme.primary,
      ),
      AppActionButtonKind.secondary => (
        scheme.surface,
        scheme.primary,
        scheme.outline,
      ),
      AppActionButtonKind.text => (
        scheme.surface.withValues(alpha: ActionButtonValues.transparentOpacity),
        scheme.primary,
        scheme.surface.withValues(alpha: ActionButtonValues.transparentOpacity),
      ),
      AppActionButtonKind.danger => (
        scheme.error,
        scheme.onError,
        scheme.error,
      ),
    };
    final grey = scheme.onSurface;
    final pressedBackground = Color.lerp(
      background,
      grey,
      ActionButtonValues.pressedBackgroundGreyRatio,
    )!;
    final pressedForeground = Color.lerp(
      foreground,
      grey,
      ActionButtonValues.pressedForegroundGreyRatio,
    )!;
    final disabledBackground = background.withValues(
      alpha: ActionButtonValues.disabledOpacity,
    );
    final disabledForeground = foreground.withValues(
      alpha: ActionButtonValues.disabledOpacity,
    );
    final content = icon == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: ActionButtonValues.iconSize),
              const SizedBox(width: ActionButtonValues.iconGap),
              Text(label),
            ],
          );
    return BaseRectButton(
      width: width,
      height: ActionButtonValues.height,
      minimumWidth: ActionButtonValues.minimumWidth,
      minimumAccessibleTargetSize:
          ActionButtonValues.minimumAccessibleTargetSize,
      radius: ActionButtonValues.radius,
      borderWidth: ActionButtonValues.borderWidth,
      horizontalPadding: ActionButtonValues.horizontalPadding,
      verticalPadding: ActionButtonValues.verticalPadding,
      fontSize: ActionButtonValues.fontSize,
      fontWeight: FontWeight.values[ActionButtonValues.fontWeightIndex],
      fontFamily: ThemeValues.fontFamily,
      backgroundColor: background,
      foregroundColor: foreground,
      pressedBackgroundColor: pressedBackground,
      pressedForegroundColor: pressedForeground,
      disabledBackgroundColor: disabledBackground,
      disabledForegroundColor: disabledForeground,
      borderColor: border,
      shadowColor: scheme.shadow.withValues(
        alpha: ActionButtonValues.shadowOpacity,
      ),
      shadowBlur: kind == AppActionButtonKind.primary
          ? ActionButtonValues.shadowBlur
          : ActionButtonValues.noShadowBlur,
      elevation: ActionButtonValues.elevation,
      visibleShadowThreshold: ActionButtonValues.visibleShadowThreshold,
      shadowOffset: const Offset(
        ActionButtonValues.shadowOffsetX,
        ActionButtonValues.shadowOffsetY,
      ),
      semanticLabel: label,
      semanticHint: semanticHint,
      tooltip: tooltip,
      focusNode: focusNode,
      autofocus: autofocus,
      interactionDuration: const Duration(
        milliseconds: ActionButtonValues.interactionDurationMilliseconds,
      ),
      onPressed: onPressed,
      child: content,
    );
  }
}

class AppEllipseIconButton extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final bool circular;
  final String? semanticHint;
  final FocusNode? focusNode;
  final bool autofocus;

  const AppEllipseIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.onPressed,
    this.circular = true,
    this.semanticHint,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = scheme.primaryContainer;
    return BaseEllipseButton(
      longAxis: circular
          ? EllipseButtonValues.circularDiameter
          : EllipseButtonValues.ellipseLongAxis,
      shortAxis: circular
          ? EllipseButtonValues.circularDiameter
          : EllipseButtonValues.ellipseShortAxis,
      minimumAccessibleTargetSize:
          EllipseButtonValues.minimumAccessibleTargetSize,
      backgroundColor: background,
      foregroundColor: scheme.onPrimaryContainer,
      pressedBackgroundColor: Color.lerp(
        background,
        scheme.onSurface,
        EllipseButtonValues.pressedBackgroundGreyRatio,
      )!,
      pressedForegroundColor: scheme.onPrimaryContainer,
      borderColor: scheme.outline,
      borderWidth: EllipseButtonValues.borderWidth,
      contentPadding: EllipseButtonValues.contentPadding,
      semanticLabel: semanticLabel,
      semanticHint: semanticHint,
      tooltip: semanticLabel,
      focusNode: focusNode,
      autofocus: autofocus,
      interactionDuration: const Duration(
        milliseconds: ActionButtonValues.interactionDurationMilliseconds,
      ),
      onPressed: onPressed,
      child: Icon(icon, size: EllipseButtonValues.iconSize),
    );
  }
}
