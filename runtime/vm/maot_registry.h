// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_MAOT_REGISTRY_H_
#define RUNTIME_VM_MAOT_REGISTRY_H_

// The Mutable-AOT implementation registry (MAOT-2, issue #66).
//
// Maps a stable #65 DeclarationId to the implementation the running program
// currently uses. The association is ESTABLISHED AT KERNEL LOAD, where the
// loader holds the Kernel node and the freshly created Function at the same
// time, and it is carried from there into the AOT snapshot. Nothing here ever
// re-derives which Function belongs to which declaration: not by name, not by
// address, not by pool offset, not by kernel offset. That reconstruction step
// is the architecture this program exists to remove.
//
// STORAGE IS NOT THE CONTRACT. Entries live in a GrowableObjectArray rooted in
// the ObjectStore, because Array/String/Function already serialize into the
// snapshot and a new heap class would touch eight files for no semantic gain.
// But no consumer may index that array: the field offsets below are private to
// this class, and everything outside goes through the accessors. #71 is
// expected to replace the storage and the transaction model, and it should be
// able to do that without rewriting every caller.
//
// A Function REFERENCE is the implementation payload. That is not the same as
// using a Function's ADDRESS as identity -- the identity is always the
// DeclarationId string.

#include "vm/allocation.h"
#include "vm/flags.h"
#include "vm/object.h"

namespace dart {

DECLARE_FLAG(charp, maot_dump_registry);
DECLARE_FLAG(charp, maot_namespace);
DECLARE_FLAG(bool, maot_trace_registration);
DECLARE_FLAG(bool, maot_disable_seeding);
DECLARE_FLAG(charp, maot_selftest);
DECLARE_FLAG(bool, maot_disable_constructor_seam);
DECLARE_FLAG(bool, maot_materialize_unselected);
DECLARE_FLAG(charp, maot_dump_registry_precompile);

class MaotRegistry : public AllStatic {
 public:
  // Bump when the entry layout or semantics change. Recorded in the dump so a
  // consumer can refuse a registry it does not understand.
  static constexpr intptr_t kSchemaVersion = 1;

  enum Kind {
    kAot = 0,
    kPatchCode = 1,
  };

  // --- population, at the kernel-load join point -------------------------

  // Records `declaration_id -> function`. Called from KernelLoader while both
  // the Kernel member and the runtime Function are in hand.
  //
  // Refuses a duplicate declaration id: two runtime entities claiming one
  // identity means a later patch binds to the wrong one, so it is a hard
  // failure rather than a last-writer-wins.
  // Returns false on a duplicate declaration id. A bool rather than a FATAL
  // so the gate can OBSERVE the refusal; the production caller still treats
  // false as fatal, because two runtime entities claiming one identity means
  // a later patch binds to the wrong one.
  static bool Register(Thread* thread,
                       const String& declaration_id,
                       bool selected,
                       const Function& implementation,
                       const String& abi_descriptor);

  // The release namespace this registry belongs to (#65 namespace identity).
  // Without it, a declaration spelled the same in a different release would be
  // treated as the same runtime entity.
  static void SetNamespace(Thread* thread, const String& namespace_identity);
  static StringPtr GetNamespace(Thread* thread);

  // --- lookup ------------------------------------------------------------

  // Returns the entry index for `declaration_id`, or -1. Callers outside this
  // class should prefer LookupCurrent.
  static intptr_t IndexOf(Thread* thread, const String& declaration_id);

  // Fills the out-params with the CURRENT descriptor. Returns false when the
  // declaration is not registered -- a missing id is refused, never implicitly
  // created.
  static bool LookupCurrent(Thread* thread,
                            const String& declaration_id,
                            Kind* kind,
                            intptr_t* version,
                            Function* implementation,
                            String* abi_descriptor);

  static bool IsSelected(Thread* thread, const String& declaration_id);

  static intptr_t Length(Thread* thread);

  // --- transient -> final materialization --------------------------------
  //
  // During compilation this table is TRANSIENT: it carries the load-time
  // DeclarationId <-> Function association into the precompiler. It is not
  // the final runtime registry, and it must not decide what the compiler
  // retains -- GC reachability is not the same property as "legally retained
  // by the AOT precompiler". The precompiler consumes selection explicitly
  // via Precompiler::AddFunction, then rebuilds this table from the retained
  // set before serialization.
  static void EntryAt(Thread* thread,
                      intptr_t index,
                      String* declaration_id,
                      bool* selected,
                      Function* implementation,
                      String* abi_descriptor);

