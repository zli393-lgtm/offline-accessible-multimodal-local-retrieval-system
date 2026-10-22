import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'runtime_configuration.dart';

enum AppTextSize { small, standard, accessibility, large, extraLarge }

enum AppLanguage { simplifiedChinese, english }

extension AppLanguageValue on AppLanguage {
  String get nativeLabel => switch (this) {
    AppLanguage.simplifiedChinese => '简体中文',
    AppLanguage.english => 'English',
  };

  String label(AppLanguage displayLanguage) => switch ((
    this,
    displayLanguage,
  )) {
    (AppLanguage.simplifiedChinese, AppLanguage.simplifiedChinese) => '简体中文',
    (AppLanguage.english, AppLanguage.simplifiedChinese) => '英语',
    (AppLanguage.simplifiedChinese, AppLanguage.english) =>
      'Simplified Chinese',
    (AppLanguage.english, AppLanguage.english) => 'English',
  };

  String get localeCode => switch (this) {
    AppLanguage.simplifiedChinese => 'zh',
    AppLanguage.english => 'en',
  };
}

extension AppTextSizeValue on AppTextSize {
  double get scale => switch (this) {
    AppTextSize.small => 0.9,
    AppTextSize.standard => 1.0,
    AppTextSize.accessibility => 1.15,
    AppTextSize.large => 1.3,
    AppTextSize.extraLarge => 1.5,
  };

  double get visualDensityAdjustment => switch (this) {
    AppTextSize.small => -1,
    AppTextSize.standard => 0,
    AppTextSize.accessibility => 1,
    AppTextSize.large => 2,
    AppTextSize.extraLarge => 3,
  };

  String get label => switch (this) {
    AppTextSize.small => '小',
    AppTextSize.standard => '标准',
    AppTextSize.accessibility => '无障碍（默认）',
    AppTextSize.large => '大',
    AppTextSize.extraLarge => '更大',
  };
}

enum UiColorMode { standard, accessibility }

extension UiColorModeValue on UiColorMode {
  String get label => switch (this) {
    UiColorMode.standard => '默认配色',
    UiColorMode.accessibility => '色觉无障碍',
  };
}

enum UiColorPreset { grayscale, blue, green, pink, yellow, orange, lightPurple }

extension UiColorPresetValue on UiColorPreset {
  String get label => switch (this) {
    UiColorPreset.blue => '蓝色',
    UiColorPreset.green => '绿色',
    UiColorPreset.pink => '粉红色',
    UiColorPreset.yellow => '黄色',
    UiColorPreset.orange => '橘色',
    UiColorPreset.lightPurple => '浅紫色',
    UiColorPreset.grayscale => '灰阶色',
  };
}

enum ColorVisionPreset { protanopia, deuteranopia, tritanopia }

extension ColorVisionPresetValue on ColorVisionPreset {
  String get label => switch (this) {
    ColorVisionPreset.protanopia => '红绿色觉辅助（红色型）',
    ColorVisionPreset.deuteranopia => '红绿色觉辅助（绿色型）',
    ColorVisionPreset.tritanopia => '蓝黄色觉辅助',
  };

  String get standardName => switch (this) {
    ColorVisionPreset.protanopia => 'Protanopia',
    ColorVisionPreset.deuteranopia => 'Deuteranopia',
    ColorVisionPreset.tritanopia => 'Tritanopia',
  };
}

class UiPreferences {
  final AppTextSize textSize;
  final UiColorMode colorMode;
  final UiColorPreset colorPreset;
  final ColorVisionPreset colorVisionPreset;
  final bool highContrast;
  final AppLanguage language;
  final bool onboardingCompleted;

  const UiPreferences({
    this.textSize = AppTextSize.accessibility,
    this.colorMode = UiColorMode.standard,
    this.colorPreset = UiColorPreset.grayscale,
    this.colorVisionPreset = ColorVisionPreset.deuteranopia,
    this.highContrast = true,
    this.language = AppLanguage.simplifiedChinese,
    this.onboardingCompleted = false,
  });

