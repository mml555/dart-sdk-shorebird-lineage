// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Stable declaration and type identity for Mutable-AOT (MAOT-1, issue #65).
///
/// # Why this exists
///
/// A patch compiler must name the same logical program entities the release
/// compiler named, without consulting anything that only exists after
/// compilation. Identity is therefore computed here, in the front end, from
/// the program's *name space* -- and from nothing else.
///
/// # What identity may NOT depend on
///
/// Machine-code addresses, `Function`/`Code` object addresses, object-pool
/// offsets, transient class ids, compilation order, declaration order, source
/// line/column, absolute filesystem paths, or temporary build directories.
///
/// The last pair is the one that bites. A [Library.fileUri] is an absolute
/// path on the machine that compiled it; [Library.importUri] is the canonical
/// name. This library uses `importUri` and REFUSES to name a `file:` library
/// it cannot make root-relative, because such an id would be reproducible
/// only on the machine that minted it -- and would pass every test written
/// there.
///
/// # Two things the first draft got wrong, and why they matter
///
/// **Lowered forms are not logical identity.** The front end lowers an
/// extension member `Ext.twice` to a top-level procedure named
/// `Ext|get#twice`. Naming the lowering would make the logical declaration's
/// identity a function of a *name-mangling scheme*: change the mangling and
/// every extension member in every release silently becomes a different
/// declaration, with no source edit. Extension and extension-type members are
/// therefore identified through their [ExtensionMemberDescriptor] -- owner
/// declaration plus source-level name and kind -- and the lowered procedure
/// name is retained only as an implementation alias.
///
/// **Compiler-generated is not source-declared.** An enum's synthesized
/// `values` field has a stable name today; that is a property of the current
/// compiler, not a contract. Every entity here is classified: source-declared
/// entities get [IdStability.nominal]; compiler-generated ones are either
/// given a defined [SyntheticRole] (addressable, [IdStability.synthetic]) or
/// marked NOT addressable. Nothing gets nominal stability that has not been
/// defined.
///
/// # The form
///
///     lib:package:foo/bar.dart
///     lib:package:foo/bar.dart::fn:compute
///     lib:package:foo/bar.dart::cls:MyClass
///     lib:package:foo/bar.dart::cls:MyClass::method:doThing
///     lib:package:foo/bar.dart::cls:MyClass::get:value
///     lib:package:foo/bar.dart::cls:MyClass::op:+
///     lib:package:foo/bar.dart::cls:MyClass::ctor:
///     lib:package:foo/bar.dart::cls:MyClass::factory:make
///     lib:package:foo/bar.dart::cls:MyClass::field:n
///     lib:package:foo/bar.dart::cls:MyClass::tp:T
///     lib:package:foo/bar.dart::cls:C::method:_hidden@package:foo/bar.dart
///     lib:package:foo/bar.dart::ext:Ext::get:twice
///     lib:package:foo/bar.dart::extype:Id::ctor:
///     lib:package:foo/bar.dart::enum:E::field:a
///     lib:package:foo/bar.dart::enum:E::synthetic:values
///
/// # Decisions stated rather than discovered
///
/// * **Rename** -> NEW identity. No automatic alias; a rename that must carry
///   state is a developer-authored migration (matrix `TS-03`).
/// * **Move to another library** -> NEW identity; the library is part of the
///   name space.
/// * **Reorder / insert declarations** -> nothing changes. No ordinal appears
///   in any id.
/// * **Generic arity change** -> identity PRESERVED, deliberately. Arity is
///   not an input. If `Box<T>` -> `Box<T, U>` minted a new id, the existing
///   instances would be unaddressable by any migration, and addressing them is
///   the entire point (matrix `TS-10`).
/// * **Private names** are qualified by their defining library. Dart privacy
///   is library-scoped; a scheme that ignored it would merge two declarations
///   and the merge would surface only as a patch binding to the wrong member.
/// * **Anonymous mixin applications** are named by the front end from the
///   mixin list. Changing that list is a different synthetic class, not churn.
/// * **Closures** get a positional id stamped [IdStability.structural]: stable
///   only while the nesting and order of function literals is unchanged.
library;

import 'ast.dart';

/// How far an id can be trusted across an edit.
enum IdStability {
  /// Derived from names the developer wrote. Stable under any edit that does
  /// not change those names.
  nominal,

  /// Compiler-generated, but with a defined semantic role, so it is derived
  /// from the logical declaration that caused it rather than from a mangling.
  synthetic,

