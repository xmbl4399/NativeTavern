import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:native_tavern/data/models/character.dart';
import 'package:native_tavern/data/models/world_info.dart';
import 'package:native_tavern/data/repositories/world_info_repository.dart';
import 'package:native_tavern/domain/services/import_service.dart';
import 'package:native_tavern/domain/services/url_import_service.dart';
import 'package:native_tavern/presentation/providers/character_providers.dart';
import 'package:native_tavern/presentation/theme/app_theme.dart';
import 'package:native_tavern/l10n/generated/app_localizations.dart';
import 'dart:convert';
import 'package:native_tavern/domain/services/llm_service.dart';
import 'package:native_tavern/presentation/providers/settings_providers.dart';

/// Import service provider
final importServiceProvider = Provider<ImportService>((ref) {
  throw UnimplementedError('Must be overridden in ProviderScope');
});

/// URL import service provider
final urlImportServiceProvider = Provider<UrlImportService>((ref) {
  final importService = ref.watch(importServiceProvider);
  return UrlImportService(importService);
});

/// Import result for a single file or URL
class ImportResult {
  final String fileName;
  final String filePath;
  final Character? character;
  final String? error;
  final bool isProcessing;
  final UrlSource? urlSource;

  const ImportResult({
    required this.fileName,
    required this.filePath,
    this.character,
    this.error,
    this.isProcessing = false,
    this.urlSource,
  });

  ImportResult copyWith({
    Character? character,
    String? error,
    bool? isProcessing,
    UrlSource? urlSource,
  }) {
    return ImportResult(
      fileName: fileName,
      filePath: filePath,
      character: character ?? this.character,
      error: error,
      isProcessing: isProcessing ?? this.isProcessing,
      urlSource: urlSource ?? this.urlSource,
    );
  }
}

/// Import state
class ImportState {
  final bool isLoading;
  final String? error;
  final List<ImportResult> results;
  final int totalFiles;
  final int processedFiles;

  const ImportState({
    this.isLoading = false,
    this.error,
    this.results = const [],
    this.totalFiles = 0,
    this.processedFiles = 0,
  });

  bool get hasResults => results.isNotEmpty;
  int get successCount => results.where((r) => r.character != null).length;
  int get errorCount => results.where((r) => r.error != null).length;

  ImportState copyWith({
    bool? isLoading,
    String? error,
    List<ImportResult>? results,
    int? totalFiles,
    int? processedFiles,
  }) {
    return ImportState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      results: results ?? this.results,
      totalFiles: totalFiles ?? this.totalFiles,
      processedFiles: processedFiles ?? this.processedFiles,
    );
  }
}

/// Import state notifier
class ImportNotifier extends StateNotifier<ImportState> {
  final ImportService _importService;
  final UrlImportService _urlImportService;
  final ImagePicker _imagePicker = ImagePicker();

  ImportNotifier(this._importService, this._urlImportService) : super(const ImportState());

