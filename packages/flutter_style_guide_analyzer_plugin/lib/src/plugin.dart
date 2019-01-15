import 'dart:async';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/file_system/file_system.dart';
// ignore: implementation_imports
import 'package:analyzer/src/context/builder.dart';
// ignore: implementation_imports
import 'package:analyzer/src/context/context_root.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer_plugin/plugin/plugin.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart' as plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart' as plugin;

import 'checker.dart';

class FlutterStyleGuidePlugin extends ServerPlugin {
  final Checker checker = new Checker();

  FlutterStyleGuidePlugin(ResourceProvider provider) : super(provider);

  @override
  AnalysisDriverGeneric createAnalysisDriver(plugin.ContextRoot contextRoot) {
    final root = ContextRoot(contextRoot.root, contextRoot.exclude,
        pathContext: resourceProvider.pathContext)
      ..optionsFilePath = contextRoot.optionsFile;
    final contextBuilder = ContextBuilder(resourceProvider, sdkManager, null)
      ..analysisDriverScheduler = analysisDriverScheduler
      ..byteStore = byteStore
      ..performanceLog = performanceLog
      ..fileContentOverlay = fileContentOverlay;
    final dartDriver = contextBuilder.buildDriver(root);
    dartDriver.results.listen((result) async {
      final path = result.path;
      final unit = result.unit ??
          (await dartDriver.getUnitElement(path)).element.computeNode();
      _processResult(path, unit);
    });
    return dartDriver;
  }

  @override
  List<String> get fileGlobsToAnalyze => const ['*.dart'];

  @override
  String get name => 'Flutter style guide plugin';

  // This is the protocol version, not the plugin version. It must match the
  // version of the `analyzer_plugin` package.
  @override
  String get version => '1.0.0-alpha.0';

  @override
  String get contactInfo => 'https://github.com/flutter/flutter/issues';

  /// Computes errors based on an analysis result and notifies the analyzer.
  void _processResult(String path, CompilationUnit unit) {
    try {
      final checkResult = checker.check(unit);
      channel.sendNotification(
          plugin.AnalysisErrorsParams(path, checkResult.keys.toList())
              .toNotification());
    } catch (e, stackTrace) {
      // Notify the analyzer that an exception happened.
      channel.sendNotification(
          plugin.PluginErrorParams(false, e.toString(), stackTrace.toString())
              .toNotification());
    }
  }

  @override
  void contentChanged(String path) {
    super.driverForPath(path).addFile(path);
  }

  @override
  Future<plugin.EditGetFixesResult> handleEditGetFixes(
      plugin.EditGetFixesParams parameters) async {
    try {
      final analysisResult =
          await (driverForPath(parameters.file) as AnalysisDriver)
              .getResult(parameters.file);

      // Get errors and fixes for the file.
      final checkResult = checker.check(analysisResult.unit);

      // Return any fixes that are for the expected file.
      final fixes = <plugin.AnalysisErrorFixes>[];
      for (final error in checkResult.keys) {
        if (error.location.file == parameters.file &&
            checkResult[error].change.edits.single.edits.isNotEmpty) {
          fixes.add(new plugin.AnalysisErrorFixes(error,
              fixes: [checkResult[error]]));
        }
      }

      return new plugin.EditGetFixesResult(fixes);
    } catch (e, stackTrace) {
      // Notify the analyzer that an exception happened.
      channel.sendNotification(new plugin.PluginErrorParams(
              false, e.toString(), stackTrace.toString())
          .toNotification());
      return new plugin.EditGetFixesResult([]);
    }
  }
}