  /// Derived in part from position within a body. Stable only while the
  /// surrounding structure is unchanged.
  structural,
}

/// The defined roles a compiler-generated entity may have.
///
/// A generated entity with a role here is ADDRESSABLE: its identity is a
/// function of the logical declaration plus the role. One without a role is
/// not addressable, and the manifest says so rather than inventing an id.
enum SyntheticRole {
  none,
  enumValues,
  enumToString,
  enumImplicitConstructor,
  implicitConstructor,
  extensionLowering,
  extensionTearOff,
  forwardingStub,
  noSuchMethodForwarder,
  memberSignature,
  mixinStub,
  representationField,
  anonymousMixinApplication,
}

/// A computed identity plus the provenance a consumer needs to judge it.
class MaotId {
  final String id;
  final IdStability stability;
  final SyntheticRole role;

  /// True when a patch may refer to this entity. False means the entity is
  /// compiler-generated with no defined role -- it exists, it is recorded, and
  /// nothing may bind to it.
  final bool addressable;

  /// Why the id is not plain nominal, when it is not.
  final String? caveat;

  /// The lowered/implementation name, when the logical entity has one. Kept
  /// for debugging and provenance; never an identity.
  final String? implementationAlias;

  const MaotId(
    this.id, {
    this.stability = IdStability.nominal,
    this.role = SyntheticRole.none,
    this.addressable = true,
    this.caveat,
    this.implementationAlias,
  });

  @override
  String toString() => id;

  @override
  bool operator ==(Object other) => other is MaotId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Raised when an identity cannot be computed reproducibly.
///
/// An exception rather than a fallback id: a fallback would be a
/// machine-specific identity that looks exactly like a real one.
class MaotIdentityError implements Exception {
  final String message;
  const MaotIdentityError(this.message);
  @override
  String toString() => 'MaotIdentityError: $message';
}

/// Computes identities for the declarations of a component.
///
/// [appRoot] makes `file:` libraries addressable: a library beneath it is
/// named `app:<relative path>`. Without it a `file:` library has no
/// reproducible name and identity computation throws.
class MaotIdentity {
  final Uri? appRoot;

  /// Lowered member reference -> the logical id it implements. Built by
  /// [indexLowerings]; consulted by [memberId] so a lowering never becomes an
  /// identity in its own right.
  final Map<Reference, MaotId> _lowerings = {};

  MaotIdentity({this.appRoot});

  static const String schema = 'maot.identity/2';

  // --------------------------------------------------------------- library

  String libraryKey(Library library) => _uriKey(library.importUri);

  String _uriKey(Uri uri) {
    switch (uri.scheme) {
      case 'package':
      case 'dart':
        return uri.toString();
      case 'file':
        final root = appRoot;
        if (root == null) {
          throw MaotIdentityError(
              'library $uri has a file: URI and no appRoot was supplied. A '
              'file: URI names a location on one machine, so an identity '
              'derived from it would be reproducible nowhere else. Supply an '
              'appRoot so the library can be named app:<relative path>, or '
              'compile with a package config so it has a package: URI.');
        }
        final rel = _relativeTo(root, uri);
        if (rel == null) {
          throw MaotIdentityError(
              'library $uri is outside appRoot $root, so it cannot be given a '
              'root-relative name. Widen appRoot or compile the library as '
              'part of a package.');
        }
        return 'app:$rel';
      default:
        throw MaotIdentityError(
            'library $uri has unsupported scheme "${uri.scheme}"; identity '
            'requires a canonical package:, dart: or root-relative file: URI.');
    }
  }

  static String? _relativeTo(Uri root, Uri target) {
    final rootSegments =
        root.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    final targetSegments =
        target.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    if (targetSegments.length < rootSegments.length) return null;
    for (var i = 0; i < rootSegments.length; i++) {
      if (rootSegments[i] != targetSegments[i]) return null;
    }
    return targetSegments.sublist(rootSegments.length).join('/');
  }

  MaotId libraryId(Library library) => MaotId('lib:${libraryKey(library)}');

  // ---------------------------------------------------------------- naming