  Future<void> pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'charx', 'json'],
        allowMultiple: true, // Enable batch import
      );

      if (result != null && result.files.isNotEmpty) {
        await loadFiles(result.files.where((f) => f.path != null).map((f) => f.path!).toList());
      }
    } catch (e) {
      state = state.copyWith(error: 'Failed to pick file: $e');
    }
  }

  /// Pick character card image from photo gallery (for mobile)
  Future<void> pickFromGallery() async {
    try {
      state = state.copyWith(isLoading: true, error: null);
      
      final List<XFile> images = await _imagePicker.pickMultiImage(
        maxWidth: 4096,
        maxHeight: 4096,
      );

      if (images.isNotEmpty) {
        await loadFiles(images.map((img) => img.path).toList());
      } else {
        state = state.copyWith(isLoading: false);
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to pick from gallery: $e',
      );
    }
  }

  Future<void> loadFiles(List<String> paths) async {
    if (paths.isEmpty) return;

    // Initialize results with all file paths
    final results = paths.map((path) {
      final fileName = path.split('/').last;
      return ImportResult(
        fileName: fileName,
        filePath: path,
        isProcessing: true,
      );
    }).toList();

    state = state.copyWith(
      isLoading: true,
      error: null,
      results: results,
      totalFiles: paths.length,
      processedFiles: 0,
    );

    // Process each file
    for (int i = 0; i < paths.length; i++) {
      final path = paths[i];
      try {
        final extension = path.split('.').last.toLowerCase();
        Character? character;

        switch (extension) {
          case 'png':
            character = await _importService.importFromPng(path);
            break;
          case 'charx':
            character = await _importService.importFromCharX(path);
            break;
          case 'json':
            final file = File(path);
            final json = await file.readAsString();
            character = await _importService.importFromJson(json);
            break;
          default:
            throw Exception('Unsupported file format: $extension');
        }

        // Update result with character
        final updatedResults = List<ImportResult>.from(state.results);
        updatedResults[i] = updatedResults[i].copyWith(
          character: character,
          isProcessing: false,
        );

        state = state.copyWith(
          results: updatedResults,
          processedFiles: i + 1,
        );
      } catch (e) {
        // Update result with error
        final updatedResults = List<ImportResult>.from(state.results);
        updatedResults[i] = updatedResults[i].copyWith(
          error: e.toString(),
          isProcessing: false,
        );

        state = state.copyWith(
          results: updatedResults,
          processedFiles: i + 1,
        );
      }
    }

    state = state.copyWith(isLoading: false);
  }

  Future<void> importFromUrl(String url) async {
    if (url.trim().isEmpty) return;

    final source = _urlImportService.identifySource(url);
    final sourceName = _urlImportService.getSourceDisplayName(source);

    final results = [
      ImportResult(
        fileName: sourceName,
        filePath: url,
        isProcessing: true,
        urlSource: source,
      ),
    ];

    state = state.copyWith(
      isLoading: true,
      error: null,
      results: results,
      totalFiles: 1,
      processedFiles: 0,
    );

    try {
      final result = await _urlImportService.importFromUrl(url);
      final updatedResults = [
        results[0].copyWith(
          character: result.character,
          isProcessing: false,
          urlSource: result.source,
        ),
      ];
      state = state.copyWith(
        results: updatedResults,
        processedFiles: 1,
        isLoading: false,
      );
    } catch (e) {
      final updatedResults = [
        results[0].copyWith(
          error: e.toString(),
          isProcessing: false,
        ),
      ];
      state = state.copyWith(
        results: updatedResults,
        processedFiles: 1,
        isLoading: false,
      );
    }
  }

  void clear() {
    state = const ImportState();
  }
}

/// Import state provider
final importStateProvider =
    StateNotifierProvider<ImportNotifier, ImportState>((ref) {
  final importService = ref.watch(importServiceProvider);
  final urlImportService = ref.watch(urlImportServiceProvider);
  return ImportNotifier(importService, urlImportService);
});

/// Import format enum
enum ImportFormat { png, charx, json }

