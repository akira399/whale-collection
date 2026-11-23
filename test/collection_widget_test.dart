import 'package:ai_tool_collection/collection_controller.dart';
import 'package:ai_tool_collection/collection_store.dart';
import 'package:ai_tool_collection/link_services.dart';
import 'package:ai_tool_collection/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'The form should validate before accessing the database.',
  );
}

void main() {
  testWidgets(
    'small screen and large text can open the link form and show validation',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 680);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = CollectionController(
        CollectionStore(_UnusedDatabase()),
        const SettingsStore(FlutterSecureStorage()),
        LinkServices(
          MockClient(
            (_) async => throw StateError('unexpected network request'),
          ),
        ),
      )..loading = false;
      addTearDown(controller.dispose);

      await tester.pumpWidget(CollectionApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('我的收藏'), findsOneWidget);
      await tester.tap(find.text('添加链接'));
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, '链接');
      await tester.enterText(field, 'not-a-url');
      tester.view.viewInsets = const FakeViewPadding(bottom: 220);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('收藏并整理'));
      expect(tester.getBottomRight(find.text('收藏并整理')).dy, lessThan(460));
      await tester.tap(find.text('收藏并整理'));
      await tester.pumpAndSettle();
      expect(find.text('请输入一个完整的 HTTP 或 HTTPS 链接。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
