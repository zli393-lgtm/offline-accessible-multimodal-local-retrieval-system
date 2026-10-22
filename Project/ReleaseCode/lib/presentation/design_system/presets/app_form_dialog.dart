import 'package:flutter/material.dart';

import '../../app_localizations.dart';

import 'app_action_button.dart';
import '../../../configuration/presentation/controls/form_dialog_values.dart';
import '../../../configuration/presentation/theme/theme_values.dart';

class AppFormDialog extends StatefulWidget {
  final String title;
  final Widget content;
  final String cancelLabel;
  final String? confirmLabel;
  final String? alternativeLabel;
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;
  final VoidCallback? onAlternative;
  const AppFormDialog({
    super.key,
    required this.title,
    required this.content,
    required this.cancelLabel,
    this.confirmLabel,
    this.alternativeLabel,
    required this.onCancel,
    this.onConfirm,
    this.onAlternative,
  });
  @override
  State<AppFormDialog> createState() => _AppFormDialogState();
}

class _AppFormDialogState extends State<AppFormDialog> {
  double _width = FormDialogValues.initialWidth;
  double _height = FormDialogValues.initialHeight;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final colors = Theme.of(context).colorScheme;
    final maximumWidth =
        viewport.width * FormDialogValues.maximumViewportWidthRatio;
    final maximumHeight =
        viewport.height * FormDialogValues.maximumViewportHeightRatio;
    _width = _width.clamp(FormDialogValues.minimumWidth, maximumWidth);
    _height = _height.clamp(FormDialogValues.minimumHeight, maximumHeight);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: widget.title,
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Dialog(
          backgroundColor: colors.surface,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: FormDialogValues.insetHorizontalPadding,
            vertical: FormDialogValues.insetVerticalPadding,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(FormDialogValues.radius),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(
              color: colors.onSurface,
              fontFamily: ThemeValues.fontFamily,
            ),
            child: IconTheme.merge(
              data: IconThemeData(color: colors.onSurface),
              child: SizedBox(
                width: _width,
                height: _height,
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        FormDialogValues.contentHorizontalPadding,
                        FormDialogValues.titleTopPadding,
                        FormDialogValues.contentHorizontalPadding,
                        FormDialogValues.actionsBottomPadding,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              widget.title,
                              style: TextStyle(
                                fontSize: FormDialogValues.titleFontSize,
                                fontWeight:
                                    FontWeight.values[FormDialogValues
                                        .titleFontWeightIndex],
                              ),
                            ),
                          ),
                          const SizedBox(
                            height: FormDialogValues.contentTopPadding,
                          ),
                          Expanded(
                            child: SingleChildScrollView(child: widget.content),
                          ),
                          const SizedBox(
                            height: FormDialogValues.contentBottomPadding,
                          ),
                          Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: FormDialogValues.actionGap,
                            runSpacing: FormDialogValues.actionRunGap,
                            children: [
                              if (widget.alternativeLabel != null)
                                AppActionButton(
                                  label: widget.alternativeLabel!,
                                  onPressed: widget.onAlternative,
                                  kind: AppActionButtonKind.secondary,
                                ),
                              AppActionButton(
                                label: widget.cancelLabel,
                                onPressed: widget.onCancel,
                                kind: AppActionButtonKind.text,
                              ),
                              if (widget.confirmLabel != null)
                                AppActionButton(
                                  label: widget.confirmLabel!,
                                  onPressed: widget.onConfirm,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _resizeCorner(
                      alignment: Alignment.topLeft,
                      cursor: SystemMouseCursors.resizeUpLeftDownRight,
                      horizontalDirection: -1,
                      verticalDirection: -1,
                      maximumWidth: maximumWidth,
                      maximumHeight: maximumHeight,
                    ),
                    _resizeCorner(
                      alignment: Alignment.topRight,
                      cursor: SystemMouseCursors.resizeUpRightDownLeft,
                      horizontalDirection: 1,
                      verticalDirection: -1,
                      maximumWidth: maximumWidth,
                      maximumHeight: maximumHeight,
                    ),
                    _resizeCorner(
                      alignment: Alignment.bottomLeft,
                      cursor: SystemMouseCursors.resizeUpRightDownLeft,
                      horizontalDirection: -1,
                      verticalDirection: 1,
                      maximumWidth: maximumWidth,
                      maximumHeight: maximumHeight,
                    ),
                    _resizeCorner(
                      alignment: Alignment.bottomRight,
                      cursor: SystemMouseCursors.resizeUpLeftDownRight,
                      horizontalDirection: 1,
                      verticalDirection: 1,
                      maximumWidth: maximumWidth,
                      maximumHeight: maximumHeight,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _resizeCorner({
    required Alignment alignment,
    required MouseCursor cursor,
    required double horizontalDirection,
    required double verticalDirection,
    required double maximumWidth,
    required double maximumHeight,
  }) {
    final top = alignment.y < 0 ? 0.0 : null;
    final bottom = alignment.y > 0 ? 0.0 : null;
    final left = alignment.x < 0 ? 0.0 : null;
    final right = alignment.x > 0 ? 0.0 : null;
    final isAccessibleCorner = alignment == Alignment.bottomRight;
    final language = Localizations.of<AppLocalizations>(
      context,
      AppLocalizations,
    );
    final resizeTarget = MouseRegion(
      cursor: cursor,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (details) => setState(() {
          _width = (_width + details.delta.dx * horizontalDirection).clamp(
            FormDialogValues.minimumWidth,
            maximumWidth,
          );
          _height = (_height + details.delta.dy * verticalDirection).clamp(
            FormDialogValues.minimumHeight,
            maximumHeight,
          );
        }),
        child: const SizedBox.square(
          dimension: FormDialogValues.resizeCornerHitSize,
        ),
      ),
    );
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: isAccessibleCorner
          ? Semantics(
              container: true,
              button: true,
              label: language?.text('调整弹窗大小', 'Resize dialog') ?? '调整弹窗大小',
              hint:
                  language?.text(
                    '用鼠标拖动弹窗角落',
                    'Drag a dialog corner with the mouse',
                  ) ??
                  '用鼠标拖动弹窗角落',
              child: resizeTarget,
            )
          : resizeTarget,
    );
  }
}