  static void Clear(Thread* thread);

  // How many entries' pinned Code no longer matches the Function's current
  // Code. A replacement that rewrites Function::CurrentCode() directly leaves
  // the registry describing an implementation that is no longer running, and
  // "the registry still says AOT v1" is indistinguishable from correct state
  // unless something actually compares the two. When `diverged_id` is given
  // it receives the first such DeclarationId.
  static intptr_t CountDivergedImplementations(Thread* thread,
                                               String* diverged_id = nullptr);

  // Re-reads entry `index`'s Code from its Function. Called once after
  // ProgramVisitor::Dedup, because the Code a descriptor was materialized
  // against may have been merged away by then -- and the descriptor is meant
  // to name the implementation that actually ships. Returns whether the pin
  // changed.
  static bool RepinCurrentCode(Thread* thread, intptr_t index);

  // Recorded so the gate can compare sets, not just counts.
  static void SetMaterializationStats(intptr_t selected,
                                      intptr_t retained,
                                      intptr_t dropped);

  // --- staging -----------------------------------------------------------
  //
  // #66 owns only the state primitive. #71 owns atomic multi-declaration
  // transactions, and these names say so deliberately so this is never
  // mistaken for production transaction semantics.

  // Stages a replacement WITHOUT making it current. Refuses when the ABI
  // descriptor differs from the current one: an incompatible replacement must
  // be rejected before any state changes, not after.
  // `patch_namespace` is CONSUMED, not recorded: a patch built against a
  // different release must be refused before anything is staged, or a
  // same-spelling declaration from another release would be treated as this
  // runtime entity.
  static bool StageReplacement(Thread* thread,
                               const String& declaration_id,
                               Kind kind,
                               intptr_t version,
                               const Function& implementation,
                               const String& abi_descriptor,
                               const String& patch_namespace);

  // Test-only: exercises staging, version, ABI, namespace, duplicate and
  // missing semantics against the live registry and writes structured
  // results. #66 needs the state primitive proven; #71 owns real transactions.
  static void RunSelfTest(Thread* thread, const char* path);

  static bool HasStaged(Thread* thread, const String& declaration_id);

  // Promotes the staged descriptor to current. Test-only: it mutates one entry
  // with no atomicity across declarations, which is exactly what #71 must
  // replace. Refuses when nothing is staged, when the version does not
  // advance, or when the implementation is unchanged -- a version bump that
  // changes nothing, and a change that does not bump the version, are both
  // defects the gate must catch.
  static bool CommitStagedForTesting(Thread* thread,
                                     const String& declaration_id);

  // --- introspection -----------------------------------------------------

  // Writes structured JSON describing logical state. Never emits an address as
  // identity; the implementation is described by its logical relationship, not
  // by where it happens to live.
  static void DumpToFile(Thread* thread, const char* path);

 private:
  // Entry layout. PRIVATE ON PURPOSE -- see the header comment.
  enum EntryField {
    kDeclarationId = 0,   // String
    kSelected,            // Smi 0/1
    kCurrentKind,         // Smi
    kCurrentVersion,      // Smi
    kCurrentImpl,         // Function
    // The Code the descriptor was materialized against. The issue's model
    // asks for a "reference to executable implementation", and a Function is
    // not that: Function::CurrentCode() is a mutable field, so a descriptor
    // that only holds the Function silently follows whatever code is attached
    // to it. Pinning the Code makes divergence observable.
    kCurrentCode,         // Code, or null outside AOT
    kCurrentAbi,          // String
    kStagedKind,          // Smi, or -1 when nothing staged
    kStagedVersion,       // Smi
    kStagedImpl,          // Function or null
    kStagedAbi,           // String or null
    kEntrySize
  };

  static GrowableObjectArrayPtr EnsureStorage(Thread* thread);
  static ObjectPtr FieldAt(Thread* thread, intptr_t entry, EntryField field);
  static void SetFieldAt(Thread* thread,
                         intptr_t entry,
                         EntryField field,
                         const Object& value);
};

}  // namespace dart

#endif  // RUNTIME_VM_MAOT_REGISTRY_H_
