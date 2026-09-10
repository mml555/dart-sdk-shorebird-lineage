// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Emits the Mutable-AOT identity manifest for a kernel binary (MAOT-1, #65).
///
/// The manifest is the machine-readable statement of the name space a release
/// was compiled against. A patch compiler proves it addresses the same program
/// by deriving the same ids from its own compilation -- never by reading
/// anything back out of a compiled artifact.
///
/// # What is in `identity` versus `provenance`
///
/// `identity` is the reproducible part: it must be byte-identical for the same
/// sources compiled anywhere, by anyone, in any directory. Nothing in it may
/// carry a path, a timestamp, a build root, or an ordering that depends on how
/// the compilation was driven.
///
/// `provenance` is everything else -- useful for debugging, never part of the
/// claim. The split is explicit so a reader cannot mistake one for the other,
/// and `identity_digest` covers only `identity`.
///
/// Usage:
///   dart pkg/vm/bin/maot_identity_manifest.dart \
///       --dill out.dill --dart-commit <sha> --dart-tree <sha> \
///       [--app-root <dir>] [--include-sdk] -o manifest.json
library;

import 'dart:convert';
import 'dart:io';

import 'package:kernel/ast.dart';
import 'package:kernel/kernel.dart';
import 'package:kernel/maot_identity.dart';

const String manifestSchema = 'maot.identity.manifest/2';

class _Entry {
  final String id;
  final String kind;
  final String stability;
  final String role;
  final bool addressable;
  final String? caveat;
  final String? alias;

  _Entry(this.id, this.kind, this.stability, this.role, this.addressable,
      this.caveat, this.alias);

  /// The reproducible projection. Deliberately excludes prose: a reworded
  /// caveat must not change the namespace digest.
  Map<String, Object?> get identityProjection => {
        'id': id,
        'kind': kind,
        'stability': stability,
        'role': role,
        'addressable': addressable,
      };

  Map<String, Object?> toJson() => {
        ...identityProjection,
        if (alias != null) 'implementation_alias': alias,
        if (caveat != null) 'caveat': caveat,
      };
}