  /// Renders a member name, qualifying private names by their defining
  /// library.
  ///
  /// Resolution goes through the REFERENCE, not `Name.library`: the latter
  /// dereferences an AST node that is absent whenever the platform is not
  /// linked into the dill, and identity must not depend on how much of the
  /// program a given compilation happened to load.
  String nameKey(Name name) {
    if (!name.isPrivate) return name.text;
    final ref = name.libraryReference;
    if (ref == null) {
      throw MaotIdentityError(
          'private name "${name.text}" carries no defining library, so it '
          'cannot be distinguished from an identically spelled private name '
          'in another library.');
    }
    final node = ref.node;
    if (node is Library) return '${name.text}@${libraryKey(node)}';
    final canonical = ref.canonicalName;
    if (canonical == null) {
      throw MaotIdentityError(
          'private name "${name.text}" has a library reference that is '
          'neither a loaded library nor a canonical name, so its defining '
          'library cannot be named.');
    }
    return '${name.text}@${_uriKey(Uri.parse(canonical.name))}';
  }

  // ------------------------------------------------------ type declarations

  String _typeDeclarationTag(Class cls) {
    if (cls.isEnum) return 'enum';
    if (cls.isMixinDeclaration) return 'mixin';
    return 'cls';
  }

  MaotId classId(Class cls) {
    final id = 'lib:${libraryKey(cls.enclosingLibrary)}'
        '::${_typeDeclarationTag(cls)}:${cls.name}';
    if (cls.isAnonymousMixin) {
      return MaotId(id,
          stability: IdStability.synthetic,
          role: SyntheticRole.anonymousMixinApplication,
          caveat: 'anonymous mixin application; the name is generated by the '
              'front end from the mixin list, so changing that list yields a '
              'different synthetic class rather than a rename');
    }
    return MaotId(id);
  }

  MaotId extensionId(Extension ext) =>
      MaotId('lib:${libraryKey(ext.enclosingLibrary)}::ext:${ext.name}');

  MaotId extensionTypeId(ExtensionTypeDeclaration decl) =>
      MaotId('lib:${libraryKey(decl.enclosingLibrary)}::extype:${decl.name}');

  MaotId typedefId(Typedef td) =>
      MaotId('lib:${libraryKey(td.enclosingLibrary)}::typedef:${td.name}');

  // --------------------------------------------- extension member lowering

  static String _extensionMemberTag(ExtensionMemberKind kind) {
    switch (kind) {
      case ExtensionMemberKind.Method:
        return 'method';
      case ExtensionMemberKind.Getter:
        return 'get';
      case ExtensionMemberKind.Setter:
        return 'set';
      case ExtensionMemberKind.Operator:
        return 'op';
      case ExtensionMemberKind.Field:
        return 'field';
    }
  }

  static String _extensionTypeMemberTag(ExtensionTypeMemberKind kind) {
    switch (kind) {
      case ExtensionTypeMemberKind.Method:
        return 'method';
      case ExtensionTypeMemberKind.Getter:
        return 'get';
      case ExtensionTypeMemberKind.Setter:
        return 'set';
      case ExtensionTypeMemberKind.Operator:
        return 'op';
      case ExtensionTypeMemberKind.Constructor:
        return 'ctor';
      case ExtensionTypeMemberKind.Factory:
        return 'factory';
      case ExtensionTypeMemberKind.RedirectingFactory:
        return 'factory';
      case ExtensionTypeMemberKind.Field:
        return 'field';
    }
  }

  /// Records, for every extension and extension-type member in [component],
  /// which lowered procedure implements it.
  ///
  /// Must run before [memberId] is used on a library that has extensions,
  /// otherwise the lowered top-level procedure is all that is visible and the
  /// mangled name becomes the identity -- the exact defect this indexing
  /// exists to prevent.
  void indexLowerings(Component component) {
    for (final library in component.libraries) {
      for (final ext in library.extensions) {
        final ownerId = extensionId(ext).id;
        for (final d in ext.memberDescriptors) {
          _recordLowering(
              ownerId, _extensionMemberTag(d.kind), d, d.memberReference,
              d.tearOffReference);
        }
      }
      for (final etd in library.extensionTypeDeclarations) {
        final ownerId = extensionTypeId(etd).id;
        for (final d in etd.memberDescriptors) {
          _recordLowering(
              ownerId, _extensionTypeMemberTag(d.kind), d, d.memberReference,
              d.tearOffReference);
        }
      }
    }
  }

