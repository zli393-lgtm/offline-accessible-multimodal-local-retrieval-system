import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'application/application_controller.dart';
import 'application/ui_preferences.dart';
import 'presentation/retrieval_home.dart';
import 'presentation/app_localizations.dart';
import 'configuration/presentation/theme/theme_values.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = ApplicationController();
  await controller.initialize();
  runApp(RetrievalApp(controller: controller));
}

class RetrievalApp extends StatefulWidget {
  final ApplicationController controller;

  const RetrievalApp({super.key, required this.controller});

  @override
  State<RetrievalApp> createState() => _RetrievalAppState();
}

class _RetrievalAppState extends State<RetrievalApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final preferences = widget.controller.uiPreferences;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: '本地文件检索',
        locale: Locale(preferences.language.localeCode),
        supportedLocales: const [Locale('zh'), Locale('en')],
        localizationsDelegates: const [
          AppLocalizationsDelegate(),
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _theme(preferences),
        builder: (context, child) {
          final media = MediaQuery.of(context);
          final systemScale = media.textScaler.scale(ThemeValues.baseTextScale);
          final effectiveScale = systemScale * preferences.textSize.scale;
          return MediaQuery(
            data: media.copyWith(textScaler: TextScaler.linear(effectiveScale)),
            child: child!,
          );
        },
        home: RetrievalHome(controller: widget.controller),
      );
    },
  );

  ThemeData _theme(UiPreferences preferences) {
    final accessibilitySecondarySeed =
        preferences.colorMode == UiColorMode.accessibility
        ? switch (preferences.colorVisionPreset) {
            ColorVisionPreset.protanopia => ThemeValues.protanopiaSecondary,
            ColorVisionPreset.deuteranopia => ThemeValues.deuteranopiaSecondary,
            ColorVisionPreset.tritanopia => ThemeValues.tritanopiaSecondary,
          }
        : null;
    final seed = preferences.colorMode == UiColorMode.standard
        ? switch (preferences.colorPreset) {
            UiColorPreset.blue => ThemeValues.blueSeed,
            UiColorPreset.green => ThemeValues.greenSeed,
            UiColorPreset.pink => ThemeValues.pinkSeed,
            UiColorPreset.yellow => ThemeValues.yellowSeed,
            UiColorPreset.orange => ThemeValues.orangeSeed,
            UiColorPreset.lightPurple => ThemeValues.lightPurpleSeed,
            UiColorPreset.grayscale => ThemeValues.grayscaleSeed,
          }
        : switch (preferences.colorVisionPreset) {
            ColorVisionPreset.protanopia => ThemeValues.protanopiaSeed,
            ColorVisionPreset.deuteranopia => ThemeValues.deuteranopiaSeed,
            ColorVisionPreset.tritanopia => ThemeValues.tritanopiaSeed,
          };
    final isGrayscale =
        preferences.colorMode == UiColorMode.standard &&
        preferences.colorPreset == UiColorPreset.grayscale;
    var generatedScheme = ColorScheme.fromSeed(
      seedColor: Color(seed),
      contrastLevel: preferences.highContrast ? 1 : 0,
    );
    if (accessibilitySecondarySeed != null) {
      final secondaryScheme = ColorScheme.fromSeed(
        seedColor: Color(accessibilitySecondarySeed),
        contrastLevel: preferences.highContrast ? 1 : 0,
      );
      generatedScheme = generatedScheme.copyWith(
        secondary: secondaryScheme.primary,
        onSecondary: secondaryScheme.onPrimary,
        secondaryContainer: secondaryScheme.primaryContainer,
        onSecondaryContainer: secondaryScheme.onPrimaryContainer,
      );
    }
    final grayscalePrimary = Color(
      preferences.highContrast
          ? ThemeValues.grayscalePrimary
          : ThemeValues.grayscalePrimarySoft,
    );
    final grayscaleOutline = Color(
      preferences.highContrast
          ? ThemeValues.grayscaleOutline
          : ThemeValues.grayscaleOutlineSoft,
    );
    final grayscaleContainer = Color(
      preferences.highContrast
          ? ThemeValues.grayscaleHighContrastContainer
          : ThemeValues.grayscaleContainer,
    );
    final onGrayscaleContainer = preferences.highContrast
        ? Colors.white
        : Colors.black;
    final scheme = isGrayscale
        ? generatedScheme.copyWith(
            primary: grayscalePrimary,
            onPrimary: Colors.white,
            primaryContainer: grayscaleContainer,
            onPrimaryContainer: onGrayscaleContainer,
            secondary: const Color(ThemeValues.grayscalePrimarySoft),
            onSecondary: Colors.white,
            secondaryContainer: grayscaleContainer,
            onSecondaryContainer: onGrayscaleContainer,
            tertiary: const Color(ThemeValues.grayscaleOutlineSoft),
            onTertiary: Colors.white,
            tertiaryContainer: const Color(ThemeValues.grayscaleContainerHigh),
            onTertiaryContainer: Colors.black,
            error: grayscalePrimary,
            onError: Colors.white,
            errorContainer: const Color(ThemeValues.grayscaleContainerHigh),
            onErrorContainer: Colors.black,
            surface: Colors.white,
            onSurface: Colors.black,
            surfaceContainerLowest: Colors.white,
            surfaceContainerLow: const Color(ThemeValues.grayscaleSurfaceLow),
            surfaceContainer: const Color(ThemeValues.grayscaleSurface),
            surfaceContainerHigh: const Color(
              ThemeValues.grayscaleSurfaceHigh,
            ),
            surfaceContainerHighest: const Color(
              ThemeValues.grayscaleSurfaceHighest,
            ),
            onSurfaceVariant: const Color(ThemeValues.grayscalePrimarySoft),
            outline: grayscaleOutline,
            outlineVariant: const Color(ThemeValues.grayscaleOutlineVariant),
            inverseSurface: Colors.black,
            onInverseSurface: Colors.white,
            inversePrimary: const Color(ThemeValues.grayscaleContainerHigh),
            shadow: Colors.black,
            scrim: Colors.black,
          )
        : generatedScheme;
    final background = isGrayscale
        ? Color(
            preferences.highContrast
                ? ThemeValues.grayscaleHighContrastBackground
                : ThemeValues.grayscaleBackground,
          )
        : Color.alphaBlend(
            scheme.primary.withValues(
              alpha: ThemeValues.standardBackgroundTintOpacity,
            ),
            const Color(ThemeValues.standardBackground),
          );
    final baseTextTheme = ThemeData.light().textTheme.apply(
      fontFamily: ThemeValues.fontFamily,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      useMaterial3: true,
      fontFamily: ThemeValues.fontFamily,
      textTheme: baseTextTheme.copyWith(
        headlineLarge: baseTextTheme.headlineLarge?.copyWith(
          color: scheme.primary,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          color: scheme.primary,
        ),
        headlineSmall: baseTextTheme.headlineSmall?.copyWith(
          color: scheme.primary,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(color: scheme.primary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: baseTextTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
        ),
        contentTextStyle: baseTextTheme.bodyMedium?.copyWith(
          color: scheme.onSurface,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        textStyle: baseTextTheme.bodyMedium?.copyWith(color: scheme.onSurface),
      ),
      splashFactory: NoSplash.splashFactory,
      visualDensity: VisualDensity(
        horizontal: preferences.textSize.visualDensityAdjustment,
        vertical: preferences.textSize.visualDensityAdjustment,
      ),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}