/// Import screen
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  @override
  void initState() {
    super.initState();
    // Clear previous import state when screen is opened
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(importStateProvider.notifier).clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final importState = ref.watch(importStateProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.importCharacter),
        actions: [
          if (importState.hasResults)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => ref.read(importStateProvider.notifier).clear(),
              tooltip: l10n.clear,
            ),
        ],
      ),
      body: importState.hasResults
          ? _BatchImportResults(
              results: importState.results,
              isLoading: importState.isLoading,
              totalFiles: importState.totalFiles,
              processedFiles: importState.processedFiles,
              onImportAll: () => _importAllCharacters(context, ref),
              onTranslateAndImportAll: () => _translateAndImportCharacters(context, ref),
            )
          : _FilePickerView(
              isLoading: importState.isLoading,
              error: importState.error,
              onPickFile: () => ref.read(importStateProvider.notifier).pickFile(),
              onPickFromGallery: () => ref.read(importStateProvider.notifier).pickFromGallery(),
              onImportUrl: (url) => ref.read(importStateProvider.notifier).importFromUrl(url),
            ),
    );
  }

  Future<void> _translateAndImportCharacters(BuildContext context, WidgetRef ref) async {
    final importState = ref.read(importStateProvider);
    if (!importState.hasResults) return;

    var llmConfig = ref.read(llmConfigProvider);
    final llmService = ref.read(llmServiceProvider);

    // 等待 config 从数据库加载完成（第一次点击时 provider 还是默认的 claude）
    if (llmConfig.provider == LLMProvider.claude && llmConfig.apiKey.isEmpty) {
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        final retry = ref.read(llmConfigProvider);
        if (retry.apiKey.isNotEmpty) {
          llmConfig = retry; // 使用加载后的配置
          break;
        }
      }
      if (llmConfig.apiKey.isEmpty && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('转换失败: 未检测到 API Key，请先在 AI 配置中配置 API'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }
    }

    // Progress tracking
    final progress = ValueNotifier<Map<String, dynamic>>({'p': 0.0, 's': '准备中...', 'e': null});

    void setProg(double p, String s, [String? e]) {
      progress.value = {'p': p, 's': s, 'e': e};
    }

    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 16),
              Text('正在转换中文...'),
            ],
          ),
          content: ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: progress,
            builder: (_, v, __) {
              final p = v['p'] as double;
              final s = v['s'] as String;
              final e = v['e'] as String?;
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: 8),
                LinearProgressIndicator(value: p == 0.0 ? null : p),
                const SizedBox(height: 12),
                Text(s, style: const TextStyle(fontSize: 14)),
                if (e != null) ...[
                  const SizedBox(height: 8),
                  Text(e, style: const TextStyle(color: Colors.red, fontSize: 12)),
                ],
              ]);
            },
          ),
        ),
      );
    }


    int successCount = 0;
    int errorCount = 0;

    /// Batch translate all fields via LLM in one request
    Future<Map<String, String>> _translateFields(Map<String, String> fields) async {
      if (!llmConfig.apiKey.isNotEmpty) {
        debugPrint('⚠️ No API key configured, skipping translation');
        return fields;
      }

      setProg(0.3, '正在调用 LLM 批量翻译...');

      // Build JSON input with all non-empty fields
      final jsonParts = <String>[];
      for (final key in fields.keys) {
        if (fields[key]!.isEmpty) continue;
        final escaped = fields[key]!.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n');
        jsonParts.add('  "' + key + '": "' + escaped + '"');
      }
      final inputJson = '{\n' + jsonParts.join(',\n') + '\n}';

      final msgs = [
        {'role': 'system', 'content': 'You are a translator. Translate character card JSON fields to Simplified Chinese. Keep all HTML tags, markdown, and formatting intact. Output ONLY a valid JSON object with the same keys containing the translated text. Do NOT add any explanations.'},
        {'role': 'user', 'content': 'Translate this character card to Simplified Chinese. Preserve all HTML/markdown/formatting. Return ONLY a JSON object:\n\n' + inputJson},
      ];

      try {
        final resp = await llmService.generateWithReasoning(msgs, llmConfig);
        String raw = resp.content.trim();

        // Extract JSON from response (handle markdown code blocks)
        if (raw.contains('```')) {
          raw = raw.split('```').firstWhere((s) => s.contains('{'), orElse: () => raw);
        }
        final jsonStart = raw.indexOf('{');
        final jsonEnd = raw.lastIndexOf('}');
        if (jsonStart < 0 || jsonEnd <= jsonStart) {
          throw Exception('API returned invalid format (no JSON found)');
        }
        raw = raw.substring(jsonStart, jsonEnd + 1);

        final translated = jsonDecode(raw) as Map<String, dynamic>;
        final result = Map<String, String>.from(fields);
        for (final key in result.keys) {
          if (translated[key] != null) {
            result[key] = translated[key] as String;
          }
        }
        return result;
      } catch (e) {
        debugPrint('❌ LLM batch translation failed: ' + e.toString());
        return fields; // fallback to original
      }
    }

    for (final result in importState.results) {
      if (result.character == null) continue;
      try {
        final orig = result.character!;
        setProg(0, '正在翻译: ' + orig.name);

        final fields = {
          'description': orig.description,
          'personality': orig.personality,
          'scenario': orig.scenario,
          'firstMessage': orig.firstMessage,
          'exampleMessages': orig.exampleMessages,
          'systemPrompt': orig.systemPrompt,
          'postHistoryInstructions': orig.postHistoryInstructions,
        };

        final translated = await _translateFields(fields);

        setProg(0.9, '正在导入...');
        final translatedChar = orig.copyWith(
          description: translated['description'] ?? orig.description,
          personality: translated['personality'] ?? orig.personality,
          scenario: translated['scenario'] ?? orig.scenario,
          firstMessage: translated['firstMessage'] ?? orig.firstMessage,
          exampleMessages: translated['exampleMessages'] ?? orig.exampleMessages,
          systemPrompt: translated['systemPrompt'] ?? orig.systemPrompt,
          postHistoryInstructions: translated['postHistoryInstructions'] ?? orig.postHistoryInstructions,
        );

        await ref.read(characterListProvider.notifier).addCharacter(translatedChar);
        successCount++;
      } catch (e) {
        errorCount++;
        debugPrint('❌ Translation import failed: ' + e.toString());
        setProg(1, '导入失败', e.toString().length > 100 ? e.toString().substring(0, 100) : e.toString());
      }
    }

    setProg(1.0, '完成!');
    await Future.delayed(const Duration(milliseconds: 300));

    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('转换中文导入完成: ' + successCount.toString() + ' 成功, ' + errorCount.toString() + ' 失败'),
          backgroundColor: errorCount > 0 ? Colors.orange : Colors.green,
        ),
      );
      if (successCount > 0) {
        ref.read(importStateProvider.notifier).clear();
        context.pop();
      }
    }
  }

    Future<void> _importAllCharacters(BuildContext context, WidgetRef ref) async {
    final importState = ref.read(importStateProvider);
    if (!importState.hasResults) return;

    final l10n = AppLocalizations.of(context)!;
    int successCount = 0;
    int errorCount = 0;

    for (final result in importState.results) {
      if (result.character == null) continue;

      try {
        // Add the character
        final character = await ref
            .read(characterListProvider.notifier)
            .addCharacter(result.character!);

        // If the character has an embedded lorebook, create a WorldInfo for it
        if (result.character!.characterBook != null &&
            result.character!.characterBook!.entries.isNotEmpty) {
          await _importEmbeddedLorebook(
            ref,
            character.id,
            result.character!.characterBook!,
            result.character!.name,
          );
        }

        successCount++;
      } catch (e) {
        errorCount++;
      }
    }

    if (context.mounted) {
      // Show summary message
      final message = successCount > 0
          ? errorCount > 0
              ? '导入成功 $successCount 个，失败 $errorCount 个'
              : '成功导入 $successCount 个角色卡！'
          : '所有导入都失败了';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: errorCount > 0 ? Colors.orange : Colors.green,
        ),
      );

      // Clear and go back if any successful
      if (successCount > 0) {
        ref.read(importStateProvider.notifier).clear();
        context.pop();
      }
    }
  }

  /// Import embedded lorebook (character_book) as a WorldInfo entry linked to the character
  Future<void> _importEmbeddedLorebook(
    WidgetRef ref,
    String characterId,
    CharacterBook characterBook,
    String characterName,
  ) async {
    final worldInfoRepo = ref.read(worldInfoRepositoryProvider);
    
    // Create a WorldInfo entry linked to this character
    final worldInfoName = characterBook.name ?? '$characterName Lorebook';
    final worldInfo = await worldInfoRepo.createWorldInfo(
      name: worldInfoName,
      description: characterBook.description ?? 'Embedded lorebook from $characterName',
      isGlobal: false,
      characterId: characterId,
    );
    
    // Convert and add all CharacterBookEntry as WorldInfoEntry
    for (final entry in characterBook.entries) {
      // Map CharacterBookEntry position to WorldInfoPosition
      // In character card spec: 0 = before char defs, 1 = after char defs
      WorldInfoPosition position;
      switch (entry.position) {
        case 0:
          position = WorldInfoPosition.before;  // Before Character Definition
          break;
        case 1:
          position = WorldInfoPosition.after;   // After Character Definition
          break;
        default:
          position = WorldInfoPosition.after;
      }
      
      await worldInfoRepo.addEntry(
        worldInfoId: worldInfo.id,
        keys: entry.keys,
        content: entry.content,
        secondaryKeys: entry.secondaryKeys.isNotEmpty ? entry.secondaryKeys : null,
        comment: entry.name.isNotEmpty ? entry.name : entry.comment,
        position: position,
        depth: 4, // Default depth
      );
    }
  }
}

