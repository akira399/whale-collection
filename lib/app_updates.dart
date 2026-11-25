import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repository = 'akira399/whale-collection';
const _mirrors = ['ghfast.top', 'gh-proxy.com'];
final _versionPattern = RegExp(
  r'^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$',
);

List<int> _versionParts(String value) {
  final match = _versionPattern.firstMatch(value);
  if (match == null) throw const FormatException('无效的版本号');
  return [for (var i = 1; i <= 3; i++) int.parse(match.group(i)!)];
}

class AppRelease {
  const AppRelease(this.version, this.notes, this.asset, this.size);

  final String version;
  final String notes;
  final Uri asset;
  final int size;

  static AppRelease? parse(Object? json, String installed, List<String> abis) {
    if (json is! Map<String, dynamic> ||
        json['draft'] != false ||
        json['prerelease'] != false ||
        json['tag_name'] is! String ||
        json['assets'] is! List) {
      throw const FormatException('无法读取正式版本信息');
    }
    final tag = json['tag_name'] as String;
    if (!tag.startsWith('v')) throw const FormatException('无效的发布标签');
    final version = tag.substring(1);
    final latest = _versionParts(version);
    final current = _versionParts(installed);
    for (var i = 0; i < latest.length; i++) {
      if (latest[i] < current[i]) return null;
      if (latest[i] > current[i]) break;
      if (i == latest.length - 1) return null;
    }
    final assets = json['assets'] as List;
    for (final abi in abis.where(
      const {'arm64-v8a', 'armeabi-v7a', 'x86_64'}.contains,
    )) {
      final name = 'Whale-Collection-$version-android-$abi.apk';
      final asset = Uri.https(
        'github.com',
        '/$_repository/releases/download/$tag/$name',
      );
      for (final value in assets) {
        if (value
            case {
              'name': final String assetName,
              'state': 'uploaded',
              'browser_download_url': final String url,
              'size': final int size,
            }
            when assetName == name &&
                url == asset.toString() &&
                size > 0 &&
                size <= 100 * 1024 * 1024) {
          final body = json['body'];
          final notes = body is String
              ? String.fromCharCodes(body.runes.take(2000))
              : '';
          return AppRelease(version, notes, asset, size);
        }
      }
    }
    throw const UpdateFailure('新版暂未提供适合此设备的安装包。');
  }
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
}

class ReleaseClient {
  ReleaseClient(this._http);

  final http.Client _http;
  static final releasePage = Uri.https(
    'github.com',
    '/$_repository/releases/latest',
  );
  static const _timeout = Duration(seconds: 15);

  Uri _mirror(String host, Uri source) => Uri.parse('https://$host/$source');

  Future<AppRelease?> latest(String installed, List<String> abis) async {
    final url = Uri.https(
      'api.github.com',
      '/repos/$_repository/releases/latest',
    );
    for (final endpoint in [url, _mirror(_mirrors.last, url)]) {
      try {
        final bytes = <int>[];
        await for (final chunk in _stream(
          endpoint,
          'application/vnd.github+json',
        )) {
          if (bytes.length + chunk.length > 256 * 1024) {
            throw const FormatException('版本信息过大');
          }
          bytes.addAll(chunk);
        }
        return AppRelease.parse(
          jsonDecode(utf8.decode(bytes)),
          installed,
          abis,
        );
      } on UpdateFailure {
        rethrow;
      } on Exception {
        // A mirror can still serve metadata when the GitHub API is unreachable.
      }
    }
    throw const UpdateFailure('无法获取版本信息，请检查网络后重试。');
  }

  Future<void> download(
    AppRelease release,
    File target, {
    required Future<void> Function() verify,
    required void Function(double progress) onProgress,
  }) async {
    await target.parent.create(recursive: true);
    final partial = File('${target.path}.part');
    var invalidApk = false;
    for (final host in _mirrors) {
      onProgress(0);
      try {
        var bytes = 0;
        final sink = partial.openWrite();
        try {
          await sink.addStream(
            _stream(
              _mirror(host, release.asset),
              'application/octet-stream',
            ).map((chunk) {
              bytes += chunk.length;
              if (bytes > release.size) throw const FormatException('安装包大小异常');
              onProgress(bytes / release.size);
              return chunk;
            }),
          );
        } finally {
          await sink.close();
        }
        if (bytes != release.size) throw const FormatException('安装包不完整');
        await partial.rename(target.path);
        await verify();
        return;
      } on Exception catch (error) {
        invalidApk |= error is PlatformException && error.code == 'invalid_apk';
        if (await partial.exists()) await partial.delete();
        if (await target.exists()) await target.delete();
      }
    }
    throw UpdateFailure(
      invalidApk ? '安装包的版本或签名无法验证，请从官方发布页获取新版。' : '国内下载线路暂不可用，请稍后重试。',
    );
  }

