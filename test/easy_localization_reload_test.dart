import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:easy_localization/src/easy_localization_controller.dart';
import 'package:easy_localization/src/localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReloadAssetLoader extends AssetLoader {
  ReloadAssetLoader(this.onLoad)
      : super(
          fileLoader: const RootBundleFileLoader(),
          linkedFileResolver: const JsonLinkedFileResolver(
            fileLoader: RootBundleFileLoader(),
          ),
        );

  Future<Map<String, dynamic>> Function(Locale locale) onLoad;

  @override
  Future<Map<String, dynamic>> load(String path, Locale locale) => onLoad(locale);
}

class EditingPage extends StatefulWidget {
  const EditingPage({required Key key, required this.useContext}) : super(key: key);

  final bool useContext;

  @override
  State<EditingPage> createState() => EditingPageState();
}

class EditingPageState extends State<EditingPage> {
  final field = TextEditingController();

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          Text(widget.useContext ? context.tr('message') : 'message'.tr()),
          TextField(controller: field),
        ]),
      );
}

class InitialTranslationReader extends StatefulWidget {
  const InitialTranslationReader({required this.onInit, Key? key}) : super(key: key);

  final void Function(String) onInit;

  @override
  State<InitialTranslationReader> createState() => InitialTranslationReaderState();
}