class _FilePickerView extends StatefulWidget {
  final bool isLoading;
  final String? error;
  final VoidCallback onPickFile;
  final VoidCallback onPickFromGallery;
  final ValueChanged<String> onImportUrl;

  const _FilePickerView({
    required this.isLoading,
    required this.error,
    required this.onPickFile,
    required this.onPickFromGallery,
    required this.onImportUrl,
  });

  @override
  State<_FilePickerView> createState() => _FilePickerViewState();
}

class _FilePickerViewState extends State<_FilePickerView> {
  final _urlController = TextEditingController();
  bool _showUrlInput = false;

  bool get _isMobile => Platform.isIOS || Platform.isAndroid;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _handleUrlImport() {
    final url = _urlController.text.trim();
    if (url.isNotEmpty) {
      widget.onImportUrl(url);
    }
  }

  Future<void> _pasteAndImport() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      _urlController.text = data.text!.trim();
      _handleUrlImport();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Local file import section
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(48),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppTheme.darkDivider,
                    width: 2,
                  ),
                ),
                child: Column(
                  children: [
                    if (widget.isLoading)
                      const CircularProgressIndicator()
                    else ...[
                      const Icon(
                        Icons.file_upload_outlined,
                        size: 64,
                        color: AppTheme.textMuted,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '选择角色卡文件',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '支持批量导入 • PNG, CharX, JSON 格式',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                      const SizedBox(height: 24),
                      if (_isMobile) ...[
                        ElevatedButton.icon(
                          onPressed: widget.onPickFromGallery,
                          icon: const Icon(Icons.photo_library),
                          label: Text(AppLocalizations.of(context)!.chooseFromGallery),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(200, 48),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: widget.onPickFile,
                          icon: const Icon(Icons.folder_open),
                          label: Text(AppLocalizations.of(context)!.browseFiles),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(200, 48),
                          ),
                        ),
                      ] else
                        ElevatedButton.icon(
                          onPressed: widget.onPickFile,
                          icon: const Icon(Icons.folder_open),
                          label: Text(AppLocalizations.of(context)!.browseFiles),
                        ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // URL import section
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppTheme.darkCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppTheme.darkDivider,
                    width: 2,
                  ),
                ),
                child: Column(
                  children: [
                    InkWell(
                      onTap: () => setState(() => _showUrlInput = !_showUrlInput),
                      child: Row(
                        children: [
                          const Icon(Icons.link, size: 24, color: AppTheme.accentColor),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '从网址导入',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Icon(
                            _showUrlInput ? Icons.expand_less : Icons.expand_more,
                            color: AppTheme.textMuted,
                          ),
                        ],
                      ),
                    ),
                    if (_showUrlInput) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          hintText: '输入角色卡链接...',
                          hintStyle: const TextStyle(color: AppTheme.textMuted),
                          prefixIcon: const Icon(Icons.link, size: 20),
                          suffixIcon: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.content_paste, size: 20),
                                onPressed: _pasteAndImport,
                                tooltip: '粘贴并导入',
                              ),
                              IconButton(
                                icon: const Icon(Icons.download, size: 20),
                                onPressed: widget.isLoading ? null : _handleUrlImport,
                                tooltip: '导入',
                              ),
                            ],
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                        onSubmitted: (_) => _handleUrlImport(),
                        enabled: !widget.isLoading,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '支持的社区（点击访问）：',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: const [
                          _CommunityChip(name: 'NativeTavern', url: 'https://nativetavern.com', isPrimary: true),
                          _CommunityChip(name: 'Chub.ai', url: 'https://chub.ai/characters'),
                          _CommunityChip(name: 'JanitorAI', url: 'https://janitorai.com'),
                          _CommunityChip(name: 'Pygmalion', url: 'https://pygmalion.chat'),
                          _CommunityChip(name: 'RisuRealm', url: 'https://realm.risuai.net'),
                          _CommunityChip(name: 'AICharacterCards', url: 'https://aicharactercards.com'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '也支持公开的 PNG / JSON 链接',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                    ],
                  ],
                ),
              ),

              if (widget.error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error, color: Colors.red, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 32),
              _buildFormatInfo(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFormatInfo(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)!.supportedFormats,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: AppTheme.accentColor,
              ),
        ),
        const SizedBox(height: 12),
        _FormatTile(
          icon: Icons.image,
          title: AppLocalizations.of(context)!.pngCharacterCard,
          description: AppLocalizations.of(context)!.characterDataEmbeddedInImage,
        ),
        const SizedBox(height: 8),
        _FormatTile(
          icon: Icons.archive,
          title: AppLocalizations.of(context)!.charxArchive,
          description: AppLocalizations.of(context)!.zipArchiveWithCharacterData,
        ),
        const SizedBox(height: 8),
        _FormatTile(
          icon: Icons.code,
          title: AppLocalizations.of(context)!.json,
          description: AppLocalizations.of(context)!.plainCharacterCardJson,
        ),
        const SizedBox(height: 8),
        const _FormatTile(
          icon: Icons.link,
          title: '社区链接',
          description: 'NativeTavern, Chub.ai, JanitorAI, Pygmalion, RisuRealm, AICharacterCards',
        ),
      ],
    );
  }
}