  Stream<List<int>> _stream(Uri url, String accept) async* {
    for (var hop = 0; hop < 5; hop++) {
      if (url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty) {
        throw const FormatException('无效的下载地址');
      }
      final abort = Completer<void>();
      try {
        final request =
            http.AbortableRequest('GET', url, abortTrigger: abort.future)
              ..followRedirects = false
              ..headers['accept'] = accept
              ..headers['user-agent'] = 'Whale-Collection';
        final response = await _http.send(request).timeout(_timeout);
        if (response.statusCode == 200) {
          yield* response.stream.timeout(_timeout);
          return;
        }
        await response.stream.listen(null).cancel();
        final location = response.headers['location'];
        if (!const {301, 302, 303, 307, 308}.contains(response.statusCode) ||
            location == null) {
          throw const HttpException('更新服务暂不可用');
        }
        url = url.resolve(location);
      } finally {
        abort.complete();
      }
    }
    throw const HttpException('更新地址跳转次数过多');
  }
}

class AppUpdates extends ChangeNotifier {
  final _http = http.Client();
  late final _releases = ReleaseClient(_http);
  static const _channel = MethodChannel('app.toolcollection/updates');
  static const _lastCheck = 'app_updates_last_check';
  final _preferences = SharedPreferencesAsync();
  bool _closed = false;
  String? installed;
  List<String> _abis = const [];
  AppRelease? release;
  double? progress;
  String? message;
  bool checking = false;
  bool downloaded = false;
  bool openingInstaller = false;
  bool get busy => checking || progress != null || openingInstaller;

  Future<void> check({bool automatic = false}) async {
    if (busy) return;
    checking = true;
    if (!automatic) message = null;
    _notify();
    try {
      if (installed == null) {
        final info = await _channel.invokeMapMethod<String, dynamic>('info');
        installed = info!['version'] as String;
        _abis = (info['abis'] as List).cast<String>();
      }
      _notify();
      if (automatic) {
        final last = await _preferences.getInt(_lastCheck);
        final now = DateTime.now().millisecondsSinceEpoch;
        if (last != null &&
            now >= last &&
            now - last < const Duration(hours: 12).inMilliseconds) {
          return;
        }
      }
      final latest = await _releases.latest(installed!, _abis);
      if (release?.version != latest?.version) downloaded = false;
      release = latest;
      if (!automatic && latest == null) message = '当前已是最新版本。';
      try {
        if (latest == null) {
          await _preferences.setInt(
            _lastCheck,
            DateTime.now().millisecondsSinceEpoch,
          );
        } else {
          await _preferences.remove(_lastCheck);
        }
      } on PlatformException {
        // Checking remains available if Android cannot store the timestamp.
      }
    } on Exception catch (error) {
      if (!automatic) {
        message = error is UpdateFailure ? error.message : '暂时无法检查更新，请稍后重试。';
      }
    } finally {
      checking = false;
      _notify();
    }
  }

  Future<void> download() async {
    final next = release;
    if (next == null || busy) return;
    message = null;
    progress = 0;
    _notify();
    try {
      final cache = await getTemporaryDirectory();
      final target = File('${cache.path}/updates/whale.apk');
      final arguments = {'version': next.version};
      await _releases.download(
        next,
        target,
        verify: () => _channel.invokeMethod<void>('verify', arguments),
        onProgress: (value) {
          if (value != 0 && (value - progress!).abs() < .01 && value < 1) {
            return;
          }
          progress = value;
          _notify();
        },
      );
      downloaded = true;
    } on Exception catch (error) {
      message = error is UpdateFailure ? error.message : '无法保存安装包，请检查可用空间后重试。';
    } finally {
      progress = null;
      _notify();
    }
  }

  Future<void> install() async {
    if (!downloaded || busy) return;
    openingInstaller = true;
    message = null;
    _notify();
    try {
      final result = await _channel.invokeMethod<String>('install', {
        'version': release!.version,
      });
      if (result == 'permission') {
        message = '在系统设置中允许安装应用，返回后再点「安装更新」。';
      }
    } on PlatformException catch (error) {
      if (error.code == 'invalid_apk' || error.code == 'update_error') {
        downloaded = false;
      }
      message = error.message ?? '暂时无法安装，请重试。';
    } finally {
      openingInstaller = false;
      _notify();
    }
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _http.close();
    super.dispose();
  }
}
