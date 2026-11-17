import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl_standalone.dart' if (dart.library.html) 'package:intl/intl_browser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'translations.dart';

class EasyLocalizationController extends ChangeNotifier {
  static Locale? _savedLocale;
  static late Locale _deviceLocale;

  late Locale _locale;
  Locale? _fallbackLocale;
  List<Locale>? _supportedLocales;

  final Function(FlutterError e) onLoadError;
  final AssetLoader assetLoader;
  final String path;
  final bool useFallbackTranslations;
  final bool saveLocale;
  final bool useOnlyLangCode;
  List<AssetLoader>? extraAssetLoaders;
  Translations? _translations, _fallbackTranslations;
  Translations? get translations => _translations;
  Translations? get fallbackTranslations => _fallbackTranslations;
  Locale? _translationsLocale;
  Completer<void>? _pendingLocaleChange;
  int _loadGeneration = 0;
  bool _disposed = false;

  EasyLocalizationController({
    required List<Locale> supportedLocales,
    required this.useFallbackTranslations,
    required this.saveLocale,
    required this.assetLoader,
    required this.path,
    required this.useOnlyLangCode,
    required this.onLoadError,
    this.extraAssetLoaders,
    Locale? startLocale,
    Locale? fallbackLocale,
    Locale? forceLocale, // used for testing
  }) {
    _fallbackLocale = fallbackLocale;
    _supportedLocales = supportedLocales;
    if (forceLocale != null) {
      _locale = forceLocale;
    } else if (_savedLocale == null && startLocale != null) {
      _locale = _getFallbackLocale(supportedLocales, startLocale);
      EasyLocalization.logger('Start locale loaded ${_locale.toString()}');
    }
    // If saved locale then get
    else if (saveLocale && _savedLocale != null) {
      EasyLocalization.logger('Saved locale loaded ${_savedLocale.toString()}');
      _locale = selectLocaleFrom(
        supportedLocales,
        _savedLocale!,
        fallbackLocale: fallbackLocale,
      );
    } else {
      // From Device Locale
      _locale = selectLocaleFrom(
        supportedLocales,
        _deviceLocale,
        fallbackLocale: fallbackLocale,
      );
    }
  }

  @visibleForTesting
  static Locale selectLocaleFrom(
    List<Locale> supportedLocales,
    Locale deviceLocale, {
    Locale? fallbackLocale,
  }) {
    final selectedLocale = supportedLocales.firstWhere(
      (locale) => locale.supports(deviceLocale),
      orElse: () => _getFallbackLocale(
        supportedLocales,
        fallbackLocale,
        deviceLocale: deviceLocale,
      ),
    );
    return selectedLocale;
  }

  //Get fallback Locale
  static Locale _getFallbackLocale(
    List<Locale> supportedLocales,
    Locale? fallbackLocale, {
    final Locale? deviceLocale,
  }) {
    if (deviceLocale != null) {
      // a locale that matches the language code of the device locale is
      // preferred over the fallback locale
      final deviceLanguage = deviceLocale.languageCode;
      for (Locale locale in supportedLocales) {
        if (locale.languageCode == deviceLanguage) {
          return locale;
        }
      }
    }
    //If fallbackLocale not set then return first from supportedLocales
    if (fallbackLocale != null) {
      return fallbackLocale;
    } else {
      return supportedLocales.first;
    }
  }

  Future<void> loadTranslations() async {
    await _loadTranslations();
  }

  /// Reload the current language without changing its selection or saved locale.
  /// Keep a working translation map if a background reload fails.
  Future<void> reloadTranslations() async {
    // A refresh must not replace an in-flight language selection with old data.
    while (_pendingLocaleChange != null) {
      await _pendingLocaleChange!.future;
    }
    final generation = _loadGeneration + 1;
    final loaded = await _loadTranslations(
      preserveLoadedTranslations: _translations != null && _translationsLocale == _locale,
    );
    if (loaded && !_disposed && generation == _loadGeneration) {
      notifyListeners();
    }
  }

  Future<bool> _loadTranslations({bool preserveLoadedTranslations = false}) async {
    if (_disposed) return false;
    final generation = ++_loadGeneration;
    final loadingLocale = _locale;
    Map<String, dynamic> data;
    try {
      data = Map.from(await loadTranslationData(loadingLocale));
      final translations = Translations(data);
      Translations? fallbackTranslations;
      if (useFallbackTranslations && _fallbackLocale != null) {
        Map<String, dynamic>? baseLangData;
        if (loadingLocale.countryCode != null && loadingLocale.countryCode!.isNotEmpty) {
          baseLangData = await loadBaseLangTranslationData(
            Locale(loadingLocale.languageCode),
          );
        }
        data = Map.from(await loadTranslationData(_fallbackLocale!));
        if (baseLangData != null) {
          try {
            data.addAll(baseLangData);
          } on UnsupportedError {
            data = Map.of(data)..addAll(baseLangData);
          }
        }
        fallbackTranslations = Translations(data);
      }
      // Only the newest active load may publish, including its fallback map.
      if (_disposed || generation != _loadGeneration) return false;
      _translations = translations;
      _fallbackTranslations = fallbackTranslations;
      _translationsLocale = loadingLocale;
      return true;
    } catch (e, stackTrace) {
      if (!_disposed && generation == _loadGeneration) {
        final error = e is FlutterError ? e : FlutterError(e.toString());
        if (preserveLoadedTranslations) {
          EasyLocalization.logger.error(error, stackTrace: stackTrace);
        } else {
          onLoadError(error);
        }
      }
    }
    return false;
  }

