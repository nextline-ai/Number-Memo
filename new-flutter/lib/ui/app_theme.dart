import 'package:flutter/material.dart';

/// Explicit neutral roles keep Material states, including errors, monochrome.
/// Using a black seed alone still introduces tinted secondary and error roles.
ThemeData buildMonochromeTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: dark ? const Color(0xfff5f5f5) : const Color(0xff181818),
    onPrimary: dark ? const Color(0xff181818) : Colors.white,
    primaryContainer: dark ? const Color(0xff3a3a3a) : const Color(0xffe5e5e5),
    onPrimaryContainer: dark ? Colors.white : const Color(0xff181818),
    primaryFixed: const Color(0xffe5e5e5),
    primaryFixedDim: const Color(0xffcccccc),
    onPrimaryFixed: const Color(0xff181818),
    onPrimaryFixedVariant: const Color(0xff3a3a3a),
    secondary: dark ? const Color(0xffcccccc) : const Color(0xff4a4a4a),
    onSecondary: dark ? const Color(0xff242424) : Colors.white,
    secondaryContainer: dark
        ? const Color(0xff303030)
        : const Color(0xffe9e9e9),
    onSecondaryContainer: dark
        ? const Color(0xfff5f5f5)
        : const Color(0xff181818),
    secondaryFixed: const Color(0xffe5e5e5),
    secondaryFixedDim: const Color(0xffcccccc),
    onSecondaryFixed: const Color(0xff181818),
    onSecondaryFixedVariant: const Color(0xff3a3a3a),
    tertiary: dark ? const Color(0xffbbbbbb) : const Color(0xff555555),
    onTertiary: dark ? const Color(0xff242424) : Colors.white,
    tertiaryContainer: dark ? const Color(0xff393939) : const Color(0xffdddddd),
    onTertiaryContainer: dark
        ? const Color(0xffeeeeee)
        : const Color(0xff202020),
    tertiaryFixed: const Color(0xffe5e5e5),
    tertiaryFixedDim: const Color(0xffcccccc),
    onTertiaryFixed: const Color(0xff181818),
    onTertiaryFixedVariant: const Color(0xff3a3a3a),
    error: dark ? Colors.white : const Color(0xff181818),
    onError: dark ? const Color(0xff181818) : Colors.white,
    errorContainer: dark ? const Color(0xff424242) : const Color(0xffdedede),
    onErrorContainer: dark ? Colors.white : const Color(0xff181818),
    surface: dark ? const Color(0xff121212) : Colors.white,
    onSurface: dark ? const Color(0xffeeeeee) : const Color(0xff181818),
    onSurfaceVariant: dark ? const Color(0xffbdbdbd) : const Color(0xff555555),
    surfaceDim: dark ? const Color(0xff121212) : const Color(0xffdedede),
    surfaceBright: dark ? const Color(0xff393939) : Colors.white,
    surfaceContainerLowest: dark ? const Color(0xff0a0a0a) : Colors.white,
    surfaceContainerLow: dark
        ? const Color(0xff1b1b1b)
        : const Color(0xfff7f7f7),
    surfaceContainer: dark ? const Color(0xff202020) : const Color(0xfff2f2f2),
    surfaceContainerHigh: dark
        ? const Color(0xff292929)
        : const Color(0xffebebeb),
    surfaceContainerHighest: dark
        ? const Color(0xff333333)
        : const Color(0xffe3e3e3),
    outline: dark ? const Color(0xff8f8f8f) : const Color(0xff777777),
    outlineVariant: dark ? const Color(0xff454545) : const Color(0xffc7c7c7),
    inverseSurface: dark ? const Color(0xffeeeeee) : const Color(0xff2e2e2e),
    onInverseSurface: dark ? const Color(0xff242424) : const Color(0xfff5f5f5),
    inversePrimary: dark ? const Color(0xff242424) : const Color(0xffeeeeee),
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: const AppBarTheme(centerTitle: false, elevation: 0),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .45),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    visualDensity: VisualDensity.standard,
  );
}
