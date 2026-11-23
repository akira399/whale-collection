import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const appearanceColors = <Color>[
  Color(0xFF426BA4),
  Color(0xFF427C70),
  Color(0xFF765C98),
  Color(0xFFB46B67),
  Color(0xFF8B7244),
];
const appearanceColorNames = ['淡蓝', '薄荷绿', '薰衣草', '珊瑚粉', '暖金'];

class Appearance {
  const Appearance({
    this.fontScale = 1.15,
    this.colorIndex = 0,
    this.mode = ThemeMode.system,
    this.backgroundPath,
    this.blur = 5,
    this.overlay = .65,
  });

  final double fontScale;
  final int colorIndex;
  final ThemeMode mode;
  final String? backgroundPath;
  final double blur;
  final double overlay;

  Appearance copyWith({
    double? fontScale,
    int? colorIndex,
    ThemeMode? mode,
    String? backgroundPath,
    bool clearBackground = false,
    double? blur,
    double? overlay,
  }) => Appearance(
    fontScale: fontScale ?? this.fontScale,
    colorIndex: colorIndex ?? this.colorIndex,
    mode: mode ?? this.mode,
    backgroundPath: clearBackground
        ? null
        : backgroundPath ?? this.backgroundPath,
    blur: blur ?? this.blur,
    overlay: overlay ?? this.overlay,
  );

  Map<String, Object?> toJson() => {
    'fontScale': fontScale,
    'colorIndex': colorIndex,
    'mode': mode.name,
    'backgroundPath': backgroundPath,
    'blur': blur,
    'overlay': overlay,
  };

  factory Appearance.fromJson(Map<String, dynamic> json) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    final index = json['colorIndex'];
    final mode = json['mode'];
    return Appearance(
      fontScale: number('fontScale', 1.15, 1, 1.4),
      colorIndex: index is int && index >= 0 && index < appearanceColors.length
          ? index
          : 0,
      mode:
          ThemeMode.values.where((value) => value.name == mode).firstOrNull ??
          ThemeMode.system,
      backgroundPath: json['backgroundPath'] is String
          ? json['backgroundPath'] as String
          : null,
      blur: number('blur', 5, 0, 20),
      overlay: number('overlay', .65, .35, .9),
    );
  }
}

class AppearanceController extends ChangeNotifier {
  AppearanceController({SharedPreferencesAsync? preferences})
    : _providedPreferences = preferences;

  final SharedPreferencesAsync? _providedPreferences;
  late final SharedPreferencesAsync _preferences =
      _providedPreferences ?? SharedPreferencesAsync();
  final ImagePicker _picker = ImagePicker();
  Appearance value = const Appearance();
  Future<void> _writes = Future.value();
  bool _disposed = false;

  Future<void> initialize() async {
    try {
      final raw = await _preferences.getString('appearance');
      if (raw != null) {
        value = Appearance.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
      if (value.backgroundPath != null &&
          !await File(value.backgroundPath!).exists()) {
        value = value.copyWith(clearBackground: true);
      }
      _notify();
      final lost = await _picker.retrieveLostData();
      if (lost.files?.isNotEmpty == true) await setImage(lost.files!.first);
    } on Exception {
      _notify();
    }
  }

  void preview(Appearance next) {
    value = next;
    _notify();
  }

  Future<void> save(Appearance next) {
    value = next;
    _notify();
    final data = jsonEncode(next.toJson());
    final operation = _writes
        .catchError((Object _) {})
        .then((_) => _preferences.setString('appearance', data));
    _writes = operation;
    return operation;
  }

  Future<void> chooseImage() async {
    final image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) await setImage(image);
  }

  Future<void> setImage(XFile image) async {
    if (await image.length() > 15 * 1024 * 1024) {
      throw const FormatException('图片不能超过 15 MB。');
    }
    final bytes = await image.readAsBytes();
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 2048,
      allowUpscaling: false,
    );
    codec.dispose();
    final directory = await getApplicationSupportDirectory();
    final target = File(
      '${directory.path}/background_${DateTime.now().microsecondsSinceEpoch}',
    );
    await target.writeAsBytes(bytes, flush: true);
    final oldValue = value;
    final previous = oldValue.backgroundPath;
    try {
      await save(value.copyWith(backgroundPath: target.path));
    } on Exception {
      value = oldValue;
      _notify();
      await target.delete();
      rethrow;
    }
    if (previous != null && previous != target.path) {
      try {
        await File(previous).delete();
      } on FileSystemException {
        /* Already removed. */
      }
    }
  }

  Future<void> removeImage() async {
    final oldValue = value;
    final previous = oldValue.backgroundPath;
    try {
      await save(oldValue.copyWith(clearBackground: true));
    } on Exception {
      value = oldValue;
      _notify();
      rethrow;
    }
    if (previous != null) {
      try {
        await File(previous).delete();
      } on FileSystemException {
        /* Already removed. */
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()!.notifier!;
}

class AppTextScaler extends TextScaler {
  const AppTextScaler(this.system, this.factor);
  final TextScaler system;
  final double factor;

  @override
  double scale(double fontSize) => system.scale(fontSize) * factor;

  @override
  double get textScaleFactor => system.scale(1) * factor;
}
