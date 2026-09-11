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

  /// The identity of each type parameter's bound, in declaration order.
  ///
  /// Derived from the VM, not from a wish list. `BuildTypeArgumentTypeChecks`
  /// emits the callee's bound checks only when `!AllDynamicBounds()`, and the
  /// bounds decide which type arguments the callee accepts. A replacement that
  /// narrows `<T extends num>` to `<T extends int>` leaves every caller
  /// compiled against the wider contract, so it is not an unchanged-ABI
  /// replacement even though every count matches.
  ///
  /// Rendered through #65 class identity, never a raw name or path -- see
  /// [renderType].
  final List<String> typeParameterBounds;

  /// Reconstructs a descriptor from [canonicalForm]. Total by construction:
  /// the canonical form is the serialized representation, so a value that
  /// cannot be parsed is a corrupt payload rather than a shape to guess at.
  factory MaotAbiDescriptor.parse(String canonical) {
    final parts = canonical.split(';');
    if (parts.length != 8) {
      throw FormatException('not a MAOT ABI canonical form: $canonical');
    }
    final positional = parts[1].substring(1).split('/');
    List<String> list(String field) {
      final body = field.substring(1);
      return body.isEmpty ? const <String>[] : body.split('|');
    }

    return MaotAbiDescriptor(
      memberKind: int.parse(parts[0].substring(1)),
      requiredPositionalCount: int.parse(positional[0]),
      totalPositionalCount: int.parse(positional[1]),
      namedParameters: list(parts[2]),
      requiredNamedParameters: list(parts[3]),
      typeParameterCount: int.parse(parts[4].substring(1)),
      hasReceiver: parts[5] == 'recv',
      ownerIsGeneric: parts[6] == 'ogen',
      typeParameterBounds: list(parts[7]),
    );
  }

  const MaotAbiDescriptor({
    required this.memberKind,
    required this.requiredPositionalCount,
    required this.totalPositionalCount,
    required this.namedParameters,
    required this.requiredNamedParameters,
    required this.typeParameterCount,
    required this.hasReceiver,
    required this.ownerIsGeneric,
    this.typeParameterBounds = const <String>[],
  });

  /// Whether every part of this descriptor could be represented.
  ///
  /// A bound the renderer does not know how to spell becomes an explicit
  /// `unrepresentable:` token rather than something that happens to compare
  /// equal to another unknown. Compatibility cannot be certified for such a
  /// declaration, and the runtime refuses to stage against it.
  bool get isRepresentable =>
      !typeParameterBounds.any((b) => b.startsWith('unrepresentable:'));

  /// A canonical rendering.
  ///
  /// It carries SHAPE and #65 IDENTITY REFERENCES, and never a raw name, a
  /// file path or an address. A bound necessarily refers to a type, and the
  /// only stable way this program has to refer to one is the #65 class id --
  /// which is what [renderType] emits. Spelling a bound as `num` would be a
  /// name; spelling it as `lib:dart:core::cls:num` is an identity.
  ///
  /// This is the KERNEL/SOURCE-CALL half of the compatibility model. The AOT
  /// calling convention half cannot be computed here: it depends on unboxing
  /// decisions the VM precompiler has not made yet, so the runtime attaches it
  /// at materialization. See MaotRegistry's call-convention descriptor.
  String get canonicalForm => [
    'k$memberKind',
    'p$requiredPositionalCount/$totalPositionalCount',
    'n${namedParameters.join("|")}',
    'r${requiredNamedParameters.join("|")}',
    't$typeParameterCount',
    hasReceiver ? 'recv' : 'norecv',
    ownerIsGeneric ? 'ogen' : 'onogen',
    'b${typeParameterBounds.join("|")}',
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

  /// Declarations that were SELECTED before tree shaking and then had no node
  /// to attach metadata to afterwards.
  ///
  /// This exists because a Set of selected ids is decorative unless some
  /// decision reads it. A selected declaration that vanished cannot be
  /// patched later, so the release must fail closed rather than ship a
  /// namespace that silently promises less than it claims. The #66 gate
  /// consumes this list; it is not advisory.
  final List<String> selectedButAbsent = [];

  // The payload is three fields: the id, the selection flag, and the ABI in
  // its CANONICAL STRING form. The canonical form is rendered once, here,
  // where the descriptor is defined -- reconstructing it on the VM side would
  // duplicate the formatting and let the two drift, which is precisely how a
  // compatibility check starts comparing two different notions of "same ABI".
  @override
  void writeToBinary(
    MaotDeclarationIdMetadata metadata,
    Node node,
    BinarySink sink,
  ) {
    sink.writeStringReference(metadata.declarationId);
    sink.writeByte(metadata.selected ? 1 : 0);
    sink.writeStringReference(metadata.abi.canonicalForm);
  }

  @override
  MaotDeclarationIdMetadata readFromBinary(Node node, BinarySource source) {
    final declarationId = source.readStringReference();
    final selected = source.readByte() == 1;
    final canonical = source.readStringReference();
    return MaotDeclarationIdMetadata(
      declarationId: declarationId,
      selected: selected,
      abi: MaotAbiDescriptor.parse(canonical),
    );
  }

  /// Assigns identity to every member of [component], marking those [select]
  /// accepts.
  ///
  /// Runs before tree shaking. A member the identity scheme refuses is
  /// recorded in [refusals] and given no metadata at all — it must not receive
  /// a guessed id, and it must not silently look like an unselected member.
  /// Collects the ids of members [select] accepts, on the UNSHAKEN component.
  ///
  /// Split from [index] deliberately. Selection must be decided before tree
  /// shaking, but metadata has to be attached to the nodes that actually reach
  /// the binary: the transforms REPLACE member nodes, and metadata keyed on a
  /// replaced node is silently dropped. Measured, not assumed -- the first
  /// version indexed pre-shaking and only the one untransformed member kept
  /// its entry.
  static Set<String> collectSelected(
    Component component,
    MaotIdentity identity,
    bool Function(Member) select, {
    bool includeSdk = false,
  }) {
    final selected = <String>{};
    for (final library in component.libraries) {
      if (!includeSdk && library.importUri.isScheme('dart')) continue;
      void visit(Member member) {
        if (!select(member)) return;
        try {
          final id = identity.memberId(member);
          if (id.addressable) selected.add(id.id);
        } on MaotIdentityError {
          // Refusals are reported by index(); nothing is guessed here.
        }
      }

      library.members.forEach(visit);
      for (final cls in library.classes) {
        cls.members.forEach(visit);
      }
    }
    return selected;
  }

  /// Records which selected ids never received metadata. Call after [index].
  void recordSelectedAbsences(Set<String> selectedIds) {
    final mapped = <String>{
      for (final m in mapping.values) m.declarationId,
    };
    for (final id in selectedIds) {
      if (!mapped.contains(id)) selectedButAbsent.add(id);
    }
  }

  void index(
    Component component,
    MaotIdentity identity, {
    required Set<String> selectedIds,
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
          selected: selectedIds.contains(id.id),
          abi: describeAbi(member, id, identity),
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
  static MaotAbiDescriptor describeAbi(
    Member member,
    MaotId id,
    MaotIdentity identity,
  ) {
    final function = member.function;
    final owner = member.enclosingClass;
    final named = <String>[];
    final requiredNamed = <String>[];
    var requiredPositional = 0;
    var totalPositional = 0;
    var typeParameterCount = 0;

    final bounds = <String>[];

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
      // In DECLARATION order, never sorted: the bound of type parameter 0 is
      // a different fact from the bound of type parameter 1, and sorting
      // would let a reordering compare equal.
      for (final tp in function.typeParameters) {
        bounds.add(renderType(tp.bound, identity, function.typeParameters));
      }
    }

    return MaotAbiDescriptor(
      memberKind: _memberKind(member),
      typeParameterBounds: bounds,
      requiredPositionalCount: requiredPositional,
      totalPositionalCount: totalPositional,
      namedParameters: named,
      requiredNamedParameters: requiredNamed,
      typeParameterCount: typeParameterCount,
      hasReceiver: member.isInstanceMember,
      ownerIsGeneric: owner != null && owner.typeParameters.isNotEmpty,
    );
  }

  /// Renders a Kernel type as an identity string.
  ///
  /// Total by construction: a shape this does not know how to spell becomes
  /// `unrepresentable:<node kind>` rather than a token that might accidentally
  /// compare equal to a different unknown shape. The runtime refuses to stage
  /// a replacement when either side carries such a token, because it cannot
  /// certify a compatibility it could not describe.
  ///
  /// Type parameters are rendered BY POSITION within [scope], so renaming
  /// `<T>` to `<E>` is not a change and reordering two parameters is.
  static String renderType(
    DartType type,
    MaotIdentity identity,
    List<TypeParameter> scope,
  ) {
    String nul(Nullability n) {
      switch (n) {
        case Nullability.nullable:
          return '?';
        case Nullability.nonNullable:
          return '';
        case Nullability.undetermined:
          return '%';
      }
    }

    String render(DartType t) {
      if (t is DynamicType) return 'dyn';
      if (t is VoidType) return 'void';
      if (t is NeverType) return 'never${nul(t.nullability)}';
      if (t is NullType) return 'null';
      if (t is InvalidType) return 'unrepresentable:invalid';
      if (t is InterfaceType) {
        final args = t.typeArguments.map(render).join(',');
        return '${identity.classId(t.classNode).id}'
            '${args.isEmpty ? "" : "<$args>"}${nul(t.nullability)}';
      }
      if (t is FutureOrType) {
        return 'futureor<${render(t.typeArgument)}>${nul(t.nullability)}';
      }
      if (t is TypeParameterType) {
        final i = scope.indexOf(t.parameter);
        // Out of scope means it belongs to the enclosing class, whose
        // genericity is already recorded by ownerIsGeneric; naming it by
        // position here would be a position in a different list.
        return i >= 0
            ? 'tp$i${nul(t.nullability)}'
            : 'ownertp:${t.parameter.name ?? ""}${nul(t.nullability)}';
      }
      if (t is StructuralParameterType) {
        return 'stp:${t.parameter.name ?? ""}${nul(t.nullability)}';
      }
      if (t is FunctionType) {
        final pos = t.positionalParameters.map(render).join(',');
        final named = [
          for (final n in t.namedParameters)
            '${n.isRequired ? "req " : ""}${n.name}:${render(n.type)}',
        ]..sort();
        return 'fn(${t.requiredParameterCount}/$pos'
            '${named.isEmpty ? "" : ";{${named.join(",")}}"})'
            '->${render(t.returnType)}${nul(t.nullability)}';
      }
      if (t is RecordType) {
        final pos = t.positional.map(render).join(',');
        final named = [
          for (final n in t.named) '${n.name}:${render(n.type)}',
        ]..sort();
        return 'rec($pos${named.isEmpty ? "" : ";{${named.join(",")}}"})'
            '${nul(t.nullability)}';
      }
      if (t is TypedefType) return render(t.unalias);
      if (t is ExtensionType) {
        final args = t.typeArguments.map(render).join(',');
        return '${identity.extensionTypeId(t.extensionTypeDeclaration).id}'
            '${args.isEmpty ? "" : "<$args>"}${nul(t.nullability)}';
      }
      if (t is IntersectionType) {
        return 'isect<${render(t.left)},${render(t.right)}>';
      }
      return 'unrepresentable:${t.runtimeType}';
    }

    return render(type);
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
