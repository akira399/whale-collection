import 'dart:convert';

import 'package:ai_tool_collection/appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('appearance survives serialization and retains system text scaling', () {
    const value = Appearance(
      fontScale: 1.3,
      colorIndex: 2,
      mode: ThemeMode.dark,
      backgroundPath: '/private/image',
      blur: 12,
      overlay: .7,
    );
    final restored = Appearance.fromJson(
      jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>,
    );
    expect(restored.fontScale, 1.3);
    expect(restored.colorIndex, 2);
    expect(restored.mode, ThemeMode.dark);
    expect(restored.backgroundPath, '/private/image');
    expect(restored.blur, 12);
    expect(restored.overlay, .7);
    expect(const AppTextScaler(TextScaler.linear(1.5), 1.3).scale(20), 39);
    expect(restored.copyWith(clearBackground: true).backgroundPath, isNull);
  });
}
