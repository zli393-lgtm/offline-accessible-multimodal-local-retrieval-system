/// Application-wide theme and accessibility inputs.
/// These values intentionally affect the whole application.
abstract final class ThemeValues {
  static const String fontFamily = 'NotoSansSC';
  static const double baseTextScale = 1;
  static const int blueSeed = 0xff315c9b;
  static const int greenSeed = 0xff287552;
  static const int pinkSeed = 0xffa44670;
  static const int yellowSeed = 0xff8a6a00;
  static const int orangeSeed = 0xffa24a16;
  static const int lightPurpleSeed = 0xff7357a6;
  static const int grayscaleSeed = 0xff55575b;
  // Okabe-Ito based color-vision-safe pairs. Contrast changes adjust tone,
  // never replace these hues.
  static const int protanopiaSeed = 0xff56b4e9;
  static const int protanopiaSecondary = 0xfff0e442;
  static const int deuteranopiaSeed = 0xff0072b2;
  static const int deuteranopiaSecondary = 0xffe69f00;
  static const int tritanopiaSeed = 0xffd55e00;
  static const int tritanopiaSecondary = 0xff009e73;
  static const int standardBackground = 0xfff7f8fc;
  static const int grayscaleBackground = 0xfff5f5f5;
  static const int grayscalePrimary = 0xff111111;
  static const int grayscalePrimarySoft = 0xff3f4145;
  static const int grayscaleContainer = 0xffe5e5e5;
  static const int grayscaleContainerHigh = 0xffd2d2d2;
  static const int grayscaleHighContrastContainer = 0xff000000;
  static const int grayscaleHighContrastBackground = 0xffffffff;
  static const int grayscaleOutline = 0xff111111;
  static const int grayscaleOutlineSoft = 0xff707070;
  static const int grayscaleSurfaceLow = 0xfffafafa;
  static const int grayscaleSurface = 0xfff0f0f0;
  static const int grayscaleSurfaceHigh = 0xffe8e8e8;
  static const int grayscaleSurfaceHighest = 0xffdddddd;
  static const int grayscaleOutlineVariant = 0xffaaaaaa;
  static const double standardBackgroundTintOpacity = 0.08;
}