class InitialTranslationReaderState extends State<InitialTranslationReader> {
  @override
  void initState() {
    super.initState();
    widget.onInit('message'.tr());
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({'other': true});
    await EasyLocalization.ensureInitialized();
  });

  for (final language in ['en', 'ar']) {
    testWidgets('preloads $language before child initialization', (tester) async {
      Localization.load(Locale(language));
      final pending = Completer<Map<String, dynamic>>();
      final reads = <String>[];
      await tester.pumpWidget(EasyLocalization(
        supportedLocales: const [Locale('en'), Locale('ar')],
        startLocale: Locale(language),
        saveLocale: false,
        preloadTranslations: true,
        path: 'unused',
        assetLoader: ReloadAssetLoader((_) => pending.future),
        child: InitialTranslationReader(onInit: reads.add),
      ));
      await tester.pump();
      expect(reads, isEmpty);
      expect(find.byType(InitialTranslationReader), findsNothing);
      final expected = language == 'en' ? 'Bundled English' : 'النص المحلي';
      pending.complete({'message': expected});
      await tester.pumpAndSettle();
      expect(reads, [expected]);
      expect(find.byType(InitialTranslationReader), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('disposing during preload never mounts the child', (tester) async {
    final pending = Completer<Map<String, dynamic>>();
    final reads = <String>[];
    await tester.pumpWidget(EasyLocalization(
      supportedLocales: const [Locale('en')],
      saveLocale: false,
      preloadTranslations: true,
      path: 'unused',
      assetLoader: ReloadAssetLoader((_) => pending.future),
      child: InitialTranslationReader(onInit: reads.add),
    ));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete({'message': 'late'});
    await tester.pumpAndSettle();
    expect(reads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preload failures use the existing error widget', (tester) async {
    final reads = <String>[];
    await tester.pumpWidget(EasyLocalization(
      supportedLocales: const [Locale('en')],
      saveLocale: false,
      preloadTranslations: true,
      path: 'unused',
      assetLoader: ReloadAssetLoader((_) async => throw StateError('load failed')),
      errorWidget: (_) => const SizedBox(key: Key('load-error')),
      child: InitialTranslationReader(onInit: reads.add),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('load-error')), findsOneWidget);
    expect(reads, isEmpty);
  });

  for (final language in ['en', 'ar']) {
    for (final useContext in [true, false]) {
      for (final fails in [false, true]) {
        testWidgets(
            'reloads $language (context: $useContext, fails: $fails) without resetting the current route',
            (tester) async {
          final navigator = GlobalKey<NavigatorState>();
          final page = GlobalKey<EditingPageState>();
          var text = language == 'en' ? 'Bundled English' : 'النص المحلي';
          final loader = ReloadAssetLoader((_) async => {'message': text});
          await tester.pumpWidget(EasyLocalization(
            supportedLocales: const [Locale('en'), Locale('ar')],
            startLocale: Locale(language),
            saveLocale: false,
            path: 'unused',
            assetLoader: loader,
            child: Builder(
                builder: (context) => MaterialApp(
                      navigatorKey: navigator,
                      locale: context.locale,
                      supportedLocales: context.supportedLocales,
                      localizationsDelegates: context.localizationDelegates,
                      routes: {
                        '/': (_) => const Scaffold(body: Text('Home')),
                        '/editing': (_) => EditingPage(key: page, useContext: useContext),
                      },
                    )),
          ));
          await tester.pumpAndSettle();
          final pushedRoute = navigator.currentState!.pushNamed('/editing');
          await tester.pumpAndSettle();
          final originalState = page.currentState;
          await tester.enterText(find.byType(TextField), 'unsaved input');
          final originalRoute = ModalRoute.of(page.currentContext!);
          if (fails) {
            loader.onLoad = (_) async => throw StateError('refresh failed');
          } else {
            text = language == 'en' ? 'Online English' : 'النص المحدث';
          }

          await page.currentContext!.reloadTranslations();
          await tester.pumpAndSettle();

          expect(find.byType(ErrorWidget), findsNothing);
          expect(find.text(text), findsOneWidget);
          expect('message'.tr(), text);
          expect(page.currentContext!.locale, Locale(language));
          expect(page.currentState, same(originalState));
          expect(ModalRoute.of(page.currentContext!), same(originalRoute));
          expect(page.currentState!.field.text, 'unsaved input');
          expect(navigator.currentState!.canPop(), isTrue);
          final preferences = await SharedPreferences.getInstance();
          expect(preferences.getString('locale'), isNull);
          expect(preferences.getBool('other'), isTrue);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          await pushedRoute;
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }
  }

  EasyLocalizationController controllerFor(ReloadAssetLoader loader,
          {List<FlutterError>? errors, bool saveLocale = false}) =>
      EasyLocalizationController(
        forceLocale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('ar')],
        useFallbackTranslations: false,
        saveLocale: saveLocale,
        assetLoader: loader,
        path: 'unused',
        useOnlyLangCode: true,
        onLoadError: (error) => errors?.add(error),
      );

  test('a stale English refresh cannot replace a newer Arabic load', () async {
    final pendingEnglish = Completer<Map<String, dynamic>>();
    final loader = ReloadAssetLoader((locale) =>
        locale.languageCode == 'en' ? pendingEnglish.future : Future.value({'message': 'العربية'}));
    final controller = controllerFor(loader);
    addTearDown(controller.dispose);
    final refresh = controller.reloadTranslations();
    await controller.setLocale(const Locale('ar'));
    pendingEnglish.complete({'message': 'stale English'});
    await refresh;
    expect(controller.locale, const Locale('ar'));
    expect(controller.translations!.get('message'), 'العربية');
  });

  test('a refresh waits for a pending locale selection and preserves its saved locale', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('locale', 'en');
    final selecting = Completer<Map<String, dynamic>>();
    final refreshing = Completer<Map<String, dynamic>>();
    var calls = 0;
    final loader = ReloadAssetLoader((_) => calls++ == 0 ? selecting.future : refreshing.future);
    final controller = controllerFor(loader, saveLocale: true);
    addTearDown(controller.dispose);
    final selection = controller.setLocale(const Locale('ar'));
    final refresh = controller.reloadTranslations();
    expect(calls, 1);
    selecting.complete({'message': 'العربية القديمة'});
    await selection;
    refreshing.complete({'message': 'العربية المحدثة'});
    await refresh;
    expect(controller.translations!.get('message'), 'العربية المحدثة');
    expect(preferences.getString('locale'), 'ar');
  });

  test('a stale English selection cannot overwrite saved Arabic', () async {
    final english = Completer<Map<String, dynamic>>();
    final loader = ReloadAssetLoader(
        (locale) => locale.languageCode == 'en' ? english.future : Future.value({'message': 'العربية'}));
    final controller = controllerFor(loader, saveLocale: true);
    addTearDown(controller.dispose);
    final older = controller.setLocale(const Locale('en'));
    await controller.setLocale(const Locale('ar'));
    english.complete({'message': 'stale English'});
    await older;
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('locale'), 'ar');
  });

  test('a failed refresh cannot discard a pending Arabic selection over loaded English', () async {
    final arabic = Completer<Map<String, dynamic>>();
    var arabicLoads = 0;
    final errors = <FlutterError>[];
    final loader = ReloadAssetLoader((locale) {
      if (locale.languageCode == 'en') return Future.value({'message': 'English'});
      if (arabicLoads++ == 0) return arabic.future;
      return Future.error(StateError('refresh failed'));
    });
    final controller = controllerFor(loader, saveLocale: true, errors: errors);
    addTearDown(controller.dispose);
    await controller.loadTranslations();
    final selection = controller.setLocale(const Locale('ar'));
    final refresh = controller.reloadTranslations();
    arabic.complete({'message': 'العربية'});
    await selection;
    await refresh;
    expect(controller.locale, const Locale('ar'));
    expect(controller.translations!.get('message'), 'العربية');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('locale'), 'ar');
    expect(errors, isEmpty);
  });

  testWidgets('a pending language change followed by failed refresh keeps Arabic UI and input',
      (tester) async {
    final arabic = Completer<Map<String, dynamic>>();
    var arabicLoads = 0;
    final loader = ReloadAssetLoader((locale) {
      if (locale.languageCode == 'en') return Future.value({'message': 'English'});
      if (arabicLoads++ == 0) return arabic.future;
      return Future.error(StateError('refresh failed'));
    });
    final page = GlobalKey<EditingPageState>();
    await tester.pumpWidget(EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ar')],
      startLocale: const Locale('en'),
      path: 'unused',
      assetLoader: loader,
      child: Builder(
          builder: (context) => MaterialApp(
                locale: context.locale,
                supportedLocales: context.supportedLocales,
                localizationsDelegates: context.localizationDelegates,
                home: EditingPage(key: page, useContext: true),
              )),
    ));
    await tester.pumpAndSettle();
    final originalState = page.currentState;
    final originalRoute = ModalRoute.of(page.currentContext!);
    await tester.enterText(find.byType(TextField), 'unsaved input');
    final selection = page.currentContext!.setLocale(const Locale('ar'));
    final refresh = page.currentContext!.reloadTranslations();
    arabic.complete({'message': 'العربية'});
    await selection;
    await refresh;
    await tester.pumpAndSettle();
    expect(find.text('العربية'), findsOneWidget);
    expect(find.text('English'), findsNothing);
    expect(page.currentContext!.locale, const Locale('ar'));
    expect(page.currentState, same(originalState));
    expect(ModalRoute.of(page.currentContext!), same(originalRoute));
    expect(page.currentState!.field.text, 'unsaved input');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('locale'), 'ar');
    expect(find.byType(ErrorWidget), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('an older same-locale refresh cannot replace a newer refresh', () async {
    final older = Completer<Map<String, dynamic>>();
    final newer = Completer<Map<String, dynamic>>();
    var calls = 0;
    final loader = ReloadAssetLoader((_) => calls++ == 0 ? older.future : newer.future);
    final controller = controllerFor(loader);
    addTearDown(controller.dispose);
    final first = controller.reloadTranslations();
    final second = controller.reloadTranslations();
    newer.complete({'message': 'newer'});
    await second;
    older.complete({'message': 'older'});
    await first;
    expect(controller.translations!.get('message'), 'newer');
  });

  test('a pending refresh does not publish after disposal', () async {
    final pending = Completer<Map<String, dynamic>>();
    final errors = <FlutterError>[];
    final controller = controllerFor(ReloadAssetLoader((_) => pending.future), errors: errors);
    final refresh = controller.reloadTranslations();
    controller.dispose();
    pending.complete({'message': 'late'});
    await refresh;
    expect(controller.translations, isNull);
    expect(errors, isEmpty);
  });

  test('a failed refresh logs the error and retains loaded translations', () async {
    final errors = <FlutterError>[];
    final logged = <Object>[];
    final printer = EasyLocalization.logger.printer;
    EasyLocalization.logger.printer = (object, {name, stackTrace, level}) => logged.add(object);
    addTearDown(() => EasyLocalization.logger.printer = printer);
    final loader = ReloadAssetLoader((_) async => {'message': 'loaded'});
    final controller = controllerFor(loader, errors: errors);
    addTearDown(controller.dispose);
    await controller.loadTranslations();
    var notifications = 0;
    controller.addListener(() => notifications++);
    loader.onLoad = (_) async => throw StateError('failed refresh');
    await controller.reloadTranslations();
    expect(errors, isEmpty);
    expect(logged.single.toString(), contains('failed refresh'));
    expect(controller.translations!.get('message'), 'loaded');
    expect(notifications, 0);
  });

  test('a stale failed English load does not report an error over Arabic', () async {
    final pendingEnglish = Completer<Map<String, dynamic>>();
    final errors = <FlutterError>[];
    final controller = controllerFor(
      ReloadAssetLoader((locale) =>
          locale.languageCode == 'en' ? pendingEnglish.future : Future.value({'message': 'العربية'})),
      errors: errors,
    );
    addTearDown(controller.dispose);
    final refresh = controller.reloadTranslations();
    await controller.setLocale(const Locale('ar'));
    pendingEnglish.completeError(StateError('stale request'));
    await refresh;
    expect(errors, isEmpty);
    expect(controller.translations!.get('message'), 'العربية');
  });
}