class _FormatTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const _FormatTile({
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.textMuted),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Text(
                description,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textMuted,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CommunityChip extends StatelessWidget {
  final String name;
  final String url;
  final bool isPrimary;

  const _CommunityChip({
    required this.name,
    required this.url,
    this.isPrimary = false,
  });

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(
        isPrimary ? Icons.star : Icons.open_in_new,
        size: 14,
        color: isPrimary ? AppTheme.accentColor : AppTheme.textMuted,
      ),
      label: Text(
        name,
        style: TextStyle(
          fontSize: 12,
          color: isPrimary ? AppTheme.accentColor : null,
          fontWeight: isPrimary ? FontWeight.bold : null,
        ),
      ),
      side: isPrimary
          ? const BorderSide(color: AppTheme.accentColor, width: 1)
          : null,
      onPressed: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
    );
  }
}

class _BatchImportResults extends StatelessWidget {
  final List<ImportResult> results;
  final bool isLoading;
  final int totalFiles;
  final int processedFiles;
  final VoidCallback onImportAll;
  final VoidCallback onTranslateAndImportAll;

  const _BatchImportResults({
    required this.results,
    required this.isLoading,
    required this.totalFiles,
    required this.processedFiles,
    required this.onImportAll,
    required this.onTranslateAndImportAll,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final successCount = results.where((r) => r.character != null).length;
    final errorCount = results.where((r) => r.error != null).length;
    final processingCount = results.where((r) => r.isProcessing).length;

    return Column(
      children: [
        // Progress header
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.darkCard,
          child: Column(
            children: [
              if (isLoading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  '处理中: $processedFiles / $totalFiles',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ] else ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _StatChip(
                      icon: Icons.check_circle,
                      label: '成功',
                      count: successCount,
                      color: Colors.green,
                    ),
                    _StatChip(
                      icon: Icons.error,
                      label: '失败',
                      count: errorCount,
                      color: Colors.red,
                    ),
                    _StatChip(
                      icon: Icons.folder,
                      label: '总计',
                      count: totalFiles,
                      color: AppTheme.accentColor,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (successCount > 0)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: onImportAll,
                      icon: const Icon(Icons.download),
                      label: Text('导入全部 ($successCount 个角色卡)'),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
                if (successCount > 0)
                  const SizedBox(height: 8),
                if (successCount > 0)
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: onTranslateAndImportAll,
                      icon: const Icon(Icons.translate),
                      label: Text('转换中文导入 (' + successCount.toString() + ' 个角色卡)'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),

        // Results list
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final result = results[index];
              return _ImportResultCard(result: result);
            },
          ),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  final Color color;

  const _StatChip({
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 32),
        const SizedBox(height: 4),
        Text(
          '$count',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
        ),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textMuted,
              ),
        ),
      ],
    );
  }
}

class _ImportResultCard extends StatelessWidget {
  final ImportResult result;

