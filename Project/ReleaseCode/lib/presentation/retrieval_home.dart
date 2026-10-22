import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../application/application_controller.dart';
import 'app_localizations.dart';
import 'library_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'status_messages.dart';
import '../configuration/presentation/pages/home_values.dart';
import 'design_system/presets/app_form_dialog.dart';

class RetrievalHome extends StatefulWidget {
  final ApplicationController controller;

  const RetrievalHome({super.key, required this.controller});

  @override
  State<RetrievalHome> createState() => _RetrievalHomeState();
}

class _RetrievalHomeState extends State<RetrievalHome> {
  var _page = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _showOnboarding());
  }

  Future<void> _showOnboarding() async {
    if (!mounted || !widget.controller.shouldShowOnboarding) return;
    final openSettings = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AppFormDialog(
        title: context.tr('首次使用提醒', 'First-use information'),
        content: Text(
          context.tr(
            '当前界面已使用默认无障碍设置。如需修改语言、颜色、字号和界面大小，请前往“设置”。索引与查询服务也需要先在“设置”中确认保存位置并启动。',
            'The interface currently uses the default accessibility settings. Open Settings to change the language, colors, text size, or interface size. The indexing and search service must also be configured and started in Settings.',
          ),
        ),
        cancelLabel: context.tr('知道了', 'Got it'),
        confirmLabel: context.tr('前往设置', 'Open Settings'),
        onCancel: () => Navigator.pop(dialogContext, false),
        onConfirm: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (openSettings == true) _selectPage(2);
    await widget.controller.completeOnboarding();
  }

  void _selectPage(int value) {
    if (_page == value) return;
    setState(() => _page = value);
    final names = [
      context.tr('文件库', 'Library'),
      context.tr('查询', 'Search'),
      context.tr('设置', 'Settings'),
    ];
    SemanticsService.sendAnnouncement(
      View.of(context),
      context.tr('已打开${names[value]}页面', '${names[value]} page opened'),
      Directionality.of(context),
    );
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.digit1, alt: true): () =>
          _selectPage(0),
      const SingleActivator(LogicalKeyboardKey.digit2, alt: true): () =>
          _selectPage(1),
      const SingleActivator(LogicalKeyboardKey.digit3, alt: true): () =>
          _selectPage(2),
    },
    child: Focus(
      autofocus: true,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) => Scaffold(
            appBar: AppBar(
              toolbarHeight: HomeValues.appBarHeight,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.tr('本地文件检索', 'Local File Search')),
                  Text(
                    context.tr(
                      '文件只在本机处理',
                      'Files are processed only on this device',
                    ),
                    style: TextStyle(
                      fontSize: HomeValues.appBarStatusFontSize,
                      fontWeight: FontWeight
                          .values[HomeValues.appBarStatusFontWeightIndex],
                    ),
                  ),
                ],
              ),
              actions: [_ServiceStatus(controller: widget.controller)],
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                final pages = IndexedStack(
                  index: _page,
                  children: [
                    LibraryPage(controller: widget.controller),
                    SearchPage(
                      controller: widget.controller,
                      onOpenLibrary: () => _selectPage(0),
                    ),
                    SettingsPage(controller: widget.controller),
                  ],
                );
                final content = Column(
                  children: [
                    _StatusBanner(controller: widget.controller),
                    Expanded(child: pages),
                  ],
                );
                if (constraints.maxWidth < HomeValues.railBreakpoint) {
                  return content;
                }
                return Row(
                  children: [
                    _DesktopNavigation(
                      selectedIndex: _page,
                      onSelected: _selectPage,
                    ),
                    const VerticalDivider(width: HomeValues.railDividerWidth),
                    Expanded(child: content),
                  ],
                );
              },
            ),
            bottomNavigationBar:
                MediaQuery.sizeOf(context).width < HomeValues.railBreakpoint
                ? NavigationBar(
                    height: HomeValues.navigationBarHeight,
                    selectedIndex: _page,
                    onDestinationSelected: _selectPage,
                    destinations: [
                      NavigationDestination(
                        icon: const Icon(
                          Icons.folder_copy_outlined,
                          size: HomeValues.navigationDestinationIconSize,
                        ),
                        selectedIcon: const Icon(
                          Icons.folder_copy,
                          size: HomeValues.navigationDestinationIconSize,
                        ),
                        label: context.tr('文件库', 'Library'),
                        tooltip: context.tr('文件库（Alt+1）', 'Library (Alt+1)'),
                      ),
                      NavigationDestination(
                        icon: const Icon(
                          Icons.search_outlined,
                          size: HomeValues.navigationDestinationIconSize,
                        ),
                        selectedIcon: const Icon(
                          Icons.search,
                          size: HomeValues.navigationDestinationIconSize,
                        ),
                        label: context.tr('查询', 'Search'),
                        tooltip: context.tr('查询（Alt+2）', 'Search (Alt+2)'),
                      ),
                      NavigationDestination(
                        icon: const Icon(
                          Icons.settings_outlined,
                          size: HomeValues.navigationDestinationIconSize,
                        ),
                        selectedIcon: const Icon(
                          Icons.settings,
                          size: HomeValues.navigationDestinationIconSize,
                        ),
                        label: context.tr('设置', 'Settings'),
                        tooltip: context.tr('设置（Alt+3）', 'Settings (Alt+3)'),
                      ),
                    ],
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}