  void _recordLowering(String ownerId, String tag, dynamic descriptor,
      Reference? memberRef, Reference? tearOffRef) {
    final Name name = descriptor.name as Name;
    final bool internal = descriptor.isInternalImplementation as bool;
    final logical = '$ownerId::$tag:${nameKey(name)}';

    if (memberRef != null) {
      _lowerings[memberRef] = MaotId(
        logical,
        stability: internal ? IdStability.synthetic : IdStability.nominal,
        role: internal ? SyntheticRole.extensionLowering : SyntheticRole.none,
        addressable: true,
        caveat: internal
            ? 'internal implementation of an extension member; addressable '
                'through its owning declaration, not through the lowered name'
            : null,
        implementationAlias: _loweredName(memberRef),
      );
    }
    if (tearOffRef != null) {
      _lowerings[tearOffRef] = MaotId(
        '$logical#tearoff',
        stability: IdStability.synthetic,
        role: SyntheticRole.extensionTearOff,
        addressable: true,
        caveat: 'the tear-off the front end generates for an extension '
            'member; derived from the member, not from the mangled name',
        implementationAlias: _loweredName(tearOffRef),
      );
    }
  }

  static String? _loweredName(Reference ref) {
    final node = ref.node;
    if (node is Member) return node.name.text;
    return ref.canonicalName?.name;
  }

  /// The logical id of a lowered member, or null if it is not a lowering.
  MaotId? loweringOf(Member m) => _lowerings[m.reference];

  // ----------------------------------------------------------------- members

  String _procedureTag(Procedure p) {
    switch (p.kind) {
      case ProcedureKind.Method:
        return p.enclosingClass == null ? 'fn' : 'method';
      case ProcedureKind.Getter:
        return 'get';
      case ProcedureKind.Setter:
        return 'set';
      case ProcedureKind.Operator:
        return 'op';
      case ProcedureKind.Factory:
        return 'factory';
    }
  }

  String _ownerKey(Member m) {
    final cls = m.enclosingClass;
    if (cls != null) return classId(cls).id;
    return libraryId(m.enclosingLibrary).id;
  }

  static SyntheticRole _stubRole(ProcedureStubKind kind) {
    switch (kind) {
      case ProcedureStubKind.Regular:
        return SyntheticRole.none;
      case ProcedureStubKind.AbstractForwardingStub:
      case ProcedureStubKind.ConcreteForwardingStub:
        return SyntheticRole.forwardingStub;
      case ProcedureStubKind.NoSuchMethodForwarder:
        return SyntheticRole.noSuchMethodForwarder;
      case ProcedureStubKind.MemberSignature:
        return SyntheticRole.memberSignature;
      case ProcedureStubKind.AbstractMixinStub:
      case ProcedureStubKind.ConcreteMixinStub:
        return SyntheticRole.mixinStub;
      case ProcedureStubKind.RepresentationField:
        return SyntheticRole.representationField;
    }
  }

  MaotId memberId(Member m) {
    // A lowering never speaks for itself.
    final lowered = loweringOf(m);
    if (lowered != null) return lowered;

    final owner = _ownerKey(m);

    if (m is Procedure) {
      final id = '$owner::${_procedureTag(m)}:${nameKey(m.name)}';

      // A member whose name is private to a library OTHER than the one
      // declaring the enclosing class was injected by the compiler: source
      // cannot spell a name private to somebody else's library. `_enumToString`
      // on every enum is the case that surfaced this. Such a member must not
      // claim source-level identity it does not have.
      final injected = _foreignPrivateInjection(m);
      if (injected != null) return injected;

      if (m.stubKind != ProcedureStubKind.Regular) {
        return MaotId(id,
            stability: IdStability.synthetic,
            role: _stubRole(m.stubKind),
            addressable: true,
            caveat: 'front-end synthesized ${m.stubKind.name}; identity is '
                'the logical member it stands for plus that role, and it is '
                're-derived with the declarations it forwards to');
      }
      return MaotId(id);
    }

    if (m is Constructor) {
      final id = '$owner::ctor:${nameKey(m.name)}';
      if (m.isSynthetic) {
        final cls = m.enclosingClass;
        return MaotId(id,
            stability: IdStability.synthetic,
            role: cls != null && cls.isEnum
                ? SyntheticRole.enumImplicitConstructor
                : SyntheticRole.implicitConstructor,
            addressable: true,
            caveat: 'implicit constructor; the developer wrote no such '
                'declaration, so its identity is the class plus the role');
      }
      return MaotId(id);
    }

    if (m is Field) {
      final id = '$owner::field:${nameKey(m.name)}';
      final cls = m.enclosingClass;
      if (cls != null && cls.isEnum) {
        if (m.isEnumElement) {
          // Source-declared: the developer wrote `a, b`. Matrix row DA-15 is
          // about adding one, so it must be addressable by name.
          return MaotId(id);
        }
        if (m.name.text == 'values') {
          return MaotId('$owner::synthetic:values',
              stability: IdStability.synthetic,
              role: SyntheticRole.enumValues,
              addressable: true,
              caveat: 'the synthesized enum value list. Identified by the '
                  'enum declaration plus a defined role, NOT by the generated '
                  'name -- the name being stable today is a property of this '
                  'compiler, not a contract',
              implementationAlias: 'values');
        }
        // A generated enum member this scheme has not modelled. It is
        // recorded and explicitly NOT addressable, rather than being given a
        // nominal identity nobody defined.
        if (m.isInternalImplementation) {
          return MaotId(id,
              stability: IdStability.synthetic,
              role: SyntheticRole.none,
              addressable: false,
              caveat: 'compiler-generated enum member with no defined role in '
                  'maot.identity/2; recorded, not addressable. Give it a role '
                  'before anything binds to it');
        }
      }
      if (m.isInternalImplementation) {
        return MaotId(id,
            stability: IdStability.synthetic,
            role: SyntheticRole.none,
            addressable: false,
            caveat: 'internal implementation field with no defined role; '
                'recorded, not addressable');
      }
      return MaotId(id);
    }

    throw MaotIdentityError(
        'unhandled member kind ${m.runtimeType} for ${m.name.text}; an '
        'unmodelled member must not silently receive a guessed identity');
  }


