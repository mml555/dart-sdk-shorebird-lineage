// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Stable declaration and type identity for Mutable-AOT (MAOT-1, issue #65).
///
/// # Why this exists
///
/// A patch compiler must name the same logical program entities the release
/// compiler named, without consulting anything that only exists after
/// compilation. So identity is computed here, in the front end, from the
/// program's *name space* -- and from nothing else.
///
/// # What identity may NOT depend on
///
/// Machine-code addresses, `Function`/`Code` object addresses, object-pool
/// offsets, transient class ids, compilation order, declaration order, source
/// line/column, absolute filesystem paths, or temporary build directories.
///
/// The one that bites in practice is the last pair. A `Library`'s [Library
/// .fileUri] is an absolute path on the machine that compiled it; its
/// [Library.importUri] is the canonical name. This library uses `importUri`
/// and REFUSES to emit an identity for a library whose canonical URI is a
/// `file:` URI it cannot make root-relative -- because such an id would be
/// reproducible only on the machine that minted it, which is exactly the
/// defect the scheme exists to prevent. Refusing is the whole point: an id
/// that silently embeds `/Users/someone/build` would pass every test written
/// on that machine.
///
/// # The form
///
/// Ids are canonical strings rather than opaque hashes. A hash would be
/// shorter and would make every mismatch equally unreadable; the point of a
/// stable identity is that a human can see WHY two ids differ. A digest of
/// the canonical string is available for callers that want a fixed width.
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
///     lib:package:foo/bar.dart::cls:MyClass::method:_hidden@package:foo/bar.dart
///
/// # Decisions this scheme makes explicitly
///
/// Each of these is a choice, not a consequence, and #65 requires them stated
/// rather than discovered:
///
/// * **Renaming** a declaration yields a NEW identity. There is no automatic
///   alias; a rename that must preserve state is a developer-authored
///   migration (matrix row `TS-03`).
/// * **Moving** a declaration to another library yields a NEW identity,
///   because the library is part of the name space.
/// * **Reordering** declarations changes nothing. No ordinal appears in an id.
/// * **Inserting** declarations changes nothing about existing ones.
/// * **Generic arity changes PRESERVE identity.** Arity is deliberately not an
///   input. `Box<T>` becoming `Box<T, U>` is the same class the developer
///   edited, and if the edit minted a new identity there would be no way to
///   ADDRESS the old instances in a migration. The matrix row `TS-10` owns
///   what happens to those instances; this scheme's job is only to make them
///   nameable.
/// * **Private names** are qualified by their defining library, so `_x` in two
///   libraries never aliases -- Dart's privacy is library-scoped and an
///   identity scheme that ignored that would silently merge two declarations.
/// * **Synthetic mixin-application classes** are identified by the name the
///   front end generates for them, which is a deterministic function of the
///   application. Changing the mixin list changes that name, and that is a
///   genuinely different synthetic class rather than churn.
/// * **Closures** get a STRUCTURAL identity: the pre-order index path of
///   function nodes within the enclosing member. It is stable under edits that
///   do not change the nesting or order of function literals, and not stable
///   otherwise. Every closure id is stamped [IdStability.structural] so a
///   consumer can refuse to rely on it rather than discovering the limit later.
library;

import 'ast.dart';

/// How much an id can be trusted across an edit.
enum IdStability {
  /// Derived from names in the program's name space. Stable under any edit
  /// that does not change those names.
  nominal,

  /// Derived from the generated name of a front-end synthesized entity, which
  /// is itself a deterministic function of the declaration that caused it.
  synthetic,

  /// Derived in part from position within a body. Stable only while the
  /// surrounding structure is unchanged. Callers that need persistence across
  /// arbitrary edits must not depend on it.
  structural,
}

/// A computed identity, with the provenance a consumer needs to judge it.
class MaotId {
  final String id;
  final IdStability stability;

  /// Why the id is not [IdStability.nominal], when it is not. Null otherwise.
  final String? caveat;

  const MaotId(this.id, {this.stability = IdStability.nominal, this.caveat});

  @override
  String toString() => id;

  @override
  bool operator ==(Object other) => other is MaotId && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Raised when an identity cannot be computed reproducibly.
///
/// Deliberately an exception rather than a fallback id. A fallback would be a
/// machine-specific identity that looks exactly like a real one.
class MaotIdentityError implements Exception {
  final String message;
  const MaotIdentityError(this.message);
  @override
  String toString() => 'MaotIdentityError: $message';
}

/// Computes identities for the declarations of a component.
///
/// [appRoot] makes `file:` libraries addressable: a library under that root is
/// named `app:<path relative to root>`. Without it, a `file:` library has no
/// reproducible name and [libraryId] throws.
class MaotIdentity {
  final Uri? appRoot;

  MaotIdentity({this.appRoot});

  static const String schema = 'maot.identity/1';

  // --------------------------------------------------------------- library

