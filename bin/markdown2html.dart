import 'dart:io';

import 'package:args/args.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:markdown2html/version.dart';
import 'package:mustache_template/mustache_template.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption(
      'input',
      abbr: 'i',
      help: 'Input directory containing 000-index.md and markdown files.',
    )
    ..addOption(
      'output',
      abbr: 'o',
      help: 'Output directory where html files will be written.',
    )
    ..addFlag(
      'clean',
      negatable: false,
      help: 'Delete all existing files and directories in the output directory before generating.',
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
  final cleanOutput = results['clean'] == true;

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

  final indexFile = File(_join(inputDir.path, '000-index.md'));
  if (!indexFile.existsSync()) {
    stderr.writeln('000-index.md not found in input directory: ${inputDir.path}');
    exitCode = 66;
    return;
  }

  if (cleanOutput && outputDir.existsSync()) {
    _cleanDirectory(outputDir);
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
  final faviconAssets = _findFaviconAssets(allFilesByRelativePath.keys);

  final orderedManifest = _parseIndexOrderFromWikiLinks(indexFile, wikiLookup);

  final pageOrder = <String>[];
  final seen = <String>{};

  void addPage(String path) {
    final normalized = _normalizeRelativePath(path);
    if (seen.add(normalized)) {
      pageOrder.add(normalized);
    }
  }

  addPage('000-index.md');

  for (final path in orderedManifest) {
    if (path.toLowerCase() == '000-index.md') {
      continue;
    }
    addPage(path);
  }

  // Recursively include wiki-linked files from all included pages,
  // even if they were not listed in 000-index.md.
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
        htmlRelativePath: markdownPath.toLowerCase() == '000-index.md'
            ? 'index.html'
            : _markdownPathToHtml(markdownPath),
        title: _extractTitle(File(_join(inputDir.path, markdownPath))),
        isIndex: markdownPath.toLowerCase() == '000-index.md',
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
  {{#faviconLinks}}
  <link rel="icon" href="{{href}}" sizes="{{sizes}}" type="image/png">
  {{/faviconLinks}}
  <style>
    :root {
      color-scheme: light dark;
      --bg: #ffffff;
      --fg: #1f2937;
      --muted: #6b7280;
      --border: #e5e7eb;
      --sidebar-bg: #f9fafb;
      --active-bg: #e0ecff;
      --hover-bg: #eef2f7;
      --code-bg: #f4f4f5;
    }

    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0f172a;
        --fg: #e5e7eb;
        --muted: #9ca3af;
        --border: #334155;
        --sidebar-bg: #111827;
        --active-bg: #1e3a8a;
        --hover-bg: #1f2937;
        --code-bg: #1e293b;
      }
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
      background: var(--hover-bg);
    }

    .sidebar a.active {
      background: var(--active-bg);
      font-weight: bold;
    }

    .doc-top-nav {
      margin-bottom: 1.5rem;
    }
    
    .sidebar-logo {
      margin-top: 1rem;
      margin-bottom: 1rem;
      text-align: center;
    }
    
    .sidebar-logo img {
      display: inline-block;
    }
    .content {
      flex: 1;
      min-width: 0;
      padding: 2rem;
      overflow-x: auto;
    }

    .content img {
      display: block;
      margin: 0 auto;
      max-width: 80%;
      height: auto;
      cursor: zoom-in;
    }

    .lightbox {
      position: fixed;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      background: rgba(0, 0, 0, 0.85);
      z-index: 999;
      padding: 1.5rem;
      cursor: zoom-out;
    }

    .lightbox.open {
      display: flex;
    }

    .lightbox img {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      box-shadow: 0 12px 28px rgba(0, 0, 0, 0.45);
      border-radius: 4px;
      cursor: auto;
    }

    .lightbox .close {
      position: absolute;
      top: 1rem;
      right: 1rem;
      border: none;
      background: rgba(255, 255, 255, 0.16);
      color: #fff;
      font-size: 1.5rem;
      width: 2.25rem;
      height: 2.25rem;
      border-radius: 50%;
      cursor: pointer;
      line-height: 1;
    }

    .content pre {
      overflow-x: auto;
      padding: 0.75rem;
      background: var(--code-bg);
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
      position: relative;
      margin: 0;
      padding: 1.5rem 1.25rem 1rem 1.25rem; /* extra top padding for Note text */
      color: #24505a;
    
      background: #e6fbff;
      border: 1px solid #7fc7d1;
      border-radius: 8px;
    }
    
    .content blockquote::before {
      content: "Note";
      position: absolute;
      top: 1rem;
      left: 1.1rem;
      font-size: 0.75rem;
      font-weight: 700;
      color: #2b6f7a;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .footer-muted {
      margin-top: 2rem;
      padding-top: 1rem;
      border-top: 1px solid var(--border);
      color: var(--muted);
      font-size: 0.95rem;
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
      <div class="doc-top-nav">
          <a href="/">&larr; BookmarkSquirrel.com</a>
      </div>
      <div class="sidebar-logo">
        <img src="/documentation/bookmarksquirrel-logo.webp" width="128" alt="Bookmark Squirrel logo">
      </div>
      <h1>Documentation</h1>
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
      {{#footerContent}}
      <footer class="footer-muted">
        {{{footerContent}}}
      </footer>
      {{/footerContent}}
    </main>
  </div>
  <div class="lightbox" id="lightbox" aria-hidden="true">
    <button class="close" id="lightbox-close" aria-label="Close enlarged image">×</button>
    <img id="lightbox-image" src="" alt="">
  </div>
  <script>
    (() => {
      const lightbox = document.getElementById('lightbox');
      const lightboxImage = document.getElementById('lightbox-image');
      const closeButton = document.getElementById('lightbox-close');
      if (!lightbox || !lightboxImage || !closeButton) {
        return;
      }

      const closeLightbox = () => {
        lightbox.classList.remove('open');
        lightbox.setAttribute('aria-hidden', 'true');
        lightboxImage.removeAttribute('src');
        lightboxImage.alt = '';
      };

      document.querySelectorAll('.content img').forEach((image) => {
        image.addEventListener('click', () => {
          const source = image.getAttribute('src');
          if (!source) {
            return;
          }

          lightboxImage.src = source;
          lightboxImage.alt = image.getAttribute('alt') || '';
          lightbox.classList.add('open');
          lightbox.setAttribute('aria-hidden', 'false');
        });
      });

      closeButton.addEventListener('click', closeLightbox);
      lightbox.addEventListener('click', (event) => {
        if (event.target === lightbox) {
          closeLightbox();
        }
      });

      document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && lightbox.classList.contains('open')) {
          closeLightbox();
        }
      });
    })();
  </script>
</body>
</html>
''';

  final template = Template(
    templateSource,
    htmlEscapeValues: false,
    lenient: true,
  );

  final footerRelativePath = '999-footer.md';
  final footerSourceFile = File(_join(inputDir.path, footerRelativePath));
  final hasFooter = footerSourceFile.existsSync();

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

    final markdownWithResolvedHtmlImages = _replaceHtmlImageSources(
      markdownText: preprocessedMarkdown,
      currentMarkdownRelativePath: page.markdownRelativePath,
      currentOutputDir: currentOutputDir,
      outputDirPath: outputDir.path,
      assetLookup: assetLookup,
      inputDirPath: inputDir.path,
    );

    final renderedMarkdown = md.markdownToHtml(
      markdownWithResolvedHtmlImages,
      extensionSet: md.ExtensionSet.gitHubWeb,
    );

    String? renderedFooter;
    if (hasFooter) {
      final footerMarkdownText = footerSourceFile.readAsStringSync();
      final preprocessedFooter = _replaceHtmlImageSources(
        markdownText: _replaceWikiLinks(
          markdownText: footerMarkdownText,
          currentMarkdownRelativePath: footerRelativePath,
          currentOutputDir: currentOutputDir,
          outputDirPath: outputDir.path,
          pageByMarkdownPath: pageByMarkdownPath,
          wikiLookup: wikiLookup,
          assetLookup: assetLookup,
          inputDirPath: inputDir.path,
        ),
        currentMarkdownRelativePath: footerRelativePath,
        currentOutputDir: currentOutputDir,
        outputDirPath: outputDir.path,
        assetLookup: assetLookup,
        inputDirPath: inputDir.path,
      );

      renderedFooter = md.markdownToHtml(
        preprocessedFooter,
        extensionSet: md.ExtensionSet.gitHubWeb,
      );
    }

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

    final faviconLinks = faviconAssets.map((faviconAsset) {
      final sourceAssetPath = _join(inputDir.path, faviconAsset.path);
      final copiedAssetPath = _join(outputDir.path, faviconAsset.path);

      File(copiedAssetPath).parent.createSync(recursive: true);
      File(sourceAssetPath).copySync(copiedAssetPath);

      return {
        'href': _encodeUrlPath(
          _relativePath(
            fromDirectory: currentOutputDir,
            toFile: copiedAssetPath,
          ),
        ),
        'sizes': faviconAsset.sizes,
      };
    }).toList();

    final html = template.renderString({
      'pageTitle': page.title,
      'content': renderedMarkdown,
      'sidebarItems': sidebarItems,
      'footerContent': renderedFooter,
      'faviconLinks': faviconLinks,
    });

    final outFile = File(pageHtmlFullPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(html);

    stdout.writeln('Wrote ${page.htmlRelativePath}');
  }
}

void _cleanDirectory(Directory directory) {
  for (final entity in directory.listSync(followLinks: false)) {
    entity.deleteSync(recursive: true);
  }
}

void _printUsage(ArgParser parser) {
  stdout.writeln("Version: $appVersion");
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
    final resolved = _resolveWikiTarget(rawTarget, '000-index.md', wikiLookup);
    if (resolved == null) {
      stderr.writeln(
        'Warning: could not resolve wiki link "[[$rawTarget]]" in 000-index.md',
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

String _replaceHtmlImageSources({
  required String markdownText,
  required String currentMarkdownRelativePath,
  required String currentOutputDir,
  required String outputDirPath,
  required Map<String, List<String>> assetLookup,
  required String inputDirPath,
}) {
  final imageTagPattern = RegExp(
    r"""<img\b[^>]*\bsrc\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))[^>]*>""",
    caseSensitive: false,
  );

  return markdownText.replaceAllMapped(imageTagPattern, (match) {
    final rawSource = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').trim();
    if (rawSource.isEmpty) {
      return match.group(0)!;
    }

    if (_isExternalSource(rawSource)) {
      return match.group(0)!;
    }

    final sourceWithoutQuery = rawSource.split('?').first.split('#').first;
    final resolvedAssetPath = _resolveAssetTarget(
      Uri.decodeFull(sourceWithoutQuery),
      currentMarkdownRelativePath,
      assetLookup,
    );

    if (resolvedAssetPath == null) {
      stderr.writeln(
        'Warning: could not resolve html image src "$rawSource" in $currentMarkdownRelativePath',
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

    final replacementSrc = _encodeUrlPath(href);
    final originalTag = match.group(0)!;

    final doubleQuoted = RegExp(
      r'(src\s*=\s*")([^"]*)(")',
      caseSensitive: false,
    );
    if (doubleQuoted.hasMatch(originalTag)) {
      return originalTag.replaceFirstMapped(
        doubleQuoted,
        (m) => '${m.group(1)}$replacementSrc${m.group(3)}',
      );
    }

    final singleQuoted = RegExp(r"(?i)(src\s*=\s*')([^']*)(')");
    if (singleQuoted.hasMatch(originalTag)) {
      return originalTag.replaceFirstMapped(
        singleQuoted,
        (m) => '${m.group(1)}$replacementSrc${m.group(3)}',
      );
    }

    final unquoted = RegExp(r'(?i)(src\s*=\s*)([^\s>]+)');
    return originalTag.replaceFirstMapped(
      unquoted,
      (m) => '${m.group(1)}$replacementSrc',
    );
  });
}

bool _isExternalSource(String source) {
  final lower = source.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('data:') ||
      lower.startsWith('//') ||
      lower.startsWith('mailto:');
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

List<FaviconAsset> _findFaviconAssets(Iterable<String> relativePaths) {
  final faviconPattern = RegExp(r'^favicon-(\d+x\d+)\.png$', caseSensitive: false);
  final favicons = <FaviconAsset>[];

  for (final path in relativePaths) {
    final normalized = _normalizeRelativePath(path);
    final basename = normalized.split('/').last;
    final match = faviconPattern.firstMatch(basename);
    if (match == null) {
      continue;
    }

    favicons.add(
      FaviconAsset(
        path: normalized,
        sizes: match.group(1)!,
      ),
    );
  }

  favicons.sort((a, b) => a.path.compareTo(b.path));
  return favicons;
}

class FaviconAsset {
  final String path;
  final String sizes;

  FaviconAsset({
    required this.path,
    required this.sizes,
  });
}
