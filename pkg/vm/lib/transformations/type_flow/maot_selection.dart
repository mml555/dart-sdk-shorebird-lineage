// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Mutable-AOT selection, in ONE place (#66/#68).
///
/// Split out of `transformer.dart` because the type-flow analysis itself now
/// has to ask the same question, and two copies of "which declarations are
/// mutable" is precisely how a policy and its enforcement start disagreeing.
library vm.transformations.type_flow.maot_selection;

import 'dart:io' show Platform;

import 'package:kernel/ast.dart';

/// A declaration is mutable when the developer says so with
/// `@pragma('maot:mutable')`.
///
/// Explicit on purpose. An implicit rule -- "everything public", "everything
/// reachable" -- would make the mutable set a consequence of unrelated edits,
/// and #66 requires that an unselected declaration can never become mutable by
/// accident nor a selected one silently vanish.
bool isMaotMutable(Member member) {
  for (final annotation in member.annotations) {
    if (annotation is ConstantExpression) {
      final constant = annotation.constant;
      if (constant is InstanceConstant) {
        final name = constant.classNode.name;
        if (name == 'pragma') {
          for (final entry in constant.fieldValues.entries) {
            final value = entry.value;
            if (value is StringConstant && value.value == 'maot:mutable') {
              return true;
            }
          }
        }
      }
    }
  }
  return false;
}

/// MEASUREMENT ONLY (#68 performance accounting), read once from the
/// environment. An environment variable rather than a VM flag because this
/// code runs inside gen_kernel, which does not take VM flags.
final bool maotSelectAllNonSdk =
    Platform.environment['MAOT_SELECT_ALL_NON_SDK'] == '1';

/// Restricts the scale lane to libraries whose import URI starts with this,
/// so the realistic posture -- an app author marking their OWN declarations
/// mutable -- can be measured next to the upper bound of marking everything.
/// Empty means no restriction.
final String maotSelectUriPrefix =
    Platform.environment['MAOT_SELECT_URI_PREFIX'] ?? '';

/// The scale lane's selection predicate: the same population the pragma path
/// can reach, minus what the registry would skip anyway. An abstract or
/// external member has no AOT body to replace, so counting it would inflate
/// the measurement with declarations the posture never touches.
bool isMaotSelectableAtScale(Member member) {
  final lib = maotEnclosingLibraryOrNull(member);
  if (lib == null) return false;
  if (maotSelectUriPrefix.isNotEmpty &&
      !lib.importUri.toString().startsWith(maotSelectUriPrefix)) {
    return false;
  }
  if (member is Procedure) {
    return !member.isAbstract &&
        !member.isExternal &&
        member.function.body != null;
  }
  if (member is Constructor) {
    return !member.isExternal;
  }
  return false;
}

/// The effective selection predicate, SDK exclusion included so it matches
/// what `collectSelected` actually walks. Anything asking "is this
/// declaration mutable" during analysis must ask through here.
bool isMaotSelected(Member member) {
  final lib = maotEnclosingLibraryOrNull(member);
  if (lib == null) return false;
  if (lib.importUri.isScheme('dart')) return false;
  return maotSelectAllNonSdk
      ? isMaotSelectableAtScale(member)
      : isMaotMutable(member);
}

/// The enclosing library, or null when there is none.
///
/// `Member.enclosingLibrary` casts the walked parent to `Library` and throws
/// when the member is not attached to one. The type-flow analysis reaches
/// members that are not: synthesized signatures and artificial nodes it
/// creates during analysis rather than reads from the component. Measured, not
/// anticipated -- the first version called `enclosingLibrary` directly and
/// gen_kernel died with "type 'Null' is not a subtype of type 'Library'".
///
/// An unattached member is not a declaration anyone can mark mutable, so it is
/// simply not selected.
Library? maotEnclosingLibraryOrNull(Member member) {
  TreeNode? node = member.parent;
  while (node != null && node is! Library) {
    node = node.parent;
  }
  return node is Library ? node : null;
}

/// P1 (#68), ON by default: the production fix for the transitive
/// constant-propagation defect.
///
/// Clears the constant attribute on the result a mutable declaration's
/// summary produces, so the constant never enters any caller's summary. This
/// attacks the escape where it originates rather than refusing the install
/// afterwards, which is what the P3 posture did.
///
/// Measured at the deliberately broad MAOT_SELECT_ALL_NON_SDK upper bound:
/// +0.43% AOT, 444 of 26,590 selected declarations had a constant cleared,
/// and 52 downstream summaries changed out of 10,163.
///
/// Set MAOT_P1_CLEAR_MUTABLE_CONSTANTS=0 to turn it off. That is not a tuning
/// knob -- it is how the falsification arms inject the defect this exists to
/// prevent, and how the P3 fallback would be reached if P1 ever had to be
/// switched off.
final bool maotP1ClearMutableConstants =
    Platform.environment['MAOT_P1_CLEAR_MUTABLE_CONSTANTS'] != '0';

/// Where the P1 prototype writes what it did, for the blast-radius lane.
final String maotP1TracePath =
    Platform.environment['MAOT_P1_TRACE'] ?? '';
