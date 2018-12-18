import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:analyzer/src/context/builder.dart';
import 'package:analyzer/src/context/context_root.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/file_state.dart';
import 'package:analyzer/src/dart/analysis/performance_logger.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer_plugin/plugin/plugin.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;
import 'package:analyzer_plugin/utilities/analyzer_converter.dart';
import 'package:logging/logging.dart';

final _log = Logger('plugin');

class FlutterStyleGuidePlugin extends ServerPlugin {
  FlutterStyleGuidePlugin(ResourceProvider provider) : super(provider) {
    Logger.root.level = Level.FINE;
    final file = io.File(
        '/home/aar-dw/perso/dev/dart/flutter/flutter/test_style_guide/plugin.log');
    Logger.root.onRecord.listen((rec) => file.writeAsStringSync(
        '${rec.level.name} ${rec.time} ${rec.loggerName} : ${rec.message}\n',
        mode: io.FileMode.append,
        flush: true));
  }

  @override
  List<String> get fileGlobsToAnalyze => <String>['**/*.dart'];

  @override
  String get name => 'Flutter style guide plugin';

  @override
  String get version => '1.0.0';

  @override
  AnalysisDriverGeneric createAnalysisDriver(plugin.ContextRoot contextRoot) {
    final ContextRoot root = ContextRoot(contextRoot.root, contextRoot.exclude,
        pathContext: resourceProvider.pathContext)
      ..optionsFilePath = contextRoot.optionsFile;

    final PerformanceLog logger = PerformanceLog(StringBuffer());
    final ContextBuilder builder =
        ContextBuilder(resourceProvider, sdkManager, null)
          ..analysisDriverScheduler = (AnalysisDriverScheduler(logger)..start())
          ..byteStore = byteStore
          ..performanceLog = logger
          ..fileContentOverlay = fileContentOverlay;

    final AnalysisDriver dartDriver = builder.buildDriver(root)
      ..results.listen((_) {}) // Consume the stream, otherwise we leak.
      ..exceptions.listen((_) {}); // Consume the stream, otherwise we leak.

    final Driver driver = Driver(
      resourceProvider,
      dartDriver,
      analysisDriverScheduler,
      fileContentOverlay,
    );
    driver.resultsStream
        .forEach((Result result) => _handleResultErrors(result, driver));
    return driver;
  }

  @override
  void contentChanged(String path) {
    final driver = driverForPath(path);
    if (driver is Driver) {
      driver..addFile(path)..dartDriver.addFile(path);
    }
  }

  /// Send notifications for errors for this result
  void _handleResultErrors(Result result, Driver driver) {
    final AnalyzerConverter converter = AnalyzerConverter();
    final LineInfo lineInfo =
        LineInfo.fromContent(driver.getFileContent(result.filename));
    final List<plugin.AnalysisError> errors = converter.convertAnalysisErrors(
      result.errors,
      lineInfo: lineInfo,
    );
    final notif =
        plugin.AnalysisErrorsParams(result.filename, errors).toNotification();
    channel.sendNotification(notif);
  }
}

class Driver implements AnalysisDriverGeneric {
  Driver(
    this._resourceProvider,
    this.dartDriver,
    this._scheduler,
    this.contentOverlay,
  ) {
    _scheduler.add(this);
  }

  final ResourceProvider _resourceProvider;
  final AnalysisDriver dartDriver;
  final AnalysisDriverScheduler _scheduler;
  final FileContentOverlay contentOverlay;

  final LinkedHashSet<String> _dartFiles = LinkedHashSet<String>();
  final StreamController<Result> resultsController = StreamController<Result>();

  @override
  void addFile(String path) {
    if (path.endsWith('.dart')) {
      _dartFiles.add(path);
      _scheduler.notify(this);
    }
  }

  @override
  void dispose() {
    resultsController.close();
  }

  @override
  bool get hasFilesToAnalyze => _dartFiles.isNotEmpty;

  @override
  Future<Null> performWork() async {
    if (_dartFiles.isNotEmpty) {
      final dartFiles = _dartFiles.toList();
      _dartFiles.clear();
      for (final path in dartFiles) {
        _analyze(path);
      }
    }
  }

  @override
  set priorityFiles(List<String> priorityPaths) {}

  @override
  AnalysisDriverPriority get workPriority {
    if (_dartFiles.isNotEmpty) {
      return AnalysisDriverPriority.interactive;
    }
    return AnalysisDriverPriority.nothing;
  }

  Stream<Result> get resultsStream => resultsController.stream;

  String getFileContent(String path) =>
      contentOverlay[path] ??
      ((Source source) =>
          source.exists() ? source.contents.data : '')(getSource(path));

  Source getSource(String path) =>
      _resourceProvider.getFile(path).createSource();

  Future<void> _analyze(String path) async {
    final source = getSource(path);
    final unit = await dartDriver.getUnitElement(path);
    // final result = await dartDriver.getResult(path);
    if (unit.element == null) return;

    final analysisErrors = <AnalysisError>[];
    final addError = (int offset, int length, StyleCode errorCode) {
      analysisErrors.add(AnalysisError(source, offset, length, errorCode));
      resultsController.add(Result(path, analysisErrors));
    };

    List<AstVisitor<void>> visitors = [
      EOFVisitor(addError),
      SeeAlsoDartdocVisitor(addError),
      StartWithSpaceDartdocVisitor(addError),
    ];
    try {
      for (final visitor in visitors) {
        visitor.visitCompilationUnit(unit.element.computeNode());
      }
    } catch (e, s) {
      _log.info('error:$e,$s');
    }
    resultsController.add(Result(path, analysisErrors));
  }
}