  Future<Map<String, dynamic>?> loadBaseLangTranslationData(
    Locale locale,
  ) async {
    try {
      return await loadTranslationData(Locale(locale.languageCode));
    } on FlutterError catch (e) {
      // Disregard asset not found FlutterError when attempting to load base language fallback
      EasyLocalization.logger.warning(e.message);
    }
    return null;
  }

  Future<Map<String, dynamic>> loadTranslationData(Locale locale) async =>
      _combineAssetLoaders(
        path: path,
        locale: locale,
        assetLoader: assetLoader,
        useOnlyLangCode: useOnlyLangCode,
        extraAssetLoaders: extraAssetLoaders,
      );

  Future<Map<String, dynamic>> _combineAssetLoaders({
    required String path,
    required Locale locale,
    required AssetLoader assetLoader,
    required bool useOnlyLangCode,
    List<AssetLoader>? extraAssetLoaders,
  }) async {
    final result = <String, dynamic>{};
    final loaderFutures = <Future<Map<String, dynamic>?>>[];

    // need scriptCode, it might be better to use ignoreCountryCode as the variable name of useOnlyLangCode
    final Locale desiredLocale = useOnlyLangCode
        ? Locale.fromSubtags(
            languageCode: locale.languageCode,
            scriptCode: locale.scriptCode,
          )
        : locale;

    List<AssetLoader> loaders = [
      assetLoader,
      if (extraAssetLoaders != null) ...extraAssetLoaders,
    ];

    for (final loader in loaders) {
      loaderFutures.add(loader.load(path, desiredLocale));
    }

    await Future.wait(loaderFutures).then((List<Map<String, dynamic>?> value) {
      for (final Map<String, dynamic>? map in value) {
        if (map != null) {
          result.addAllRecursive(map);
        }
      }
    });

    return result;
  }

  Locale get locale => _locale;

  Future<void> setLocale(Locale l) async {
    if (_disposed) return;
    final pending = Completer<void>();
    _pendingLocaleChange = pending;
    try {
      _locale = l;
      final generation = _loadGeneration + 1;
      final loaded = await _loadTranslations();
      if (_disposed || _locale != l) return;
      if (loaded && generation == _loadGeneration) notifyListeners();
      EasyLocalization.logger('Locale $locale changed');
      await _saveLocale(l);
    } finally {
      pending.complete();
      if (identical(_pendingLocaleChange, pending)) _pendingLocaleChange = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    super.dispose();
  }

  Future<void> _saveLocale(Locale? locale) async {
    if (!saveLocale) return;
    final preferences = await SharedPreferences.getInstance();
    if (_disposed || locale != _locale) return;
    await preferences.setString('locale', locale.toString());
    EasyLocalization.logger('Locale $locale saved');
  }

  static Future<void> initEasyLocation() async {
    final preferences = await SharedPreferences.getInstance();
    final strLocale = preferences.getString('locale');
    _savedLocale = strLocale?.toLocale();
    final foundPlatformLocale = await findSystemLocale();
    _deviceLocale = foundPlatformLocale.toLocale();
    EasyLocalization.logger.debug('Localization initialized');
  }

  Future<void> deleteSaveLocale() async {
    _savedLocale = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove('locale');
    EasyLocalization.logger('Saved locale deleted');
  }

  Locale get deviceLocale => _deviceLocale;
  Locale? get savedLocale => _savedLocale;

  Future<void> resetLocale() async {
    final locale = selectLocaleFrom(
      _supportedLocales!,
      deviceLocale,
      fallbackLocale: _fallbackLocale,
    );

    EasyLocalization.logger(
      'Reset locale to $locale while the platform locale is $_deviceLocale and the fallback locale is $_fallbackLocale',
    );
    await setLocale(locale);
  }
}

@visibleForTesting
extension LocaleExtension on Locale {
  bool supports(Locale locale) {
    if (this == locale) {
      return true;
    }
    if (languageCode != locale.languageCode) {
      return false;
    }
    if (countryCode != null &&
        countryCode!.isNotEmpty &&
        countryCode != locale.countryCode) {
      return false;
    }
    if (scriptCode != null && scriptCode != locale.scriptCode) {
      return false;
    }

    return true;
  }
}
