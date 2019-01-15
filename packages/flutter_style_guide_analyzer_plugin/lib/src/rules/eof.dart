import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:flutter_style_guide_analyzer_plugin/src/checker.dart';

class EOFRule extends Rule {
  EOFRule(ErrorReporter addError) : super('eof', addError);

  @override
  void visitCompilationUnit(CompilationUnit node) {
    final lineInfo = node.lineInfo;
    final lineCount = lineInfo.lineCount;
    final lastLineStart = lineInfo.getOffsetOfLine(lineCount - 1);
    if (node.end - lastLineStart > 0) {
      final offset = lastLineStart;
      final length = node.end - lastLineStart;
      addError(
        'File should end with an empty line',
        offset,
        length,
        'Add an empty line at the end of file',
        [SourceEdit(offset + length, 0, '\n')],
      );
    }
  }
}