class _DesktopNavigation extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _DesktopNavigation({
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    width: HomeValues.railWidth,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeValues.railHorizontalPadding,
        HomeValues.railTopPadding,
        HomeValues.railHorizontalPadding,
        HomeValues.zeroPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: HomeValues.railHeadingLeftPadding,
              bottom: HomeValues.railHeadingBottomPadding,
            ),
            child: Text(context.tr('主要功能', 'Main features')),
          ),
          _NavigationItem(
            label: context.tr('文件库', 'Library'),
            shortcutLabel: 'Alt+1',
            semanticShortcut: context.tr('Alt 加 1', 'Alt plus 1'),
            icon: Icons.folder_copy_outlined,
            selectedIcon: Icons.folder_copy,
            selected: selectedIndex == 0,
            onTap: () => onSelected(0),
          ),
          const SizedBox(height: HomeValues.railDestinationGap),
          _NavigationItem(
            label: context.tr('查询', 'Search'),
            shortcutLabel: 'Alt+2',
            semanticShortcut: context.tr('Alt 加 2', 'Alt plus 2'),
            icon: Icons.search_outlined,
            selectedIcon: Icons.search,
            selected: selectedIndex == 1,
            onTap: () => onSelected(1),
          ),
          const SizedBox(height: HomeValues.railDestinationGap),
          _NavigationItem(
            label: context.tr('设置', 'Settings'),
            shortcutLabel: 'Alt+3',
            semanticShortcut: context.tr('Alt 加 3', 'Alt plus 3'),
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            selected: selectedIndex == 2,
            onTap: () => onSelected(2),
          ),
        ],
      ),
    ),
  );
}

class _NavigationItem extends StatelessWidget {
  final String label;
  final String shortcutLabel;
  final String semanticShortcut;
  final IconData icon;
  final IconData selectedIcon;
  final bool selected;
  final VoidCallback onTap;

  const _NavigationItem({
    required this.label,
    required this.shortcutLabel,
    required this.semanticShortcut,
    required this.icon,
    required this.selectedIcon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = selected
        ? scheme.onSecondaryContainer
        : scheme.onSurface;
    return Tooltip(
      message: context.tr(
        '$label，快捷键 $shortcutLabel',
        '$label, shortcut $shortcutLabel',
      ),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        hint: context.tr('快捷键 $semanticShortcut', 'Shortcut $semanticShortcut'),
        excludeSemantics: true,
        child: Material(
          color: selected ? scheme.secondaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(HomeValues.railDestinationRadius),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(
              HomeValues.railDestinationRadius,
            ),
            child: SizedBox(
              height: HomeValues.railDestinationHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HomeValues.railDestinationHorizontalPadding,
                ),
                child: Row(
                  children: [
                    Icon(
                      selected ? selectedIcon : icon,
                      size: HomeValues.railDestinationIconSize,
                      color: foreground,
                    ),
                    const SizedBox(
                      width: HomeValues.railDestinationIconToLabelGap,
                    ),
                    Expanded(
                      child: Text(label, style: TextStyle(color: foreground)),
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
}

class _ServiceStatus extends StatelessWidget {
  final ApplicationController controller;

  const _ServiceStatus({required this.controller});

  @override
  Widget build(BuildContext context) {
    final ready = controller.ready;
    final working = controller.busy;
    final label = working
        ? controller.statusMessage
        : ready
        ? context.tr(
            StatusMessages.serviceStarted(context),
            'Indexing and search service started',
          )
        : context.tr(
            '索引与查询服务未启动',
            'Indexing and search service is not running',
          );
    final hint = working
        ? controller.statusMessage
        : ready
        ? context.tr('现在可以建立索引和查询文件', 'You can now index and search files')
        : context.tr(
            '请前往“设置”选择索引保存位置并启动服务',
            'Open Settings, choose where to store the index, and start the service',
          );
    final color = working
        ? Theme.of(context).colorScheme.tertiary
        : ready
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(
        right: HomeValues.serviceStatusRightPadding,
      ),
      child: Tooltip(
        message: hint,
        child: Semantics(
          container: true,
          liveRegion: true,
          label: label,
          hint: hint,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: HomeValues.serviceStatusDotSize,
                height: HomeValues.serviceStatusDotSize,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: HomeValues.serviceStatusGap),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight
                      .values[HomeValues.serviceStatusFontWeightIndex],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final ApplicationController controller;

  const _StatusBanner({required this.controller});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    label: context.tr(
      '程序状态：${controller.statusMessage}',
      'Application status: ${controller.statusMessage}',
    ),
    excludeSemantics: true,
    child: Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(
        horizontal: HomeValues.statusBannerHorizontalPadding,
        vertical: HomeValues.statusBannerVerticalPadding,
      ),
      child: Row(
        children: [
          if (controller.busy)
            const Padding(
              padding: EdgeInsets.only(
                right: HomeValues.statusIndicatorRightPadding,
              ),
              child: SizedBox(
                width: HomeValues.statusIndicatorSize,
                height: HomeValues.statusIndicatorSize,
                child: CircularProgressIndicator(
                  strokeWidth: HomeValues.statusProgressStrokeWidth,
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.only(
                right: HomeValues.statusIndicatorRightPadding,
              ),
              child: Icon(
                Icons.info_outline,
                size: HomeValues.statusIndicatorSize,
              ),
            ),
          Expanded(
            child: Text(
              controller.statusMessage,
              style: TextStyle(
                fontWeight:
                    FontWeight.values[HomeValues.statusMessageFontWeightIndex],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