  /// A member the compiler placed on a class, detected by its name being
  /// private to a different library than the class's own.
  ///
  /// Returns null when the member is not such an injection. Known roles get a
  /// role-derived identity; anything else is recorded and explicitly NOT
  /// addressable, because minting nominal identity for a construct nobody has
  /// modelled is how an unowned entity later gets bound to.
  MaotId? _foreignPrivateInjection(Procedure m) {
    if (!m.name.isPrivate) return null;
    if (m.stubKind != ProcedureStubKind.Regular) return null;
    final cls = m.enclosingClass;
    if (cls == null) return null;
    final nameLib = m.name.libraryReference?.canonicalName?.name ??
        (m.name.libraryReference?.node is Library
            ? libraryKey(m.name.libraryReference!.node as Library)
            : null);
    if (nameLib == null) return null;
    final ownLib = libraryKey(cls.enclosingLibrary);
    if (_uriKey(Uri.parse(nameLib)) == ownLib) return null;

    final owner = classId(cls).id;
    if (cls.isEnum && m.name.text == '_enumToString') {
      return MaotId('$owner::synthetic:enumToString',
          stability: IdStability.synthetic,
          role: SyntheticRole.enumToString,
          addressable: true,
          caveat: 'the enum toString support the front end injects from '
              'dart:core. Identified by the enum declaration plus a defined '
              'role, not by the injected private name',
          implementationAlias: m.name.text);
    }
    return MaotId('$owner::injected:${nameKey(m.name)}',
        stability: IdStability.synthetic,
        role: SyntheticRole.none,
        addressable: false,
        caveat: 'compiler-injected member private to $nameLib, which is not '
            'the declaring library of this class. It has no defined role in '
            'maot.identity/2, so it is recorded and NOT addressable. Give it '
            'a role before anything binds to it',
        implementationAlias: m.name.text);
  }

  // --------------------------------------------------------- type parameters

  /// Type parameters are identified by NAME within their declaration, never by
  /// index, so inserting one does not rename its neighbours.
  MaotId typeParameterId(String ownerId, TypeParameter tp, int index) {
    final name = tp.name;
    if (name == null || name.isEmpty) {
      return MaotId('$ownerId::tp#$index',
          stability: IdStability.structural,
          addressable: true,
          caveat: 'the type parameter has no name, so its id is positional '
              'and moves if the parameter list is reordered');
    }
    return MaotId('$ownerId::tp:$name');
  }

  // ---------------------------------------------------------------- closures

  MaotId closureId(String memberId, List<int> path) => MaotId(
      '$memberId::closure:${path.join('.')}',
      stability: IdStability.structural,
      addressable: true,
      caveat: 'positional within the enclosing body; stable only while the '
          'nesting and order of function literals is unchanged');
}
