// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Carries the Mutable-AOT declaration identity from Kernel into the VM
/// (MAOT-2, issue #66).
///
/// # Why a metadata repository
///
/// The registry must never rediscover which runtime `Function` corresponds to
/// which logical declaration. It has to be *told*, by the only party that can
/// know without guessing: the compiler, while the Kernel declaration is still
/// the authoritative object. This repository is how that fact travels — it is
/// serialized into the dill and read back by a `MetadataHelper` during kernel
/// loading inside `gen_snapshot`, exactly as `vm.closure-id`,
/// `vm.procedure-attributes` and the seven other repositories already do.
///
/// The alternative that looks simpler — put the id on `Function` beside
/// `kernel_offset_` — does not work, and not for a matter of taste:
/// `raw_object.h` guards `kernel_offset_` with
/// `#if !defined(DART_PRECOMPILED_RUNTIME)`, so kernel-derived `Function`
/// fields are compiled out of the AOT runtime. The id would exist in the
/// precompiler and be absent in the artifact that runs.
///
/// # Selection
///
/// Selection is computed here, on the Kernel component, BEFORE the
/// precompiler's tree shaker runs. "Whatever survived AOT" is not a selection
/// contract: a declaration that was selected and then eliminated must still be
/// registered, because #68 needs dead-but-mutable declarations to remain
/// representable. The flag rides in the payload so widening the selected set
/// later is a policy change rather than a representation change.
library vm.metadata.maot_declaration_id;

import 'package:kernel/ast.dart';
import 'package:kernel/maot_identity.dart';

/// What the runtime needs in order to decide whether a replacement body can
/// occupy an existing call contract.
///
/// Dart source type equality does not define machine-call compatibility, so
/// this records the shape the calling convention actually cares about. It is
/// deterministic and order-stable: named parameters are sorted, so two
/// compilations of the same declaration produce the same descriptor and the
/// same digest.
class MaotAbiDescriptor {
  /// Mirrors the member kind in the #65 identity tag, so the descriptor and
  /// the id can never disagree about what kind of member this is.
  final int memberKind;

  /// Positional parameters the caller must supply, and the total it may.
  final int requiredPositionalCount;
  final int totalPositionalCount;

  /// Named parameters, sorted; and which of them are required.
  final List<String> namedParameters;
  final List<String> requiredNamedParameters;

  final int typeParameterCount;

  /// True when the declaration takes a receiver — an instance member. A static
  /// and an instance member with the same signature are not call-compatible.
  final bool hasReceiver;

  /// True when the enclosing declaration is generic, so the callee expects
  /// type arguments to be passed.
  final bool ownerIsGeneric;

  const MaotAbiDescriptor({
    required this.memberKind,
    required this.requiredPositionalCount,
    required this.totalPositionalCount,
    required this.namedParameters,
    required this.requiredNamedParameters,
    required this.typeParameterCount,
    required this.hasReceiver,
    required this.ownerIsGeneric,
  });

  /// A canonical rendering. The runtime compares descriptors by this string's
  /// digest rather than by walking structures, and it must never include a
  /// name, a path or an address — only shape.
  String get canonicalForm => [
    'k$memberKind',
    'p$requiredPositionalCount/$totalPositionalCount',
    'n${namedParameters.join("|")}',
    'r${requiredNamedParameters.join("|")}',
    't$typeParameterCount',
    hasReceiver ? 'recv' : 'norecv',
    ownerIsGeneric ? 'ogen' : 'onogen',
  ].join(';');

  @override
  String toString() => canonicalForm;
}

class MaotDeclarationIdMetadata {
  /// The #65 identity. The whole point of this repository.
  final String declarationId;

  /// Whether this declaration was selected for Mutable-AOT body replacement.
  /// Recorded per declaration rather than implied by presence, so an
  /// unselected declaration cannot become mutable by accident and a selected
  /// one cannot quietly vanish.
  final bool selected;

  final MaotAbiDescriptor abi;

  const MaotDeclarationIdMetadata({
    required this.declarationId,
    required this.selected,
    required this.abi,
  });

  @override
  String toString() =>
      '$declarationId${selected ? " [selected]" : ""} ${abi.canonicalForm}';
}