  UiPreferences copyWith({
    AppTextSize? textSize,
    UiColorMode? colorMode,
    UiColorPreset? colorPreset,
    ColorVisionPreset? colorVisionPreset,
    bool? highContrast,
    AppLanguage? language,
    bool? onboardingCompleted,
  }) => UiPreferences(
    textSize: textSize ?? this.textSize,
    colorMode: colorMode ?? this.colorMode,
    colorPreset: colorPreset ?? this.colorPreset,
    colorVisionPreset: colorVisionPreset ?? this.colorVisionPreset,
    highContrast: highContrast ?? this.highContrast,
    language: language ?? this.language,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
  );

  Map<String, Object> toJson() => {
    'version': 6,
    'textSize': textSize.name,
    'colorMode': colorMode.name,
    'colorPreset': colorPreset.name,
    'colorVisionPreset': colorVisionPreset.name,
    'highContrast': highContrast,
    'language': language.name,
    'onboardingCompleted': onboardingCompleted,
  };

  factory UiPreferences.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != 1 &&
        version != 2 &&
        version != 3 &&
        version != 4 &&
        version != 5 &&
        version != 6) {
      throw const FormatException('Unsupported interface settings format.');
    }
    if (version == 1 || version == 2 || version == 3 || version == 4) {
      return UiPreferences(
        textSize: _migrateTextSize(json['textSize'] as String?),
        colorMode: version == 1
            ? (json['highContrast'] as bool? ?? false)
                  ? UiColorMode.accessibility
                  : UiColorMode.standard
            : UiColorMode.values.byName(
                json['colorMode'] as String? ?? UiColorMode.standard.name,
              ),
        colorPreset: UiColorPreset.grayscale,
        colorVisionPreset: version == 2 || version == 3
            ? _parseColorVisionPreset(json['colorVisionPreset'] as String?)
            : ColorVisionPreset.deuteranopia,
        highContrast: version == 1
            ? json['highContrast'] as bool? ?? false
            : json['highContrast'] as bool? ?? true,
        onboardingCompleted: true,
      );
    }
    return UiPreferences(
      textSize: AppTextSize.values.byName(
        json['textSize'] as String? ?? AppTextSize.accessibility.name,
      ),
      colorMode: UiColorMode.values.byName(
        json['colorMode'] as String? ?? UiColorMode.standard.name,
      ),
      colorPreset: UiColorPreset.values.byName(
        json['colorPreset'] as String? ?? UiColorPreset.grayscale.name,
      ),
      colorVisionPreset: _parseColorVisionPreset(
        json['colorVisionPreset'] as String?,
      ),
      highContrast: json['highContrast'] as bool? ?? true,
      language: AppLanguage.values.byName(
        json['language'] as String? ?? AppLanguage.simplifiedChinese.name,
      ),
      onboardingCompleted: version >= 6
          ? json['onboardingCompleted'] as bool? ?? false
          : true,
    );
  }

  static ColorVisionPreset _parseColorVisionPreset(String? value) =>
      switch (value) {
        'protanopia' || 'red' => ColorVisionPreset.protanopia,
        'tritanopia' || 'yellow' || 'blue' => ColorVisionPreset.tritanopia,
        'deuteranopia' || 'green' || null => ColorVisionPreset.deuteranopia,
        _ => ColorVisionPreset.deuteranopia,
      };

  static AppTextSize _migrateTextSize(String? value) => switch (value) {
    'small' => AppTextSize.small,
    'large' => AppTextSize.large,
    'extraLarge' => AppTextSize.extraLarge,
    'standard' || null => AppTextSize.accessibility,
    _ => AppTextSize.accessibility,
  };
}

class UiPreferencesStore {
  final File file;

  const UiPreferencesStore(this.file);

  factory UiPreferencesStore.platformDefault() => UiPreferencesStore(
    File(
      p.join(
        RuntimeConfigurationStore.settingsDirectory(),
        'interface-settings.json',
      ),
    ),
  );

  Future<UiPreferences?> load() async {
    if (!await file.exists()) return null;
    final value = jsonDecode(await file.readAsString());
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Interface settings must be a JSON object.');
    }
    return UiPreferences.fromJson(value);
  }

  Future<void> save(UiPreferences preferences) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(preferences.toJson()),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}
