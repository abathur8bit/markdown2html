import 'dart:io';

import 'package:args/args.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mustache_template/mustache_template.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption(
      'input',
      abbr: 'i',
      help: 'Input directory containing 00-index.md and markdown files.',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Output directory where html files will be written.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show usage information.',
    );

  ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln('Argument error: $e');
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (results['help'] == true) {
    _printUsage(parser);
    return;
  }

  final inputPath = results['input'] as String?;
  final outputPath = results['output'] as String?;

  if (inputPath == null || inputPath.trim().isEmpty) {
    stderr.writeln('Missing required option: --input');
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  if (outputPath == null || outputPath.trim().isEmpty) {
    stderr.writeln('Missing required option: --output');
    _printUsage(parser);
    exitCode = 64;
    return;
  }

  final inputDir = Directory(inputPath);
  final outputDir = Directory(outputPath);

  if (!inputDir.existsSync()) {
    stderr.writeln('Input directory does not exist: ${inputDir.path}');
    exitCode = 66;
    return;
  }

  final indexFile = File(_join(inputDir.path, '00-index.md'));
  if (!indexFile.existsSync()) {
    stderr.writeln('00-index.md not found in input directory: ${inputDir.path}');
    exitCode = 66;
    return;
  }

  outputDir.createSync(recursive: true);

  final allFilesByRelativePath = _discoverFiles(inputDir);
  final markdownFilesByRelativePath = {
    for (final entry in allFilesByRelativePath.entries)
      if (entry.key.toLowerCase().endsWith('.md')) entry.key: entry.value,
  };

  final wikiLookup = _buildLookup(markdownFilesByRelativePath.keys);
  final assetLookup = _buildLookup(
    allFilesByRelativePath.keys.where((path) => !path.toLowerCase().endsWith('.md')),
  );

  final orderedManifest = _parseIndexOrderFromWikiLinks(indexFile, wikiLookup);

  final pageOrder = <String>[];
  final seen = <String>{};

  void addPage(String path) {
    final normalized = _normalizeRelativePath(path);
    if (seen.add(normalized)) {
      pageOrder.add(normalized);
    }
  }

  addPage('00-index.md');

  for (final path in orderedManifest) {
    if (path.toLowerCase() == '00-index.md') {
      continue;
    }
    addPage(path);
  }

  // Recursively include wiki-linked files from all included pages,
  // even if they were not listed in 00-index.md.
  for (int i = 0; i < pageOrder.length; i++) {
    final currentMarkdownPath = pageOrder[i];
    final sourceFile = File(_join(inputDir.path, currentMarkdownPath));

    if (!sourceFile.existsSync()) {
      stderr.writeln('Referenced file not found: $currentMarkdownPath');
      exitCode = 66;
      return;
    }

    final markdownText = sourceFile.readAsStringSync();
    final wikiTargets = _extractWikiTargets(markdownText);

    for (final rawTarget in wikiTargets) {
      final resolved = _resolveWikiTarget(
        rawTarget,
        currentMarkdownPath,
        wikiLookup,
      );

      if (resolved == null) {
        stderr.writeln(
          'Warning: could not resolve wiki link "[[$rawTarget]]" in $currentMarkdownPath',
        );
        continue;
      }

      addPage(resolved);
    }
  }

  final pages = <PageInfo>[
    for (final markdownPath in pageOrder)
      PageInfo(
        markdownRelativePath: markdownPath,
        htmlRelativePath: markdownPath.toLowerCase() == '00-index.md'
            ? 'index.html'
            : _markdownPathToHtml(markdownPath),
        title: _extractTitle(File(_join(inputDir.path, markdownPath))),
        isIndex: markdownPath.toLowerCase() == '00-index.md',
      ),
  ];

  final pageByMarkdownPath = <String, PageInfo>{
    for (final p in pages) p.markdownRelativePath: p,
  };

  const templateSource = '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>{{pageTitle}}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg: #ffffff;
      --fg: #1f2937;
      --muted: #6b7280;
      --border: #e5e7eb;
      --sidebar-bg: #f9fafb;
      --active-bg: #e0ecff;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: Arial, Helvetica, sans-serif;
      color: var(--fg);
      background: var(--bg);
    }

    .layout {
      display: flex;
      min-height: 100vh;
    }

    .sidebar {
      width: 280px;
      flex: 0 0 280px;
      border-right: 1px solid var(--border);
      background: var(--sidebar-bg);
      padding: 1rem;
      overflow-y: auto;
    }

    .sidebar h2 {
      margin-top: 0;
      font-size: 1.1rem;
    }

    .sidebar ul {
      list-style: none;
      margin: 0;
      padding: 0;
    }

    .sidebar li {
      margin: 0.25rem 0;
    }

    .sidebar a {
      display: block;
      padding: 0.5rem 0.75rem;
      color: var(--fg);
      text-decoration: none;
      border-radius: 6px;
    }

    .sidebar a:hover {
      background: #eef2f7;
    }

    .sidebar a.active {
      background: var(--active-bg);
      font-weight: bold;
    }

    .content {
      flex: 1;
      min-width: 0;
      padding: 2rem;
      overflow-x: auto;
    }

    .content img {
      max-width: 100%;
      height: auto;
    }

    .content pre {
      overflow-x: auto;
      padding: 0.75rem;
      background: #f4f4f5;
      border-radius: 6px;
    }

    .content code {
      font-family: Consolas, Monaco, monospace;
    }

    .content table {
      border-collapse: collapse;
      width: 100%;
    }

    .content th, .content td {
      border: 1px solid var(--border);
      padding: 0.5rem;
      text-align: left;
    }

    .content blockquote {
      border-left: 4px solid var(--border);
      margin-left: 0;
      padding-left: 1rem;
      color: var(--muted);
    }

    @media (max-width: 900px) {
      .layout {
        flex-direction: column;
      }

      .sidebar {
        width: 100%;
        flex: none;
        border-right: none;
        border-bottom: 1px solid var(--border);
      }
    }
  </style>
