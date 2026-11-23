import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import 'collection_controller.dart';
import 'appearance.dart';
import 'card_glow.dart';
import 'collection_store.dart';
import 'collection_ui.dart';
import 'link_services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Sea Salt Serif / Noto Serif SC',
    ], await rootBundle.loadString('assets/fonts/OFL-NotoSerifSC.txt'));
  });
  runApp(const CollectionApp());
}

class CollectionApp extends StatefulWidget {
  const CollectionApp({super.key, this.controller});

  final CollectionController? controller;

  @override
  State<CollectionApp> createState() => _CollectionAppState();
}

class _CollectionAppState extends State<CollectionApp> {
  final appearance = AppearanceController();

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) unawaited(appearance.initialize());
  }

  @override
  void dispose() {
    appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: appearance,
    builder: (context, _) => MaterialApp(
      title: '大肥鱼的收藏箱',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: appearance.value.mode,
      builder: (context, child) {
        final data = MediaQuery.of(context);
        final value = appearance.value;
        final dark =
            value.mode == ThemeMode.dark ||
            (value.mode == ThemeMode.system &&
                data.platformBrightness == Brightness.dark);
        return AppearanceScope(
          controller: appearance,
          child: MediaQuery(
            data: data.copyWith(
              textScaler: AppTextScaler(data.textScaler, value.fontScale),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (value.backgroundPath != null) ...[
                  ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: value.blur,
                      sigmaY: value.blur,
                    ),
                    child: Image.file(
                      File(value.backgroundPath!),
                      fit: BoxFit.cover,
                      cacheWidth: 2048,
                      errorBuilder: (context, error, stack) =>
                          const SizedBox.expand(),
                    ),
                  ),
                  ColoredBox(
                    color: (dark ? Colors.black : Colors.white).withValues(
                      alpha: value.overlay,
                    ),
                  ),
                ],
                if (child != null) CardGlowScope(child: child),
              ],
            ),
          ),
        );
      },
      home: widget.controller == null
          ? const _Startup()
          : CollectionPage(controller: widget.controller!),
    ),
  );

  ThemeData _theme(Brightness brightness) {
    final ocean = appearance.value.colorIndex == 0;
    final light = brightness == Brightness.light;
    final base = ColorScheme.fromSeed(
      seedColor: appearanceColors[appearance.value.colorIndex],
      brightness: brightness,
    );
    final scheme = !ocean
        ? base
        : light
        ? base.copyWith(
            primary: const Color(0xFF175B87),
            onPrimary: Colors.white,
            primaryContainer: const Color(0xFFD5EBFC),
            onPrimaryContainer: const Color(0xFF113D5D),
            secondaryContainer: const Color(0xFFDFEFF3),
            onSecondaryContainer: const Color(0xFF193F4A),
            surface: const Color(0xFFF1F6FA),
            surfaceContainerLowest: const Color(0xFFFCFEFF),
            surfaceContainer: const Color(0xFFE9F1F7),
            surfaceContainerHigh: const Color(0xFFE2EDF5),
            onSurface: const Color(0xFF162E44),
            onSurfaceVariant: const Color(0xFF475F73),
            outlineVariant: const Color(0xFFCDDFEB),
          )
        : base.copyWith(
            primaryContainer: const Color(0xFF173A54),
            secondaryContainer: const Color(0xFF203D49),
            surface: const Color(0xFF101D2B),
            surfaceContainerLowest: const Color(0xFF172638),
            surfaceContainer: const Color(0xFF203247),
            surfaceContainerHigh: const Color(0xFF283C50),
            outlineVariant: const Color(0xFF3A536A),
          );
    return ThemeData(
      colorScheme: scheme,
      textTheme: const TextTheme(
        headlineMedium: _serifHeading,
        headlineSmall: _serifHeading,
        titleLarge: _serifHeading,
      ),
      scaffoldBackgroundColor: appearance.value.backgroundPath != null
          ? Colors.transparent
          : scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        foregroundColor: scheme.onSurface,
        systemOverlayStyle: brightness == Brightness.light
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(18)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surfaceContainerLowest,
        selectedColor: scheme.primaryContainer,
        showCheckmark: false,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
      ),
    );
  }

  static const _serifHeading = TextStyle(
    fontFamily: 'SeaSaltSerif',
    fontWeight: FontWeight.w600,
    letterSpacing: .18,
  );
}

class _Startup extends StatefulWidget {
  const _Startup();

  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup> {
  final _client = http.Client();
  CollectionController? _controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final path = await getDatabasesPath();
      final db = await databaseFactory.openDatabase(
        '$path/collection.db',
        options: CollectionStore.options,
      );
      if (!mounted) {
        await db.close();
        return;
      }
      final controller = CollectionController(
        CollectionStore(db),
        const SettingsStore(FlutterSecureStorage()),
        LinkServices(_client),
      );
      setState(() => _controller = controller);
      unawaited(controller.initialize());
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) {
      return CollectionPage(controller: controller, acceptShares: true);
    }
    return Scaffold(
      body: Center(
        child: _failed
            ? FilledButton.tonal(
                onPressed: () {
                  setState(() => _failed = false);
                  unawaited(_open());
                },
                child: const Text('无法打开收藏库，点击重试'),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
