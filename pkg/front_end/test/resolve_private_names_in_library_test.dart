// [selfhost] Tests CompilerOptions.resolvePrivateNamesInLibrary, the option
// Route B uses so generated code can see the private names of the application
// library it replaces a member in.
//
// Usage: dart resolve_private_names_in_library_test.dart [path/to/vm_platform.dill]
// The platform dill defaults to the one next to the running dart executable.

import 'dart:io';

import 'package:front_end/src/api_prototype/compiler_options.dart';
import 'package:front_end/src/api_unstable/vm.dart' show CfeSeverity;
import 'package:front_end/src/api_prototype/kernel_generator.dart';
import 'package:front_end/src/api_prototype/memory_file_system.dart';
import 'package:front_end/src/base/hybrid_file_system.dart';
import 'package:kernel/binary/ast_to_binary.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/target/targets.dart';
import 'package:vm/modular/target/vm.dart' show VmTarget;

final Uri base = Uri.parse('org-dartlang-test:///');
final Uri appUri = base.resolve('app.dart');
final Uri genUri = base.resolve('gen.dart');

int failures = 0;

void expect(bool condition, String what) {
  if (!condition) {
    failures++;
    stderr.writeln('FAIL: $what');
  } else {
    print('ok: $what');
  }
}

Future<void> main(List<String> args) async {
  final Uri platform = Uri.file(
    args.isNotEmpty
        ? args.first
        : '${File(Platform.resolvedExecutable).parent.path}/vm_platform.dill',
  );
  final fs = MemoryFileSystem(base);
  fs
      .entityForUri(appUri)
      .writeAsStringSync('int _secret() => 42;\nvoid main() {}\n');
  // Not a part of app.dart: only sees app.dart's privates through the option.
  fs
      .entityForUri(genUri)
      .writeAsStringSync("int f() => _secret();\nvoid main() {}\n");

  CompilerOptions options({Uri? resolveIn, List<Uri> dills = const []}) =>
      CompilerOptions()
        ..sdkSummary = platform
        ..fileSystem = HybridFileSystem(fs)
        ..environmentDefines = const {}
        ..target = VmTarget(TargetFlags())
        ..additionalDillModules = dills
        ..resolvePrivateNamesInLibrary = resolveIn
        ..onDiagnostic = (CfeDiagnosticMessage m) {};

  // Compile app.dart on its own and write it out as a dill the second compile
  // can import.
  final appResult = await kernelForProgram(appUri, options());
  expect(appResult?.component != null, 'app.dart compiles');
  final component = appResult!.component!;
  final dillUri = base.resolve('app.dill');
  final sink = BytesSink();
  BinaryPrinter(
    sink,
    libraryFilter: (Library l) => !l.importUri.isScheme('dart'),
  ).writeComponentFile(component);
  fs.entityForUri(dillUri).writeAsBytesSync(sink.builder.takeBytes());

  Future<List<String>> errorsFor(CompilerOptions o) async {
    final errors = <String>[];
    o.onDiagnostic = (CfeDiagnosticMessage m) {
      if (m.severity == CfeSeverity.error) {
        errors.addAll(m.plainTextFormatted);
      }
    };
    await kernelForProgram(genUri, o);
    return errors;
  }

  // Control: without the option a library cannot see another library's private.
  var errors = await errorsFor(options(dills: [dillUri]));
  expect(
    errors.any((e) => e.contains('_secret')),
    'without the option, _secret is not found',
  );

  // With the option naming app.dart, _secret resolves.
  errors = await errorsFor(options(resolveIn: appUri, dills: [dillUri]));
  expect(errors.isEmpty, 'with the option, _secret resolves ($errors)');

  // A platform library may not be the target.
  Object? thrown;
  try {
    await errorsFor(
      options(resolveIn: Uri.parse('dart:core'), dills: [dillUri]),
    );
  } catch (e) {
    thrown = e;
  }
  expect(
    '$thrown'.contains('is a platform library'),
    'dart:core is refused as the target ($thrown)',
  );

  // A library that is not supplied fails loudly rather than narrowing.
  thrown = null;
  try {
    await errorsFor(options(resolveIn: base.resolve('missing.dart')));
  } catch (e) {
    thrown = e;
  }
  expect(
    '$thrown'.contains('no such library'),
    'an unsupplied library is an error ($thrown)',
  );

  if (failures > 0) exit(1);
  print('all passed');
}