void main(List<String> args) {
  String? dillPath;
  String? outPath;
  String? dartCommit;
  String? dartTree;
  String? sourceDigest;
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
    } else if (a == '--dart-commit') {
      dartCommit = args[++i];
    } else if (a == '--dart-tree') {
      dartTree = args[++i];
    } else if (a == '--source-digest') {
      sourceDigest = args[++i];
    } else if (a == '--include-sdk') {
      includeSdk = true;
    } else if (a == '-h' || a == '--help') {
      stdout.writeln('usage: maot_identity_manifest.dart --dill <file> '
          '--dart-commit <sha> --dart-tree <sha> [--source-digest <sha>] '
          '[--app-root <dir>] [--include-sdk] -o <manifest.json>');
      exit(0);
    }
  }

  if (dillPath == null || outPath == null) {
    stderr.writeln('--dill and -o are required');
    exit(2);
  }
  // Fail closed. An unbound manifest names a namespace without saying which
  // compiler produced it, and a patch compiler could then "agree" with a
  // release built by something else entirely.
  if (dartCommit == null || dartCommit.length != 40) {
    stderr.writeln('--dart-commit must be a full 40-hex commit sha; a '
        'manifest that does not name the compiler that produced it cannot '
        'bind a patch to a release');
    exit(2);
  }
  if (dartTree == null || dartTree.length != 40) {
    stderr.writeln('--dart-tree must be a full 40-hex tree sha');
    exit(2);
  }

  final component = loadComponentFromBinary(dillPath);
  final identity = MaotIdentity(appRoot: appRoot);
  // Index lowerings BEFORE walking members, or the mangled top-level name is
  // all that is visible and it becomes the identity.
  identity.indexLowerings(component);

  final entries = <_Entry>[];
  final refusals = <String>[];
  final appMappings = <String>{};

  void add(MaotId id, String kind) {
    entries.add(_Entry(id.id, kind, id.stability.name, id.role.name,
        id.addressable, id.caveat, id.implementationAlias));
  }

  void addTypeParameters(String ownerId, List<TypeParameter> params) {
    for (var i = 0; i < params.length; i++) {
      add(identity.typeParameterId(ownerId, params[i], i), 'type_parameter');
    }
  }

  void addMember(Member m) {
    final id = identity.memberId(m);
    add(id, _memberKind(m, identity));
    final fn = m.function;
    if (fn != null) addTypeParameters(id.id, fn.typeParameters);
  }

  for (final library in component.libraries) {
    if (!includeSdk && library.importUri.scheme == 'dart') continue;
    try {
      final libId = identity.libraryId(library);
      add(libId, 'library');
      if (library.importUri.scheme == 'file') {
        appMappings.add(libId.id);
      }

      for (final td in library.typedefs) {
        final id = identity.typedefId(td);
        add(id, 'typedef');
        addTypeParameters(id.id, td.typeParameters);
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

      // Top-level members come after the extension declarations so every
      // lowering is already indexed and resolves to its logical owner.
      for (final member in library.members) {
        addMember(member);
      }

      for (final cls in library.classes) {
        final clsId = identity.classId(cls);
        add(
            clsId,
            cls.isEnum
                ? 'enum'
                : cls.isMixinDeclaration
                    ? 'mixin'
                    : 'class');
        addTypeParameters(clsId.id, cls.typeParameters);
        for (final member in cls.members) {
          addMember(member);
        }
      }
    } on MaotIdentityError catch (e) {
      // Recorded, never swallowed. A library the scheme cannot name
      // reproducibly must be visible as a refusal; the alternative is a
      // manifest that silently describes less than the program.
      refusals.add('${library.importUri}: ${e.message}');
    }
  }

  entries.sort((a, b) => a.id.compareTo(b.id));

  final ids = entries.map((e) => e.id).toList(growable: false);
  final duplicates = <String>{};
  for (var i = 1; i < ids.length; i++) {
    if (ids[i] == ids[i - 1]) duplicates.add(ids[i]);
  }

  final addressable = entries.where((e) => e.addressable).toList();
  final nonAddressable = entries.where((e) => !e.addressable).toList();

  // The reproducible core. Sorted by id, prose excluded, no path anywhere.
  final identityBlock = <String, Object?>{
    'identity_schema': MaotIdentity.schema,
    'manifest_schema': manifestSchema,
    'dart_commit': dartCommit,
    'dart_tree': dartTree,
    if (sourceDigest != null) 'source_digest': sourceDigest,
    'include_sdk': includeSdk,
    'app_root_supplied': appRoot != null,
    // The canonical URI mapping INPUTS -- which libraries were named through
    // the app root. The root's absolute path is deliberately absent: it is a
    // location, and recording it would make the manifest machine-specific.
    'app_mapped_libraries': (appMappings.toList()..sort()),
    'total': entries.length,
    'addressable': addressable.length,
    'non_addressable': nonAddressable.length,
    'duplicate_count': duplicates.length,
    'refusal_count': refusals.length,
    'by_kind': _countBy(entries, (e) => e.kind),
    'by_stability': _countBy(entries, (e) => e.stability),
    'by_role': _countBy(entries, (e) => e.role),
    'entries': entries.map((e) => e.identityProjection).toList(),
  };

  final identityDigest = _sha256OfCanonicalJson(identityBlock);

  final manifest = <String, Object?>{
    'schema': manifestSchema,
    // The namespace a later patch compilation must match. This is the value
    // #66 onward binds against.
    'namespace_identity': identityDigest,
    'identity': identityBlock,
    'detail': {
      'entries': entries.map((e) => e.toJson()).toList(),
      'refusals': refusals,
      'duplicate_ids': duplicates.toList()..sort(),
    },
    'provenance': {
      'generated_by': 'pkg/vm/bin/maot_identity_manifest.dart',
      'dart_version': Platform.version,
      'note': 'provenance is informational and is NOT covered by '
          'namespace_identity. Nothing here may be used to decide whether a '
          'patch matches a release.',
    },
  };

  File(outPath).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(manifest)}\n');

  stdout.writeln('entries        ${entries.length}');
  stdout.writeln('addressable    ${addressable.length}');
  stdout.writeln('non-addressable ${nonAddressable.length}');
  stdout.writeln('duplicates     ${duplicates.length}');
  stdout.writeln('refusals       ${refusals.length}');
  stdout.writeln('namespace      $identityDigest');
  for (final e in refusals) {
    stderr.writeln('REFUSED $e');
  }
  if (duplicates.isNotEmpty) {
    for (final d in duplicates) {
      stderr.writeln('DUPLICATE $d');
    }
    exit(1);
  }
  if (refusals.isNotEmpty) exit(1);
}

/// A canonical JSON encoding: keys sorted at every level, so the digest is a
/// function of the content and not of insertion order.
String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:'
        '${_canonicalJson(value[k])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

String _sha256OfCanonicalJson(Object? value) {
  // A dependency-free SHA-256 so the tool runs anywhere the SDK does.
  return _Sha256().convert(utf8.encode(_canonicalJson(value)));
}

String _memberKind(Member m, MaotIdentity identity) {
  if (identity.loweringOf(m) != null) return 'extension_member';
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

/// Minimal SHA-256. `package:crypto` is not a dependency of pkg/vm, and the
/// manifest digest must not require one.
class _Sha256 {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  static int _rotr(int x, int n) =>
      ((x >> n) | (x << (32 - n))) & 0xffffffff;

  String convert(List<int> message) {
    final h = <int>[
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ];
    final bitLength = message.length * 8;
    final padded = <int>[...message, 0x80];
    while (padded.length % 64 != 56) {
      padded.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      padded.add((bitLength >> (i * 8)) & 0xff);
    }

    final w = List<int>.filled(64, 0);
    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        final j = chunk + i * 4;
        w[i] = (padded[j] << 24) |
            (padded[j + 1] << 16) |
            (padded[j + 2] << 8) |
            padded[j + 3];
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var i = 0; i < 64; i++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xffffffff;
        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }
      h[0] = (h[0] + a) & 0xffffffff;
      h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff;
      h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff;
      h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff;
      h[7] = (h[7] + hh) & 0xffffffff;
    }
    return h.map((x) => x.toRadixString(16).padLeft(8, '0')).join();
  }
}