</head>
<body>
  <div class="layout">
    <aside class="sidebar">
      <h2>Contents</h2>
      <ul>
        {{#sidebarItems}}
        <li>
          <a href="{{href}}"{{#active}} class="active"{{/active}}>{{title}}</a>
        </li>
        {{/sidebarItems}}
      </ul>
    </aside>
    <main class="content">
      {{{content}}}
    </main>
  </div>
</body>
</html>
''';

  final template = Template(
    templateSource,
    htmlEscapeValues: false,
    lenient: true,
  );

  for (final page in pages) {
    final sourceFile = File(_join(inputDir.path, page.markdownRelativePath));
    final markdownText = sourceFile.readAsStringSync();

    final pageHtmlFullPath = _join(outputDir.path, page.htmlRelativePath);
    final currentOutputDir = File(pageHtmlFullPath).parent.path;

    final preprocessedMarkdown = _replaceWikiLinks(
      markdownText: markdownText,
      currentMarkdownRelativePath: page.markdownRelativePath,
      currentOutputDir: currentOutputDir,
      outputDirPath: outputDir.path,
      pageByMarkdownPath: pageByMarkdownPath,
      wikiLookup: wikiLookup,
      assetLookup: assetLookup,
      inputDirPath: inputDir.path,
    );

    final renderedMarkdown = md.markdownToHtml(
      preprocessedMarkdown,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );

    final sidebarItems = pages.map((p) {
      final targetHtmlFullPath = _join(outputDir.path, p.htmlRelativePath);
      final href = _relativePath(
        fromDirectory: currentOutputDir,
        toFile: targetHtmlFullPath,
      );

      return {
        'title': p.title,
        'href': href,
        'active': p.htmlRelativePath == page.htmlRelativePath,
      };
    }).toList();

    final html = template.renderString({
      'pageTitle': page.title,
      'content': renderedMarkdown,
      'sidebarItems': sidebarItems,
    });

    final outFile = File(pageHtmlFullPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(html);

    stdout.writeln('Wrote ${page.htmlRelativePath}');
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln('''
Usage:
  dart run bin/mdsite.dart --input <inputDir> --output <outputDir>

Options:
${parser.usage}
''');
}

List<String> _parseIndexOrderFromWikiLinks(
    File indexFile,
    Map<String, List<String>> wikiLookup,
    ) {
  final content = indexFile.readAsStringSync();
  final rawTargets = _extractWikiTargets(content);

  final ordered = <String>[];
  final seen = <String>{};

  for (final rawTarget in rawTargets) {
    final resolved = _resolveWikiTarget(rawTarget, '00-index.md', wikiLookup);
    if (resolved == null) {
      stderr.writeln(
        'Warning: could not resolve wiki link "[[$rawTarget]]" in 00-index.md',
      );
      continue;
    }

    if (seen.add(resolved)) {
      ordered.add(resolved);
    }
  }

  return ordered;
}

List<String> _extractWikiTargets(String markdownText) {
  final matches = RegExp(r'\[\[([^\[\]]+)\]\]').allMatches(markdownText);
  return [
    for (final match in matches)
      if (match.start == 0 || markdownText[match.start - 1] != '!')
        if ((match.group(1) ?? '').trim().isNotEmpty) (match.group(1) ?? '').trim(),
  ];
}

String _replaceWikiLinks({
  required String markdownText,
  required String currentMarkdownRelativePath,
  required String currentOutputDir,
  required String outputDirPath,
  required Map<String, PageInfo> pageByMarkdownPath,
  required Map<String, List<String>> wikiLookup,
  required Map<String, List<String>> assetLookup,
  required String inputDirPath,
}) {
  return markdownText.replaceAllMapped(
    RegExp(r'(!)?\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]'),
        (match) {
      final isImageWikiLink = match.group(1) == '!';
      final rawTarget = match.group(2)?.trim();
      final rawLabel = match.group(3)?.trim();

      if (rawTarget == null || rawTarget.isEmpty) {
        return match.group(0)!;
      }

      if (isImageWikiLink) {
        final resolvedAssetPath = _resolveAssetTarget(
          rawTarget,
          currentMarkdownRelativePath,
          assetLookup,
        );

        if (resolvedAssetPath == null) {
          stderr.writeln(
            'Warning: could not resolve wiki image link "![[${rawTarget}]]" in $currentMarkdownRelativePath',
          );
          return match.group(0)!;
        }

        final sourceAssetPath = _join(inputDirPath, resolvedAssetPath);
        final copiedAssetPath = _join(outputDirPath, resolvedAssetPath);

        File(copiedAssetPath).parent.createSync(recursive: true);
        File(sourceAssetPath).copySync(copiedAssetPath);

        final href = _relativePath(
          fromDirectory: currentOutputDir,
          toFile: copiedAssetPath,
        );

        final altText = rawLabel ?? _basenameWithoutExtension(resolvedAssetPath);
        return '![${_escapeMarkdownLinkText(altText)}](${_encodeUrlPath(href)})';
      }

      final resolvedMarkdownPath = _resolveWikiTarget(
        rawTarget,
        currentMarkdownRelativePath,
        wikiLookup,
      );

      if (resolvedMarkdownPath == null) {
        stderr.writeln(
          'Warning: could not resolve wiki link "[[$rawTarget]]" in $currentMarkdownRelativePath',
        );
        return rawLabel ?? rawTarget;
      }

      final page = pageByMarkdownPath[resolvedMarkdownPath];
      if (page == null) {
        stderr.writeln(
          'Warning: wiki link target resolved but not included in output: $resolvedMarkdownPath',
        );
        return rawLabel ?? rawTarget;
      }

      final targetHtmlFullPath = _join(outputDirPath, page.htmlRelativePath);
      final href = _relativePath(
        fromDirectory: currentOutputDir,
        toFile: targetHtmlFullPath,
      );

      final label = rawLabel ?? page.title;

      return '[${_escapeMarkdownLinkText(label)}](${_encodeUrlPath(href)})';
    },
  );
}

String _encodeUrlPath(String path) {
  return path
      .split('/')
      .map(Uri.encodeComponent)
      .join('/');
}

String _escapeMarkdownLinkText(String text) {
  return text.replaceAll('[', r'\[').replaceAll(']', r'\]');
}



String _basenameWithoutExtension(String path) {
  final basename = path.split('/').last;
  return basename.replaceFirst(RegExp(r'\.[^.]+$'), '');
}

String? _resolveAssetTarget(
  String rawTarget,
  String currentMarkdownRelativePath,
  Map<String, List<String>> assetLookup,
) {
  final normalizedTarget = rawTarget.replaceAll('\\', '/').trim();

  final exactKey = _wikiKey(normalizedTarget);
  final exactMatches = assetLookup[exactKey];
  if (exactMatches != null && exactMatches.length == 1) {
    return exactMatches.first;
  }
  if (exactMatches != null && exactMatches.isNotEmpty) {
    return _preferClosestPath(currentMarkdownRelativePath, exactMatches);
  }

  final basename = normalizedTarget.split('/').last;
  final baseKey = _wikiKey(basename);
  final baseMatches = assetLookup[baseKey];
  if (baseMatches != null && baseMatches.length == 1) {
    return baseMatches.first;
  }
  if (baseMatches != null && baseMatches.isNotEmpty) {
    return _preferClosestPath(currentMarkdownRelativePath, baseMatches);
  }

  return null;
}

String? _resolveWikiTarget(
    String rawTarget,
    String currentMarkdownRelativePath,
    Map<String, List<String>> wikiLookup,
    ) {
  final normalizedTarget = rawTarget.replaceAll('\\', '/').trim();
  final withMd = normalizedTarget.toLowerCase().endsWith('.md')
      ? normalizedTarget
      : '$normalizedTarget.md';

  final exactKey = _wikiKey(withMd);
  final exactMatches = wikiLookup[exactKey];
  if (exactMatches != null && exactMatches.length == 1) {
    return exactMatches.first;
  }
  if (exactMatches != null && exactMatches.isNotEmpty) {
    return _preferClosestPath(currentMarkdownRelativePath, exactMatches);
  }

  final basename = withMd.split('/').last;
  final baseKey = _wikiKey(basename);
  final baseMatches = wikiLookup[baseKey];
  if (baseMatches != null && baseMatches.length == 1) {
    return baseMatches.first;
  }
  if (baseMatches != null && baseMatches.isNotEmpty) {
    return _preferClosestPath(currentMarkdownRelativePath, baseMatches);
  }

  return null;
}

String _preferClosestPath(String currentPath, List<String> candidates) {
  final sorted = [...candidates];
  sorted.sort((a, b) {
    final aScore = _pathDistance(currentPath, a);
    final bScore = _pathDistance(currentPath, b);
    final cmp = aScore.compareTo(bScore);
    if (cmp != 0) {
      return cmp;
    }
    return a.compareTo(b);
  });
  return sorted.first;
}

int _pathDistance(String a, String b) {
  final aParts = _splitPath(a);
  final bParts = _splitPath(b);

  int common = 0;
  while (common < aParts.length &&
      common < bParts.length &&
      aParts[common] == bParts[common]) {
    common++;
  }

  return (aParts.length - common) + (bParts.length - common);
}

Map<String, String> _discoverFiles(Directory inputDir) {
  final files = <String, String>{};

  for (final entity in inputDir.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }

    final fullPath = entity.path;
    final relativePath = _relativePath(
      fromDirectory: inputDir.path,
      toFile: fullPath,
    );

    files[_normalizeRelativePath(relativePath)] = fullPath;
  }

  return files;
}

Map<String, List<String>> _buildLookup(Iterable<String> relativePaths) {
  final map = <String, List<String>>{};

  for (final path in relativePaths) {
    final normalized = _normalizeRelativePath(path);
    final fullKey = _wikiKey(normalized);
    final baseKey = _wikiKey(normalized.split('/').last);

    map.putIfAbsent(fullKey, () => []).add(normalized);
    if (baseKey != fullKey) {
      map.putIfAbsent(baseKey, () => []).add(normalized);
    }
  }

  return map;
}

String _wikiKey(String value) {
  return value.replaceAll('\\', '/').trim().toLowerCase();
}

String _extractTitle(File markdownFile) {
  final lines = markdownFile.readAsLinesSync();

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.startsWith('# ')) {
      return line.substring(2).trim();
    }
  }

  final name = markdownFile.uri.pathSegments.isNotEmpty
      ? markdownFile.uri.pathSegments.last
      : markdownFile.path;
  final withoutExtension =
  name.replaceFirst(RegExp(r'\.md$', caseSensitive: false), '');

  return withoutExtension.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
}

String _markdownPathToHtml(String relativeMarkdownPath) {
  return relativeMarkdownPath.replaceFirst(
    RegExp(r'\.md$', caseSensitive: false),
    '.html',
  );
}

String _normalizeRelativePath(String path) {
  final normalized = path.replaceAll('\\', '/').trim();
  if (normalized.startsWith('/')) {
    return normalized.substring(1);
  }
  return normalized;
}

String _join(String a, String b) {
  if (a.endsWith(Platform.pathSeparator)) {
    return '$a$b';
  }
  return '$a${Platform.pathSeparator}$b';
}

String _relativePath({
  required String fromDirectory,
  required String toFile,
}) {
  final fromParts = _splitPath(fromDirectory);
  final toParts = _splitPath(toFile);

  int common = 0;
  while (common < fromParts.length &&
      common < toParts.length &&
      fromParts[common] == toParts[common]) {
    common++;
  }

  final upMoves = List.filled(fromParts.length - common, '..');
  final downMoves = toParts.sublist(common);

  final resultParts = [...upMoves, ...downMoves];
  if (resultParts.isEmpty) {
    return '.';
  }

  return resultParts.join('/');
}

List<String> _splitPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  return normalized.split('/').where((part) => part.isNotEmpty).toList();
}

class PageInfo {
  final String markdownRelativePath;
  final String htmlRelativePath;
  final String title;
  final bool isIndex;

  PageInfo({
    required this.markdownRelativePath,
    required this.htmlRelativePath,
    required this.title,
    this.isIndex = false,
  });
}