  const _ImportResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Status icon
            _buildStatusIcon(),
            const SizedBox(width: 16),
            
            // File info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.character?.name ?? result.fileName,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (result.urlSource != null)
                    Row(
                      children: [
                        const Icon(Icons.link, size: 12, color: AppTheme.textMuted),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            result.fileName,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textMuted,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  else
                    Text(
                      result.fileName,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textMuted,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  // Show embedded lorebook indicator
                  if (result.character?.characterBook != null &&
                      result.character!.characterBook!.entries.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.auto_stories, size: 14, color: AppTheme.accentColor),
                        const SizedBox(width: 4),
                        Text(
                          '${result.character!.characterBook!.entries.length} 条世界书',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.accentColor,
                              ),
                        ),
                      ],
                    ),
                  ],
                  if (result.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      result.error!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.red,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    if (result.isProcessing) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (result.character != null) {
      return const Icon(Icons.check_circle, color: Colors.green, size: 32);
    } else if (result.error != null) {
      return const Icon(Icons.error, color: Colors.red, size: 32);
    } else {
      return const Icon(Icons.help_outline, color: AppTheme.textMuted, size: 32);
    }
  }
}

class _CharacterPreview extends StatelessWidget {
  final Character character;
  final VoidCallback onImport;

  const _CharacterPreview({
    required this.character,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Avatar and basic info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: AppTheme.darkDivider,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: character.assets?.avatarPath != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(character.assets!.avatarPath!),
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Center(
                            child: Icon(
                              Icons.person,
                              size: 48,
                              color: AppTheme.textMuted,
                            ),
                          ),
                  ),
                  const SizedBox(width: 16),
                  // Info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          character.name,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (character.creator.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'by ${character.creator}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: AppTheme.textMuted,
                                ),
                          ),
                        ],
                        if (character.version.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Version: ${character.version}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textMuted,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Tags
          if (character.tags.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context)!.tags,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: AppTheme.accentColor,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: character.tags
                          .map((tag) => Chip(
                                label: Text(tag),
                                visualDensity: VisualDensity.compact,
                              ))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Description
          if (character.description.isNotEmpty)
            _ExpandableSection(
              title: 'Description',
              content: character.description,
            ),

          // Personality
          if (character.personality.isNotEmpty)
            _ExpandableSection(
              title: 'Personality',
              content: character.personality,
            ),

          // Scenario
          if (character.scenario.isNotEmpty)
            _ExpandableSection(
              title: 'Scenario',
              content: character.scenario,
            ),

          // First message
          if (character.firstMessage.isNotEmpty)
            _ExpandableSection(
              title: 'First Message',
              content: character.firstMessage,
            ),

          // Alternate greetings
          if (character.alternateGreetings.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.format_list_bulleted, size: 20, color: AppTheme.accentColor),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.of(context)!.alternateGreetingsCount(character.alternateGreetings.length),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                color: AppTheme.accentColor,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...character.alternateGreetings.asMap().entries.map((e) => Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '${e.key + 1}. ${e.value.length > 100 ? '${e.value.substring(0, 100)}...' : e.value}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                    )),
                  ],
                ),
              ),
            ),

          // Embedded lorebook
          if (character.characterBook != null && character.characterBook!.entries.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_stories, size: 20, color: AppTheme.accentColor),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.of(context)!.embeddedLorebookEntries(character.characterBook!.entries.length),
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                color: AppTheme.accentColor,
                              ),
                        ),
                      ],
                    ),
                    if (character.characterBook!.name != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        character.characterBook!.name!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Text(
                      'Keywords: ${character.characterBook!.entries.expand((e) => e.keys).take(10).join(", ")}${character.characterBook!.entries.expand((e) => e.keys).length > 10 ? "..." : ""}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textMuted,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),

          // Example messages
          if (character.exampleMessages.isNotEmpty)
            _ExpandableSection(
              title: 'Example Messages',
              content: character.exampleMessages,
            ),

          // Import button
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.download),
            label: Text(AppLocalizations.of(context)!.importCharacter),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.all(16),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ExpandableSection extends StatefulWidget {
  final String title;
  final String content;

  const _ExpandableSection({
    required this.title,
    required this.content,
  });

  @override
  State<_ExpandableSection> createState() => _ExpandableSectionState();
}

class _ExpandableSectionState extends State<_ExpandableSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: AppTheme.accentColor,
                        ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppTheme.textMuted,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),
                SelectableText(
                  widget.content,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  widget.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textMuted,
                      ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}