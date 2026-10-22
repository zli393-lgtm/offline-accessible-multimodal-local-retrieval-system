import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../application/ui_preferences.dart';

class AppLocalizations {
  final AppLanguage language;

  const AppLocalizations(this.language);

  bool get isEnglish => language == AppLanguage.english;

  String text(String chinese, String english) => isEnglish ? english : chinese;

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations)!;
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'zh' || locale.languageCode == 'en';

  @override
  Future<AppLocalizations> load(Locale locale) => SynchronousFuture(
    AppLocalizations(
      locale.languageCode == 'en'
          ? AppLanguage.english
          : AppLanguage.simplifiedChinese,
    ),
  );

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}

extension AppLocalizationContext on BuildContext {
  AppLocalizations get strings => AppLocalizations.of(this);
  String tr(String chinese, String english) => strings.text(chinese, english);
}
