// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Emits the Mutable-AOT identity manifest for a kernel binary (MAOT-1, #65).
///
/// The manifest is the machine-readable statement of the name space a release
/// was compiled against. A patch compiler proves it is addressing the same
/// program by deriving the same ids from its own compilation -- never by
/// reading anything back out of a compiled artifact.
///
/// Usage:
///   dart pkg/vm/bin/maot_identity_manifest.dart \
///       --dill out.dill [--app-root <uri>] [--include-sdk] -o manifest.json
///
/// By default only non-`dart:` libraries are emitted: the SDK's name space is
/// fixed by the release and enumerating it would bury the program's own
/// declarations in tens of thousands of rows. `--include-sdk` is available for
/// the cases that need it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/maot_identity.dart';

const String manifestSchema = 'maot.identity.manifest/1';

class _Entry {
  final String id;
  final String kind;
  final String stability;
  final String? caveat;
  _Entry(this.id, this.kind, this.stability, this.caveat);

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind,
        'stability': stability,
        if (caveat != null) 'caveat': caveat,
      };
}

void main(List<String> args) {
  String? dillPath;
  String? outPath;
  Uri? appRoot;
  var includeSdk = false;

  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--dill') {
      dillPath = args[++i];
    } else if (a == '-o' || a == '--output') {
      outPath = args[++i];
    } else if (a == '--app-root') {
      appRoot = Uri.directory(args[++i]);
    } else if (a == '--include-sdk') {
      includeSdk = true;
    } else if (a == '-h' || a == '--help') {
      stdout.writeln(
          'usage: maot_identity_manifest.dart --dill <file> [--app-root <dir>] '
          '[--include-sdk] -o <manifest.json>');
      exit(0);
    }
  }

  if (dillPath == null || outPath == null) {
    stderr.writeln('--dill and -o are required');
    exit(2);
  }

  final component = loadComponentFromBinary(dillPath);
  final identity = MaotIdentity(appRoot: appRoot);
  final entries = <_Entry>[];
  final errors = <String>[];

  void add(MaotId id, String kind) {
    entries.add(_Entry(id.id, kind, id.stability.name, id.caveat));
  }

  void addTypeParameters(String ownerId, List<TypeParameter> params) {
    for (var i = 0; i < params.length; i++) {
      add(identity.typeParameterId(ownerId, params[i], i), 'type_parameter');
    }
  }

  for (final library in component.libraries) {
    if (!includeSdk && library.importUri.scheme == 'dart') continue;
    try {
      final libId = identity.libraryId(library);
      add(libId, 'library');

      for (final td in library.typedefs) {
        final id = identity.typedefId(td);
        add(id, 'typedef');
        addTypeParameters(id.id, td.typeParameters);
      }

      for (final member in library.members) {
        final id = identity.memberId(member);
        add(id, _memberKind(member));
        final fn = member.function;
        if (fn != null) addTypeParameters(id.id, fn.typeParameters);
      }

      for (final cls in library.classes) {
        final clsId = identity.classId(cls);
        add(clsId, cls.isEnum
            ? 'enum'
            : cls.isMixinDeclaration
                ? 'mixin'
                : 'class');
        addTypeParameters(clsId.id, cls.typeParameters);
        for (final member in cls.members) {
          final id = identity.memberId(member);
          add(id, _memberKind(member));
          final fn = member.function;
          if (fn != null) addTypeParameters(id.id, fn.typeParameters);
        }
      }

      for (final ext in library.extensions) {
        final id = identity.extensionId(ext);
        add(id, 'extension');
        addTypeParameters(id.id, ext.typeParameters);
      }

      for (final etd in library.extensionTypeDeclarations) {
        final id = identity.extensionTypeId(etd);
        add(id, 'extension_type');
        addTypeParameters(id.id, etd.typeParameters);
      }
    } on MaotIdentityError catch (e) {
      // Recorded, never swallowed. A library the scheme cannot name
      // reproducibly must be visible as a refusal, because the alternative is
      // a manifest that silently describes less than the program.
      errors.add('${library.importUri}: ${e.message}');
    }
  }

  entries.sort((a, b) => a.id.compareTo(b.id));

  final ids = entries.map((e) => e.id).toList(growable: false);
  final duplicates = <String>{};
  for (var i = 1; i < ids.length; i++) {
    if (ids[i] == ids[i - 1]) duplicates.add(ids[i]);
  }

  final byStability = <String, int>{};
  for (final e in entries) {
    byStability[e.stability] = (byStability[e.stability] ?? 0) + 1;
  }

  final manifest = <String, Object?>{
    'schema': manifestSchema,
    'identity_scheme': MaotIdentity.schema,
    'generated_by': 'pkg/vm/bin/maot_identity_manifest.dart',
    'dart_version': Platform.version,
    'app_root_supplied': appRoot != null,
    'include_sdk': includeSdk,
    'total': entries.length,
    'by_kind': _countBy(entries, (e) => e.kind),
    'by_stability': byStability,
    // A duplicate id means two distinct declarations received one identity --
    // a patch binding to either would be binding to the wrong one. It is a
    // hard failure, never a warning.
    'duplicate_ids': duplicates.toList()..sort(),
    'refusals': errors,
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  File(outPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(manifest) + '\n');

  stdout.writeln('entries    ${entries.length}');
  stdout.writeln('duplicates ${duplicates.length}');
  stdout.writeln('refusals   ${errors.length}');
  for (final e in errors) {
    stderr.writeln('REFUSED $e');
  }
  if (duplicates.isNotEmpty) {
    for (final d in duplicates) {
      stderr.writeln('DUPLICATE $d');
    }
    exit(1);
  }
  if (errors.isNotEmpty) exit(1);
}

String _memberKind(Member m) {
  if (m is Field) return 'field';
  if (m is Constructor) return 'constructor';
  if (m is Procedure) {
    switch (m.kind) {
      case ProcedureKind.Method:
        return m.enclosingClass == null ? 'function' : 'method';
      case ProcedureKind.Getter:
        return 'getter';
      case ProcedureKind.Setter:
        return 'setter';
      case ProcedureKind.Operator:
        return 'operator';
      case ProcedureKind.Factory:
        return 'factory';
    }
  }
  return 'unknown';
}

Map<String, int> _countBy(List<_Entry> entries, String Function(_Entry) key) {
  final out = <String, int>{};
  for (final e in entries) {
    final k = key(e);
    out[k] = (out[k] ?? 0) + 1;
  }
  return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}