  /// The canonical name of [library]'s name space.
  ///
  /// Uses [Library.importUri]. Never [Library.fileUri] -- that is where the
  /// file happened to sit on the machine that compiled it.
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

  /// Renders a member name, qualifying private names by their owning library.
  ///
  /// Dart privacy is library-scoped: `_x` in two libraries are two different
  /// members that happen to be spelled the same. An identity scheme that
  /// dropped the qualification would merge them, and the merge would only
  /// surface as a patch binding to the wrong member.
  String nameKey(Name name) {
    if (!name.isPrivate) return name.text;
    final ref = name.libraryReference;
    if (ref == null) {
      throw MaotIdentityError(
          'private name "${name.text}" carries no defining library, so it '
          'cannot be distinguished from an identically spelled private name '
          'in another library.');
    }
    // Resolve through the REFERENCE, not through `name.library`. The latter
    // dereferences an AST node, which is absent whenever the platform is not
    // linked into the dill -- and the identity of a private name must not
    // depend on how much of the program a given compilation happened to load.
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

  // -------------------------------------------------------- type declarations

  String _typeDeclarationTag(Class cls) {
    if (cls.isEnum) return 'enum';
    if (cls.isMixinDeclaration) return 'mixin';
    return 'cls';
  }

  MaotId classId(Class cls) {
    final key = '${libraryKey(cls.enclosingLibrary)}'
        '::${_typeDeclarationTag(cls)}:${cls.name}';
    if (cls.isAnonymousMixin) {
      return MaotId('lib:$key',
          stability: IdStability.synthetic,
          caveat: 'anonymous mixin application; the name is generated by the '
              'front end from the mixin list, so changing that list is a '
              'different synthetic class rather than a rename');
    }
    return MaotId('lib:$key');
  }

  MaotId extensionId(Extension ext) => MaotId(
      'lib:${libraryKey(ext.enclosingLibrary)}::ext:${ext.name}');

  MaotId extensionTypeId(ExtensionTypeDeclaration decl) => MaotId(
      'lib:${libraryKey(decl.enclosingLibrary)}::extype:${decl.name}');

  MaotId typedefId(Typedef td) =>
      MaotId('lib:${libraryKey(td.enclosingLibrary)}::typedef:${td.name}');

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

  /// The id of the entity a member is declared in: a class, an extension, an
  /// extension type, or the library itself.
  String _ownerKey(Member m) {
    final cls = m.enclosingClass;
    if (cls != null) return classId(cls).id;
    return libraryId(m.enclosingLibrary).id;
  }

  MaotId memberId(Member m) {
    final owner = _ownerKey(m);
    if (m is Procedure) {
      final id = MaotId('$owner::${_procedureTag(m)}:${nameKey(m.name)}');
      if (m.stubKind != ProcedureStubKind.Regular) {
        return MaotId(id.id,
            stability: IdStability.synthetic,
            caveat: 'front-end synthesized ${m.stubKind.name}; it exists '
                'because of the declarations it forwards to, and is '
                're-derived with them rather than edited directly');
      }
      return id;
    }
    if (m is Constructor) {
      return MaotId('$owner::ctor:${nameKey(m.name)}');
    }
    if (m is Field) {
      return MaotId('$owner::field:${nameKey(m.name)}');
    }
    throw MaotIdentityError(
        'unhandled member kind ${m.runtimeType} for ${m.name.text}; an '
        'unmodelled member must not silently receive a guessed identity');
  }

  // --------------------------------------------------------- type parameters

  /// Type parameters are identified by NAME within their declaration, not by
  /// index, so inserting a parameter does not rename its neighbours.
  ///
  /// An unnamed parameter falls back to its index and is stamped
  /// [IdStability.structural], because a positional id moves when the list
  /// does.
  MaotId typeParameterId(String ownerId, TypeParameter tp, int index) {
    final name = tp.name;
    if (name == null || name.isEmpty) {
      return MaotId('$ownerId::tp#$index',
          stability: IdStability.structural,
          caveat: 'the type parameter has no name, so its id is positional '
              'and moves if the parameter list is reordered');
    }
    return MaotId('$ownerId::tp:$name');
  }

  // ---------------------------------------------------------------- closures

  /// A closure's id is the pre-order index path of function nodes inside the
  /// enclosing member.
  ///
  /// Stated plainly because it is the weakest id here: this is stable while
  /// the nesting and order of function literals in the body is unchanged, and
  /// not otherwise. Callers that need a closure to survive an arbitrary edit
  /// must not build on it -- which is why it is stamped rather than presented
  /// as equivalent to a nominal id.
  MaotId closureId(String memberId, List<int> path) => MaotId(
      '$memberId::closure:${path.join('.')}',
      stability: IdStability.structural,
      caveat: 'positional within the enclosing body; stable only while the '
          'nesting and order of function literals is unchanged');
}
