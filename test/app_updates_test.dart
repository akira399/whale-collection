import 'dart:convert';
import 'dart:io';

import 'package:ai_tool_collection/app_updates.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _project = 'https://github.com/akira399/whale-collection';

Map<String, Object> _release(String version) => {
  'tag_name': 'v$version',
  'draft': false,
  'prerelease': false,
  'body': '新的更新功能',
  'assets': [
    for (final abi in ['arm64-v8a', 'x86_64'])
      {
        'name': 'Whale-Collection-$version-android-$abi.apk',
        'state': 'uploaded',
        'size': 4,
        'browser_download_url':
            '$_project/releases/download/v$version/Whale-Collection-$version-android-$abi.apk',
      },
  ],
};

void main() {
  test('compares numeric versions and selects APK in device ABI order', () {
    final payload = _release('1.0.10');
    final release = AppRelease.parse(payload, '1.0.9', [
      'x86_64',
      'arm64-v8a',
    ])!;
    expect(release.version, '1.0.10');
    expect(release.asset.pathSegments.last, endsWith('x86_64.apk'));
    expect(AppRelease.parse(payload, '1.0.10', ['x86_64']), isNull);
    expect(AppRelease.parse(payload, '1.1.0', ['x86_64']), isNull);
    expect(
      () => AppRelease.parse(payload, '1.0.9', ['x86']),
      throwsA(isA<UpdateFailure>()),
    );
  });

  test(
    'requires a stable release and assets belonging to the app repository',
    () {
      final payload = _release('1.1.0');
      expect(
        () => AppRelease.parse(
          {...payload, 'prerelease': true},
          '1.0.0',
          ['arm64-v8a'],
        ),
        throwsFormatException,
      );
      final asset = (payload['assets'] as List<Map<String, Object>>).first;
      asset['browser_download_url'] = 'https://other.example/${asset['name']}';
      expect(
        () => AppRelease.parse(payload, '1.0.0', ['arm64-v8a']),
        throwsA(isA<UpdateFailure>()),
      );
    },
  );

  test('unavailable official API falls back to accelerated metadata', () async {
    final hosts = <String>[];
    final client = ReleaseClient(
      MockClient((request) async {
        hosts.add(request.url.host);
        return request.url.host == 'api.github.com'
            ? http.Response('', 503)
            : http.Response.bytes(
                utf8.encode(jsonEncode(_release('1.0.1'))),
                200,
              );
      }),
    );
    final release = await client.latest('1.0.0', ['arm64-v8a']);
    expect(release?.version, '1.0.1');
    expect(hosts, ['api.github.com', 'gh-proxy.com']);
  });

  test(
    'partial mirror download falls back and completed APK is verified',
    () async {
      final directory = await Directory.systemTemp.createTemp('whale-apk-test');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/whale.apk');
      final hosts = <String>[];
      final client = ReleaseClient(
        MockClient((request) async {
          hosts.add(request.url.host);
          return request.url.host == 'ghfast.top'
              ? http.Response.bytes([1, 2], 200)
              : http.Response.bytes([1, 2, 3, 4], 200);
        }),
      );
      final release = AppRelease.parse(_release('1.0.1'), '1.0.0', [
        'arm64-v8a',
      ])!;
      final progress = <double>[];
      await client.download(
        release,
        file,
        onProgress: progress.add,
        verify: () async => expect(await file.readAsBytes(), [1, 2, 3, 4]),
      );
      expect(hosts, ['ghfast.top', 'gh-proxy.com']);
      expect(progress, [0, .5, 0, 1]);
      expect(File('${file.path}.part').existsSync(), isFalse);
    },
  );

  test('rejects insecure redirects and deletes an unverified file', () async {
    final directory = await Directory.systemTemp.createTemp('whale-apk-test');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/whale.apk');
    final client = ReleaseClient(
      MockClient((request) async {
        expect(request.url.scheme, 'https');
        return request.url.host == 'ghfast.top'
            ? http.Response(
                '',
                302,
                headers: {'location': 'http://example.org/apk'},
              )
            : http.Response.bytes([1, 2, 3, 4], 200);
      }),
    );
    final release = AppRelease.parse(_release('1.0.1'), '1.0.0', [
      'arm64-v8a',
    ])!;
    await expectLater(
      client.download(
        release,
        file,
        onProgress: (_) {},
        verify: () async => throw PlatformException(code: 'invalid_apk'),
      ),
      throwsA(
        isA<UpdateFailure>().having(
          (error) => error.message,
          'message',
          contains('签名'),
        ),
      ),
    );
    expect(file.existsSync(), isFalse);
    expect(File('${file.path}.part').existsSync(), isFalse);
  });
}
