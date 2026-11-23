import 'collection_models.dart';

const maxBatchLinks = 30;

({List<Uri> urls, int duplicates, int unrecognized, int excess}) parseLinkText(
  String input,
) {
  final pattern = RegExp(
    r'''https?://(?:(?!,https?://)[^\s<>"'，、。；！？])+''',
    caseSensitive: false,
  );
  final urls = <Uri>[];
  final seen = <String>{};
  var duplicates = 0;
  var unrecognized = 0;
  var excess = 0;
  for (final line in input.split('\n')) {
    if (line.trim().isEmpty) continue;
    final matches = pattern.allMatches(line);
    if (matches.isEmpty) unrecognized++;
    for (final match in matches) {
      var value = match.group(0)!;
      if (value != line.trim()) {
        value = value.replaceFirst(RegExp(r'[,.;，。；）]+$'), '');
        while (value.endsWith(')') &&
            ')'.allMatches(value).length > '('.allMatches(value).length) {
          value = value.substring(0, value.length - 1);
        }
      }
      final url = webUri(value);
      if (url == null) {
        unrecognized++;
      } else if (!seen.add(LinkIdentity(url).key)) {
        duplicates++;
      } else if (urls.length == maxBatchLinks) {
        excess++;
      } else {
        urls.add(url);
      }
    }
  }
  return (
    urls: urls,
    duplicates: duplicates,
    unrecognized: unrecognized,
    excess: excess,
  );
}

final _variable = RegExp(r'\{\{([^{}\r\n]+)\}\}');

List<String> promptVariables(String text) => {
  for (final match in _variable.allMatches(text))
    if (match.group(1)!.trim().isNotEmpty) match.group(1)!.trim(),
}.toList();

String fillPrompt(String text, Map<String, String> values) =>
    text.replaceAllMapped(
      _variable,
      (match) => values[match.group(1)!.trim()] ?? match.group(0)!,
    );

String collectionMarkdown(
  Iterable<Entry> entries, {
  bool notes = false,
  bool promptText = false,
}) {
  String escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAllMapped(
        RegExp(r'[\\\[\]#*_`|!~]'),
        (match) => '\\${match.group(0)}',
      );
  final out = StringBuffer('# 大肥鱼的收藏箱\n');
  for (final entry in entries) {
    final title =
        !promptText &&
            entry.kind == SourceKind.prompt &&
            entry.title == defaultPromptTitle(entry.promptText)
        ? '未命名提示词'
        : entry.title;
    out.writeln('\n## ${escape(compact(title))}\n');
    if (entry.preview.isNotEmpty) {
      out.writeln('${escape(compact(entry.preview))}\n');
    }
    if (entry.tags.isNotEmpty) {
      out.writeln('标签：${entry.tags.map(escape).join('、')}\n');
    }
    if (entry.toolLink case final link?) {
      out.writeln('[${escape(compact(link.label))}](<${link.url}>)\n');
    }
    if (notes && entry.note.isNotEmpty) {
      out.writeln('个人备注：${escape(compact(entry.note))}\n');
    }
    if (promptText && entry.kind == SourceKind.prompt) {
      out.writeln('提示词原文：\n');
      for (final line in entry.promptText.split('\n')) {
        out.writeln('    $line');
      }
    }
  }
  return out.toString();
}