class MaotDeclarationIdMetadataRepository
    extends MetadataRepository<MaotDeclarationIdMetadata> {
  static const String repositoryTag = 'vm.maot-declaration-id';

  @override
  String get tag => repositoryTag;

  @override
  final Map<TreeNode, MaotDeclarationIdMetadata> mapping = {};

  /// Declarations this compilation refused to name. Kept rather than dropped:
  /// a declaration the identity scheme cannot name reproducibly must be
  /// visible, because the alternative is a registry that silently describes
  /// less than the program.
  final List<String> refusals = [];

  @override
  void writeToBinary(
    MaotDeclarationIdMetadata metadata,
    Node node,
    BinarySink sink,
  ) {
    sink.writeStringReference(metadata.declarationId);
    sink.writeByte(metadata.selected ? 1 : 0);
    final abi = metadata.abi;
    sink.writeUInt30(abi.memberKind);
    sink.writeUInt30(abi.requiredPositionalCount);
    sink.writeUInt30(abi.totalPositionalCount);
    sink.writeUInt30(abi.namedParameters.length);
    for (final name in abi.namedParameters) {
      sink.writeStringReference(name);
    }
    sink.writeUInt30(abi.requiredNamedParameters.length);
    for (final name in abi.requiredNamedParameters) {
      sink.writeStringReference(name);
    }
    sink.writeUInt30(abi.typeParameterCount);
    sink.writeByte(abi.hasReceiver ? 1 : 0);
    sink.writeByte(abi.ownerIsGeneric ? 1 : 0);
  }

  @override
  MaotDeclarationIdMetadata readFromBinary(Node node, BinarySource source) {
    final declarationId = source.readStringReference();
    final selected = source.readByte() == 1;
    final memberKind = source.readUInt30();
    final requiredPositional = source.readUInt30();
    final totalPositional = source.readUInt30();
    final named = <String>[
      for (int i = source.readUInt30(); i > 0; i--) source.readStringReference(),
    ];
    final requiredNamed = <String>[
      for (int i = source.readUInt30(); i > 0; i--) source.readStringReference(),
    ];
    final typeParameterCount = source.readUInt30();
    final hasReceiver = source.readByte() == 1;
    final ownerIsGeneric = source.readByte() == 1;
    return MaotDeclarationIdMetadata(
      declarationId: declarationId,
      selected: selected,
      abi: MaotAbiDescriptor(
        memberKind: memberKind,
        requiredPositionalCount: requiredPositional,
        totalPositionalCount: totalPositional,
        namedParameters: named,
        requiredNamedParameters: requiredNamed,
        typeParameterCount: typeParameterCount,
        hasReceiver: hasReceiver,
        ownerIsGeneric: ownerIsGeneric,
      ),
    );
  }

  /// Assigns identity to every member of [component], marking those [select]
  /// accepts.
  ///
  /// Runs before tree shaking. A member the identity scheme refuses is
  /// recorded in [refusals] and given no metadata at all — it must not receive
  /// a guessed id, and it must not silently look like an unselected member.
  void index(
    Component component,
    MaotIdentity identity, {
    required bool Function(Member) select,
    bool includeSdk = false,
  }) {
    for (final library in component.libraries) {
      if (!includeSdk && library.importUri.isScheme('dart')) continue;
      void visit(Member member) {
        final MaotId id;
        try {
          id = identity.memberId(member);
        } on MaotIdentityError catch (e) {
          refusals.add('${member.name.text}: ${e.message}');
          return;
        }
        if (!id.addressable) {
          // Recorded by the identity scheme as compiler-generated with no
          // defined role. It has an id, and nothing may bind to it.
          return;
        }
        mapping[member] = MaotDeclarationIdMetadata(
          declarationId: id.id,
          selected: select(member),
          abi: describeAbi(member, id),
        );
      }

      try {
        identity.libraryId(library);
      } on MaotIdentityError catch (e) {
        refusals.add('${library.importUri}: ${e.message}');
        continue;
      }
      library.members.forEach(visit);
      for (final cls in library.classes) {
        cls.members.forEach(visit);
      }
    }
  }

  /// Derives the ABI descriptor from the Kernel member.
  static MaotAbiDescriptor describeAbi(Member member, MaotId id) {
    final function = member.function;
    final owner = member.enclosingClass;
    final named = <String>[];
    final requiredNamed = <String>[];
    var requiredPositional = 0;
    var totalPositional = 0;
    var typeParameterCount = 0;

    if (function != null) {
      requiredPositional = function.requiredParameterCount;
      totalPositional = function.positionalParameters.length;
      typeParameterCount = function.typeParameters.length;
      for (final p in function.namedParameters) {
        named.add(p.name ?? '');
        if (p.isRequired) requiredNamed.add(p.name ?? '');
      }
      named.sort();
      requiredNamed.sort();
    }

    return MaotAbiDescriptor(
      memberKind: _memberKind(member),
      requiredPositionalCount: requiredPositional,
      totalPositionalCount: totalPositional,
      namedParameters: named,
      requiredNamedParameters: requiredNamed,
      typeParameterCount: typeParameterCount,
      hasReceiver: member.isInstanceMember,
      ownerIsGeneric: owner != null && owner.typeParameters.isNotEmpty,
    );
  }

  static int _memberKind(Member member) {
    if (member is Field) return 0;
    if (member is Constructor) return 1;
    if (member is Procedure) {
      switch (member.kind) {
        case ProcedureKind.Method:
          return member.isInstanceMember ? 2 : 3;
        case ProcedureKind.Getter:
          return 4;
        case ProcedureKind.Setter:
          return 5;
        case ProcedureKind.Operator:
          return 6;
        case ProcedureKind.Factory:
          return 7;
      }
    }
    return 8;
  }
}
