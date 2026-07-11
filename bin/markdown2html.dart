import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:markdown2html/version.dart';
import 'package:mustache_template/mustache_template.dart';
import 'package:html/parser.dart' as html_parser;

bool get isCompiledExecutable {
  final exe = Platform.resolvedExecutable.toLowerCase();
  return !exe.endsWith('dart') && !exe.endsWith('dart.exe');
}

bool get isRunningFromDartRun => !isCompiledExecutable;
String executable = 'markdown2html'; //default to an executable

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
      help:
          'Delete all existing files and directories in the output directory before generating.',
    )
    ..addFlag(
      'create-config',
      negatable: false,
      help:
          'Create a pretty-formatted markdown2html.json config file in --input or the current directory.',
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
  final createConfig = results['create-config'] == true;

  if (createConfig) {
    final configDirectoryPath =
        (inputPath != null && inputPath.trim().isNotEmpty)
        ? inputPath
        : Directory.current.path;
    _createConfigFile(configDirectoryPath);
    if (outputPath == null || outputPath.trim().isEmpty) {
      return;
    }
  }

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

  late final Markdown2HtmlConfig config;
  try {
    config = _loadConfig(inputDir);
  } on FormatException catch (e) {
    stderr.writeln('Config error: $e');
    exitCode = 65;
    return;
  }

  final indexFile = File(_join(inputDir.path, '000-index.md'));
  if (!indexFile.existsSync()) {
    stderr.writeln(
      '000-index.md not found in input directory: ${inputDir.path}',
    );
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
    allFilesByRelativePath.keys.where(
      (path) => !path.toLowerCase().endsWith('.md'),
    ),
  );
  final faviconAssets = config.favicons
      ? _findFaviconAssets(allFilesByRelativePath.keys)
      : const <FaviconAsset>[];

  final cssRelativePath = config.css;
  String? inlineCss;
  if (cssRelativePath != null) {
    final cssSourceFile = File(_join(inputDir.path, cssRelativePath));
    if (!cssSourceFile.existsSync()) {
      stderr.writeln('Configured CSS file not found: $cssRelativePath');
      exitCode = 66;
      return;
    }
    inlineCss = cssSourceFile.readAsStringSync();
  }

  final indexSections = _splitIndexContents(indexFile.readAsStringSync());
  final orderedManifest = _parseIndexOrderFromWikiLinks(
    indexSections.sidebarMarkdown ?? indexSections.visibleMarkdown,
    wikiLookup,
  );

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

  for (int i = 0; i < pageOrder.length; i++) {
    final currentMarkdownPath = pageOrder[i];
    final sourceFile = File(_join(inputDir.path, currentMarkdownPath));

    if (!sourceFile.existsSync()) {
      stderr.writeln('Referenced file not found: $currentMarkdownPath');
      exitCode = 66;
      return;
    }

    final markdownText = sourceFile.readAsStringSync();
    final wikiSource = currentMarkdownPath.toLowerCase() == '000-index.md'
        ? (indexSections.sidebarMarkdown ?? indexSections.visibleMarkdown)
        : markdownText;
    final wikiTargets = _extractWikiTargets(wikiSource);

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

  final featuredCards = _parseFeaturedCards(
    indexSections.featuredMarkdown,
    wikiLookup,
    outputDir.path,
    pageByMarkdownPath,
    assetLookup,
    inputDir.path,
  );

  final sidebarPageOrder = <String>[];
  final seenSidebarPages = <String>{};

  void addSidebarPage(String path) {
    final normalized = _normalizeRelativePath(path);
    if (seenSidebarPages.add(normalized)) {
      sidebarPageOrder.add(normalized);
    }
  }

  addSidebarPage('000-index.md');
  for (final path in orderedManifest) {
    if (path.toLowerCase() == '000-index.md') {
      continue;
    }
    addSidebarPage(path);
  }

  final sidebarPages = <PageInfo>[
    for (final markdownPath in sidebarPageOrder)
      if (pageByMarkdownPath.containsKey(markdownPath))
        pageByMarkdownPath[markdownPath]!,
  ];

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
  {{#inlineCss}}
  <style>
{{{inlineCss}}}
  </style>
  {{/inlineCss}}
</head>
<body>
  <header class="mobile-toolbar">
    <button class="mobile-menu-toggle" type="button" aria-label="Toggle table of contents" aria-expanded="false">
      <i class="bi bi-list" aria-hidden="true"></i>
    </button>
    <div class="mobile-toolbar-title">{{pageTitle}}</div>
  </header>
  <div class="mobile-menu-backdrop" aria-hidden="true"></div>
  <div class="layout">
    <aside class="sidebar">
      <button class="mobile-menu-close" type="button" aria-label="Close table of contents">
        <i class="bi bi-x" aria-hidden="true"></i>
      </button>
      {{#topNav}}
      <div class="doc-top-nav"><a href="{{url}}">{{title}}</a></div>
      {{/topNav}}
      {{#sidebarLogo}}
      <div class="sidebar-logo">
        <img src="{{src}}" alt="{{alt}}">
      </div>
      {{/sidebarLogo}}
      {{#sidebarTitle}}
      <h1>{{sidebarTitle}}</h1>
      {{/sidebarTitle}}
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
      {{#hasFeaturedCards}}
      <section class="featured-cards" aria-label="Featured pages">
        {{#featuredCards}}
        <a class="featured-card" href="{{href}}">
          <div class="featured-card-title">{{title}}</div>
          <div class="featured-card-summary">{{{summaryHtml}}}</div>
        </a>
        {{/featuredCards}}
      </section>
      {{/hasFeaturedCards}}
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
      const menuToggle = document.querySelector('.mobile-menu-toggle');
      const menuClose = document.querySelector('.mobile-menu-close');
      const menuBackdrop = document.querySelector('.mobile-menu-backdrop');
      const sidebarLinks = document.querySelectorAll('.sidebar a');

      const closeMenu = () => {
        document.body.classList.remove('nav-open');
        if (menuToggle) {
          menuToggle.setAttribute('aria-expanded', 'false');
        }
      };

      if (menuToggle) {
        menuToggle.addEventListener('click', () => {
          const isOpen = document.body.classList.toggle('nav-open');
          menuToggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
        });
      }
      if (menuClose) {
        menuClose.addEventListener('click', closeMenu);
      }
      if (menuBackdrop) {
        menuBackdrop.addEventListener('click', closeMenu);
      }
      sidebarLinks.forEach((link) => link.addEventListener('click', closeMenu));

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
        if (event.key === 'Escape' && document.body.classList.contains('nav-open')) {
          closeMenu();
        }
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

  final footerRelativePath = config.footer;
  final footerSourceFile = footerRelativePath == null
      ? null
      : File(_join(inputDir.path, footerRelativePath));
  final hasFooter = footerSourceFile?.existsSync() ?? false;

  for (final page in pages) {
    final sourceFile = File(_join(inputDir.path, page.markdownRelativePath));
    final rawMarkdownText = sourceFile.readAsStringSync();
    final markdownText = page.isIndex
        ? indexSections.visibleMarkdown
        : rawMarkdownText;

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
    if (hasFooter && footerSourceFile != null && footerRelativePath != null) {
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

    final sidebarItems = sidebarPages.map((p) {
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

    final sidebarLogo = _buildSidebarLogo(
      config: config,
      currentOutputDir: currentOutputDir,
      outputDirPath: outputDir.path,
      inputDirPath: inputDir.path,
      assetLookup: assetLookup,
      currentMarkdownRelativePath: page.markdownRelativePath,
    );

    final pageFeaturedCards = page.isIndex
        ? featuredCards
        : const <Map<String, Object>>[];

    final html = template.renderString({
      'pageTitle': stripHtml(page.title),
      'content': renderedMarkdown,
      'featuredCards': pageFeaturedCards,
      'hasFeaturedCards': pageFeaturedCards.isNotEmpty,
      'sidebarItems': sidebarItems,
      'footerContent': renderedFooter,
      'faviconLinks': faviconLinks,
      'inlineCss': inlineCss,
      'sidebarTitle': config.sidebarTitle,
      'sidebarLogo': sidebarLogo,
      'topNav': config.topNav == null
          ? null
          : {'url': config.topNav!.url, 'title': config.topNav!.title},
    });

    final outFile = File(pageHtmlFullPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsStringSync(html);

    stdout.writeln('Wrote ${page.htmlRelativePath}');
  }
}

void _createConfigFile(String directoryPath) {
  final directory = Directory(directoryPath);
  directory.createSync(recursive: true);

  final configFile = File(_join(directory.path, 'markdown2html.json'));
  const defaultConfig = {
    'logo': 'logo.webp',
    'logoAlt': 'Site logo',
    'css': 'site.css',
    'favicons': true,
    'sidebarTitle': 'Your site',
    'footer': '999-footer.md',
    'top-nav': {'url': '/', 'title': 'Home'},
  };

  const encoder = JsonEncoder.withIndent('  ');
  configFile.writeAsStringSync('${encoder.convert(defaultConfig)}\n');
  stdout.writeln('Wrote ${configFile.path}');
}

Markdown2HtmlConfig _loadConfig(Directory inputDir) {
  final configFile = File(_join(inputDir.path, 'markdown2html.json'));
  if (!configFile.existsSync()) {
    return const Markdown2HtmlConfig();
  }

  final decoded = jsonDecode(configFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    stderr.writeln(
      'Invalid config file: markdown2html.json must contain a JSON object.',
    );
    exitCode = 65;
    throw const FormatException('Invalid markdown2html.json');
  }

  return Markdown2HtmlConfig.fromJson(decoded);
}

Map<String, String>? _buildSidebarLogo({
  required Markdown2HtmlConfig config,
  required String currentOutputDir,
  required String outputDirPath,
  required String inputDirPath,
  required Map<String, List<String>> assetLookup,
  required String currentMarkdownRelativePath,
}) {
  final logoTarget = config.logo;
  if (logoTarget == null) {
    return null;
  }

  final resolvedAssetPath = _resolveAssetTarget(
    logoTarget,
    currentMarkdownRelativePath,
    assetLookup,
  );

  if (resolvedAssetPath == null) {
    stderr.writeln(
      'Warning: configured logo could not be resolved: $logoTarget',
    );
    return null;
  }

  final sourceAssetPath = _join(inputDirPath, resolvedAssetPath);
  final copiedAssetPath = _join(outputDirPath, resolvedAssetPath);

  File(copiedAssetPath).parent.createSync(recursive: true);
  File(sourceAssetPath).copySync(copiedAssetPath);

  return {
    'src': _encodeUrlPath(
      _relativePath(fromDirectory: currentOutputDir, toFile: copiedAssetPath),
    ),
    'alt': config.logoAlt ?? 'Site logo',
  };
}

void _cleanDirectory(Directory directory) {
  for (final entity in directory.listSync(followLinks: false)) {
    entity.deleteSync(recursive: true);
  }
}

void _printUsage(ArgParser parser) {
  if (isRunningFromDartRun) {
    executable =
        "dart run bin/markdown2html.dart"; //running from dart, not an executable
  }
  stdout.writeln(
    "Converts a markdown directory into a website with static HTML pages.",
  );
  stdout.writeln("Version: $appVersion");
  stdout.writeln("");
  stdout.writeln(
    "Homepage: https://weatheredhiker.com/pages/markdown2html.html",
  );
  stdout.writeln("Source  : https://github.com/abathur8bit/markdown2html");
  stdout.writeln(
    "Issues  : https://github.com/abathur8bit/markdown2html/issues",
  );
  stdout.writeln("");
  stdout.writeln("Usage: $executable -i <inputDir> -o <outputDir>");
  stdout.writeln("");
  stdout.writeln(parser.usage);
  stdout.writeln("");
}

List<String> _parseIndexOrderFromWikiLinks(
  String markdownText,
  Map<String, List<String>> wikiLookup,
) {
  final rawTargets = _extractWikiTargets(markdownText);

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
        if ((match.group(1) ?? '').trim().isNotEmpty)
          (match.group(1) ?? '').trim(),
  ];
}

IndexSections _splitIndexContents(String markdownText) {
  final lines = markdownText.split('\n');
  final featuredHeading = RegExp(r'^\s*#\s+featured\s*$', caseSensitive: false);
  final contentsHeading = RegExp(r'^\s*#\s+contents\s*$', caseSensitive: false);
  int? featuredStart;
  int? contentsStart;

  for (var i = 0; i < lines.length; i++) {
    if (featuredStart == null && featuredHeading.hasMatch(lines[i])) {
      featuredStart = i;
    }
    if (contentsStart == null && contentsHeading.hasMatch(lines[i])) {
      contentsStart = i;
    }
  }

  final specialSectionStarts = [
    if (featuredStart != null) featuredStart,
    if (contentsStart != null) contentsStart,
  ]..sort();

  final visibleMarkdown = specialSectionStarts.isEmpty
      ? markdownText
      : lines.take(specialSectionStarts.first).join('\n').trimRight();

  String? featuredMarkdown;
  if (featuredStart != null) {
    final featuredEnd = [
      if (contentsStart != null && contentsStart > featuredStart) contentsStart,
      lines.length,
    ].reduce((a, b) => a < b ? a : b);
    final section = lines
        .skip(featuredStart + 1)
        .take(featuredEnd - featuredStart - 1)
        .join('\n')
        .trim();
    featuredMarkdown = section.isEmpty ? null : section;
  }

  String? sidebarMarkdown;
  if (contentsStart != null) {
    final section = lines.skip(contentsStart + 1).join('\n').trim();
    sidebarMarkdown = section.isEmpty ? null : section;
  }

  return IndexSections(
    visibleMarkdown: visibleMarkdown,
    featuredMarkdown: featuredMarkdown,
    sidebarMarkdown: sidebarMarkdown,
  );
}

List<Map<String, Object>> _parseFeaturedCards(
  String? markdownText,
  Map<String, List<String>> wikiLookup,
  String outputDirPath,
  Map<String, PageInfo> pageByMarkdownPath,
  Map<String, List<String>> assetLookup,
  String inputDirPath,
) {
  if (markdownText == null || markdownText.trim().isEmpty) {
    return const [];
  }

  final cards = <Map<String, Object>>[];
  final lines = markdownText.split('\n');
  final itemPattern = RegExp(
    r'^\s*-\s*\[\[([^\[\]]+)\]\]\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*$',
  );

  for (final line in lines) {
    final match = itemPattern.firstMatch(line);
    if (match == null) {
      continue;
    }

    final rawTarget = (match.group(1) ?? '').trim();
    final title = (match.group(2) ?? '').trim();
    final summary = (match.group(3) ?? '').trim();
    if (rawTarget.isEmpty || title.isEmpty || summary.isEmpty) {
      continue;
    }

    final resolvedMarkdownPath = _resolveWikiTarget(
      rawTarget,
      '000-index.md',
      wikiLookup,
    );

    if (resolvedMarkdownPath == null) {
      stderr.writeln(
        'Warning: could not resolve featured card target "[[$rawTarget]]" in 000-index.md',
      );
      continue;
    }

    final targetHtmlFullPath = _join(
      outputDirPath,
      resolvedMarkdownPath.toLowerCase() == '000-index.md'
          ? 'index.html'
          : _markdownPathToHtml(resolvedMarkdownPath),
    );

    cards.add(
      FeaturedCardInfo(
        href: _encodeUrlPath(
          _relativePath(
            fromDirectory: outputDirPath,
            toFile: targetHtmlFullPath,
          ),
        ),
        title: title,
        summaryHtml: md.markdownToHtml(
          _replaceHtmlImageSources(
            markdownText: _replaceWikiLinks(
              markdownText: summary,
              currentMarkdownRelativePath: '000-index.md',
              currentOutputDir: outputDirPath,
              outputDirPath: outputDirPath,
              pageByMarkdownPath: pageByMarkdownPath,
              wikiLookup: wikiLookup,
              assetLookup: assetLookup,
              inputDirPath: inputDirPath,
            ),
            currentMarkdownRelativePath: '000-index.md',
            currentOutputDir: outputDirPath,
            outputDirPath: outputDirPath,
            assetLookup: assetLookup,
            inputDirPath: inputDirPath,
          ),
          extensionSet: md.ExtensionSet.gitHubWeb,
        ),
      ).toTemplateData(),
    );
  }

  return cards;
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

        final altText =
            rawLabel ?? _basenameWithoutExtension(resolvedAssetPath);
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
  return path.split('/').map(Uri.encodeComponent).join('/');
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
    r'''<img\b[^>]*\bsrc\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))[^>]*>''',
    caseSensitive: false,
  );

  return markdownText.replaceAllMapped(imageTagPattern, (match) {
    final rawSource = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
        .trim();
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
  final withoutExtension = name.replaceFirst(
    RegExp(r'\.md$', caseSensitive: false),
    '',
  );

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

String _relativePath({required String fromDirectory, required String toFile}) {
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

class IndexSections {
  const IndexSections({
    required this.visibleMarkdown,
    this.featuredMarkdown,
    this.sidebarMarkdown,
  });

  final String visibleMarkdown;
  final String? featuredMarkdown;
  final String? sidebarMarkdown;
}

class FeaturedCardInfo {
  const FeaturedCardInfo({
    required this.href,
    required this.title,
    required this.summaryHtml,
  });

  final String href;
  final String title;
  final String summaryHtml;

  Map<String, Object> toTemplateData() => {
    'href': href,
    'title': title,
    'summaryHtml': summaryHtml,
  };
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
  final faviconPattern = RegExp(
    r'^favicon-(\d+x\d+)\.png$',
    caseSensitive: false,
  );
  final favicons = <FaviconAsset>[];

  for (final path in relativePaths) {
    final normalized = _normalizeRelativePath(path);
    final basename = normalized.split('/').last;
    final match = faviconPattern.firstMatch(basename);
    if (match == null) {
      continue;
    }

    favicons.add(FaviconAsset(path: normalized, sizes: match.group(1)!));
  }

  favicons.sort((a, b) => a.path.compareTo(b.path));
  return favicons;
}

class FaviconAsset {
  final String path;
  final String sizes;

  const FaviconAsset({required this.path, required this.sizes});
}

class Markdown2HtmlConfig {
  final String? logo;
  final String? logoAlt;
  final String? css;
  final bool favicons;
  final String? sidebarTitle;
  final String? footer;
  final TopNavConfig? topNav;

  const Markdown2HtmlConfig({
    this.logo = 'logo.webp',
    this.logoAlt = 'Site logo',
    this.css = 'site.css',
    this.favicons = true,
    this.sidebarTitle = 'Your site',
    this.footer = '999-footer.md',
    this.topNav = const TopNavConfig(),
  });

  factory Markdown2HtmlConfig.fromJson(Map<String, dynamic> json) {
    return Markdown2HtmlConfig(
      logo: _readNullableString(json, 'logo', fallback: 'logo.webp'),
      logoAlt: _readNullableString(json, 'logoAlt', fallback: 'Site logo'),
      css: _readNullableString(json, 'css', fallback: 'site.css'),
      favicons: _readBool(json, 'favicons', fallback: true),
      sidebarTitle: _readNullableString(
        json,
        'sidebarTitle',
        fallback: 'Your site',
      ),
      footer: _readNullableString(json, 'footer', fallback: '999-footer.md'),
      topNav: _readTopNavConfig(
        json,
        'top-nav',
        fallback: const TopNavConfig(),
      ),
    );
  }
}

class TopNavConfig {
  final String url;
  final String title;

  const TopNavConfig({this.url = '/', this.title = 'Home'});
}

TopNavConfig? _readTopNavConfig(
  Map<String, dynamic> json,
  String key, {
  TopNavConfig? fallback,
}) {
  if (!json.containsKey(key)) {
    return fallback;
  }

  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is! Map<String, dynamic>) {
    throw FormatException('Config value "$key" must be an object or null.');
  }

  final url = _readNullableString(value, 'url');
  final title = _readNullableString(value, 'title');

  if (url == null || title == null) {
    throw FormatException(
      'Config value "$key" must include non-empty string values for "url" and "title".',
    );
  }

  return TopNavConfig(url: url, title: title);
}

String? _readNullableString(
  Map<String, dynamic> json,
  String key, {
  String? fallback,
}) {
  if (!json.containsKey(key)) {
    return fallback;
  }

  final value = json[key];
  if (value == null) {
    return null;
  }
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  throw FormatException('Config value "$key" must be a string or null.');
}

bool _readBool(
  Map<String, dynamic> json,
  String key, {
  required bool fallback,
}) {
  if (!json.containsKey(key)) {
    return fallback;
  }

  final value = json[key];
  if (value is bool) {
    return value;
  }

  throw FormatException('Config value "$key" must be a boolean.');
}

String stripHtml(String input) {
  final document = html_parser.parse(input);
  return document.body?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';
}