class EOFVisitor extends SimpleAstVisitor<void> {
  EOFVisitor(this.addError);

  final void Function(int offset, int length, StyleCode errorCode) addError;

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final lineInfo = node.lineInfo;
    final lineCount = lineInfo.lineCount;
    final lastLineStart = lineInfo.getOffsetOfLine(lineCount - 1);
    if (node.end - lastLineStart > 0) {
      addError(
        lastLineStart,
        node.end - lastLineStart,
        StyleCode('eof', 'File should end with an empty line'),
      );
    }
  }
}

class SeeAlsoDartdocVisitor extends RecursiveAstVisitor<void> {
  SeeAlsoDartdocVisitor(this.addError);

  final void Function(int offset, int length, StyleCode errorCode) addError;

  @override
  void visitComment(Comment node) {
    if (node == null) {
      return;
    }
    final linesStartingFromSeeAlso =
        node.tokens.skipWhile((e) => e.lexeme != '/// See also:').toList();
    if (linesStartingFromSeeAlso.isEmpty) {
      return;
    }
    final seeAlsoToken = linesStartingFromSeeAlso.first;
    if (linesStartingFromSeeAlso.length == 1) {
      addError(
        seeAlsoToken.offset,
        seeAlsoToken.length,
        StyleCode(
            'dartdoc.seealso.list.empty', 'See also list should not be empty.'),
      );
    }
    if (linesStartingFromSeeAlso.skip(1).first.lexeme != '///') {
      addError(
        seeAlsoToken.offset,
        seeAlsoToken.length,
        StyleCode('dartdoc.seealso.blank',
            'There should be a blank line between "See also:" and the first item in the bulleted list.'),
      );
      return;
    }
    final lines = linesStartingFromSeeAlso.skip(2).fold(<List<Token>>[],
        (List<List<Token>> previousValue, element) {
      if (element.lexeme.startsWith(RegExp(r'///  \* '))) {
        previousValue.add(<Token>[element]);
      } else if (previousValue.isEmpty) {
        addError(
          element.offset,
          element.length,
          StyleCode('dartdoc.seealso.list.invalid',
              'Only list can be put in see also section.'),
        );
      } else if (element.lexeme.startsWith(RegExp(r'///    '))) {
        previousValue.last.add(element);
      } else if (element.lexeme == '/// {@endtemplate}') {
        // OK to have {@endtemplate} at the end
      } else {
        addError(
          element.offset,
          element.length,
          StyleCode('dartdoc.seealso.list.invalid',
              'Only list can be put in see also section.'),
        );
      }
      return previousValue;
    });
    for (final lineTokens in lines) {
      final line = ([lineTokens.first.lexeme.substring('///  * '.length)]
            ..addAll(lineTokens
                .skip(1)
                .map((e) => e.lexeme.substring('///    '.length))))
          .join(' ');
      if (lineTokens.length == 1 &&
          line.startsWith('<') &&
          line.endsWith('>') &&
          !line.substring(1, line.length - 1).contains('>')) {
        continue;
      }
      if (lineTokens.length == 1 &&
          line.startsWith('[') &&
          line.endsWith(']') &&
          !line.substring(1, line.length - 1).contains(']')) {
        continue;
      }
      if (!line.endsWith('.')) {
        addError(
          lineTokens.last.offset,
          lineTokens.last.length,
          StyleCode('dartdoc.seseealsoe.list.end',
              'Each line should end with a period.'),
        );
      }
    }
  }
}

class StartWithSpaceDartdocVisitor extends DartdocVisitor {
  StartWithSpaceDartdocVisitor(this.addError);

  final void Function(int offset, int length, StyleCode errorCode) addError;

  void checkComment(Comment comment) {
    if (comment == null) {
      return;
    }
    for (final token in comment.tokens) {
      if (token.lexeme != '///' && !token.lexeme.startsWith('/// ')) {
        addError(
          token.offset,
          token.length,
          StyleCode('dartdoc.space',
              'Documentation comments should start with "/// "'),
        );
      }
    }
  }
}

abstract class DartdocVisitor extends RecursiveAstVisitor<void> {
  void checkComment(Comment comment);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitClassTypeAlias(ClassTypeAlias node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitFunctionTypeAlias(FunctionTypeAlias node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitLibraryDirective(LibraryDirective node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    checkComment(node.documentationComment);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    checkComment(node.documentationComment);
  }
}

class StyleCode extends ErrorCode {
  const StyleCode(String name, String message, {String correction})
      : super.temporary(name, message, correction: correction);

  @override
  ErrorSeverity get errorSeverity => ErrorSeverity.INFO;

  @override
  ErrorType get type => ErrorType.LINT;

  @override
  String get uniqueName => 'FmtCode.$name';
}

class Result {
  Result(this.filename, this.errors);

  final String filename;
  final List<AnalysisError> errors;
}
