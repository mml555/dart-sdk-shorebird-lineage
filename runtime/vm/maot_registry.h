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
// THE DESCRIPTOR IS NOT A FUNCTION. An earlier version of this comment said "a
// Function reference is the implementation payload", and that turned out to be
// the bug rather than the design:
//
//   DeclarationId            the identity, always, and the only key
//     -> descriptor
//          -> Function       the declaration/runtime-function relationship
//          -> pinned Code    the executable implementation actually shipped
//          -> ABI            Kernel/source-call shape, from the compiler
//          -> call convention  final AOT shape, from the precompiler
//
// Function::CurrentCode() is a mutable field, so a descriptor that held only
// the Function followed whatever code was later attached to it and could never
// report that it had been bypassed. The pinned Code is what makes divergence
// observable. None of this uses an ADDRESS as identity: the identity is the
// DeclarationId string, and the Code is compared for object equality against
// what the Function points at, never parsed for a location.
//
// TWO ABI COMPONENTS, because they are known at different times. The
// Kernel/source-call shape (parameter counts, named sets, type-parameter
// bounds) is known to the front end and rides in as metadata. The final AOT
// calling convention (how many arguments go in registers, and whether each is
// tagged, unboxed int64 or unboxed double) is decided by the VM precompiler
// and does not exist until then -- and `unboxed_parameters_info_` is compiled
// out of DART_PRECOMPILED_RUNTIME entirely, so it cannot be recovered from the
// Function at run time. It is captured at materialization and stored as data.

#include <functional>

#include "vm/allocation.h"
#include "vm/flags.h"
#include "vm/object.h"

namespace dart {

DECLARE_FLAG(charp, maot_dump_registry);
DECLARE_FLAG(charp, maot_probe_resolvers);
DECLARE_FLAG(bool, maot_disable_call_indirection);
DECLARE_FLAG(bool, maot_disable_escape_detection);
DECLARE_FLAG(bool, maot_ignore_escapes_on_install);
DECLARE_FLAG(bool, maot_drop_escape_state_at_materialization);
DECLARE_FLAG(charp, maot_inject_disposition);
DECLARE_FLAG(bool, maot_install_trampolines);
DECLARE_FLAG(bool, maot_trace_serializer);
DECLARE_FLAG(charp, maot_trampoline_only);
DECLARE_FLAG(charp, maot_trampoline_skip);
DECLARE_FLAG(charp, maot_dump_caller_code);
DECLARE_FLAG(bool, maot_dump_trampoline_shape);
DECLARE_FLAG(int, maot_limit_selected);
DECLARE_FLAG(bool, maot_trampoline_class_owner);
DECLARE_FLAG(bool, maot_disable_retention_roots);
DECLARE_FLAG(bool, maot_disable_constant_backstop);
DECLARE_FLAG(bool, maot_force_recognized);
DECLARE_FLAG(bool, maot_allow_inlining_mutable);
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
  // `call_convention` may be empty at kernel-load time: the precompiler has
  // not decided unboxing yet. It is filled in at materialization, which is the
  // first moment the answer exists.
  // `dispatch_cell` is null on first registration (one is created) and is the
  // EXISTING cell when the precompiler re-registers the entry at
  // materialization -- call sites already reference that object.
  static bool Register(Thread* thread,
                       const String& declaration_id,
                       bool selected,
                       const Function& implementation,
                       const String& abi_descriptor,
                       const String& call_convention,
                       const Array& dispatch_cell = Array::null_array(),
                       const String& implementation_id = String::null_string());

  // The final AOT calling-convention shape of `function`, rendered as a
  // canonical string. Derived from what compiler::ComputeCallingConvention
  // actually consumes for a target -- see the implementation for the argument
  // that this set is complete rather than merely plausible.
  static StringPtr ComputeCallConvention(Thread* thread,
                                         const Function& function);

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
                      String* abi_descriptor,
                      String* call_convention = nullptr);

  static void Clear(Thread* thread);

  // --- MAOT-3 (#67): the call-site indirection ----------------------------

  // The dispatch cell a static call to `function` must load from, or null when
  // `function` is not a selected Mutable-AOT declaration.
  //
  // Looked up by OBJECT IDENTITY against the Function the loader bound, not by
  // name, address or any other reconstruction: it is the same object the
  // metadata named. Only meaningful inside the precompiler, where that binding
  // is still in the table.
  // Element indices into the dispatch cell. Named rather than written as
  // bare 0/1 at each site: the compiler emits a field offset computed from
  // these, and an off-by-one there is a branch to whatever object happens to
  // sit in the next slot.
  static constexpr intptr_t kCellImplFunction = 0;
  static constexpr intptr_t kCellImplCode = 1;
  static constexpr intptr_t kCellLength = 2;

  static ArrayPtr DispatchCellForFunction(Thread* thread,
                                          const Function& function);

  // Whether `function` is a selected Mutable-AOT declaration. Used by the
  // inliner to refuse to inline through the mutable boundary.
  static bool IsMutableDeclaration(Thread* thread, const Function& function);

  // --- MAOT-4 (#68): the optimizer decision record ------------------------
  //
  // Every optimizer decision touching a mutable declaration is recorded with
  // a DISPOSITION, and the disposition is what the install path reads. A
  // count alone says how many; it does not say whether any of them was
  // allowed to happen.
  enum Disposition {
    // The optimization would erase the boundary and is refused outright.
    kForbidden = 0,
    // The optimization happened and the resulting path still loads the
    // dispatch cell -- devirtualization into a static call, for instance.
    kSlotPreserving,
    // Allowed only once it carries invalidation state the install path can
    // act on. #68 Phase B; nothing produces this yet -- and because nothing
    // does, it FAILS CLOSED exactly like kUnmodeledBlocking. See
    // BlocksInstallation.
    kDependencyRequired,
    // Nobody has decided. Blocks installation, because "we did not think
    // about it" is not a safety argument.
    kUnmodeledBlocking,
  };

  static const char* DispositionName(Disposition d);

  // Whether a disposition blocks installation. kDependencyRequired does, in
  // Phase A: its own meaning is "allowed once it carries invalidation state
  // the install path can act on", and until that state and its consumer both
  // exist, admitting it would be admitting an optimization on a promise.
  static bool BlocksInstallation(Disposition d);

  // Records one decision. `caller_id` is the caller's #65 DeclarationId when
  // the caller is itself an indexed declaration, and a clearly-labelled
  // diagnostic otherwise -- no decision binds on it.
  static void NoteDecision(Thread* thread,
                           const String& declaration_id,
                           const String& caller_id,
                           const char* optimization_class,
                           const char* decision,
                           Disposition disposition);

  // The DeclarationId bound to `function` whether or not it is selected --
  // kernel loading indexes every member, so a caller has a real #65 identity
  // during compilation even when it is not itself mutable.
  static StringPtr AnyDeclarationIdOf(Thread* thread,
                                      const Function& function);

  static intptr_t DecisionCount(Thread* thread);
  static void ClearDecisions(Thread* thread);

  // MAOT-4 (#68): records that a compiler decision may have produced an
  // executable path which does not consult the dispatch cell. Any escape
  // makes the declaration un-installable until #68 Phase B gives the
  // optimization machine-consumed invalidation state.
  static void NoteEscape(Thread* thread,
                         const Function& function,
                         const char* reason);
  static void NoteEscapeById(Thread* thread,
                             const String& declaration_id,
                             const char* reason);
  static intptr_t EscapeCountFor(Thread* thread, const String& declaration_id);

  // Escape accounting is gathered DURING code generation and therefore has to
  // survive the rebuild of the table at materialization -- the call-site
  // counter had to learn the same lesson.
  static void EscapeStateFor(Thread* thread,
                             const Function& function,
                             intptr_t* count,
                             String* reason);
  static void SetEscapeStateFor(Thread* thread,
                                const String& declaration_id,
                                intptr_t count,
                                const String& reason);

  // The DeclarationId bound to `function`, or null when it is not a selected
  // Mutable-AOT declaration.
  static StringPtr DeclarationIdOf(Thread* thread, const Function& function);

  // Records that one more indirect call site was emitted for `function`.
  static void NoteCallSiteEmitted(Thread* thread, const Function& function);
  // Records an inliner verdict for a mutable callee. `admitted` false means
  // the MAOT rule refused it; true means the falsification control let it
  // through, which additionally records an escape so installation fails
  // closed rather than silently producing a stale caller.
  static void NoteInlineVerdict(Thread* thread,
                                const Function& callee,
                                bool admitted);
  static void InlineCountsFor(Thread* thread,
                              const Function& function,
                              intptr_t* refusals,
                              intptr_t* admissions);
  // Restores counts across the materialization rebuild. The inliner runs
  // during compilation; the final table is rebuilt afterwards, so a count
  // that is not carried is a count that reports zero for a declaration the
  // inliner refused eleven times -- the same defect the call-site count hit.
  // MAOT-5 (#69). Hands every pinned Code in the registry to `canonicalize`
  // and stores what comes back. Called from ProgramVisitor::Dedup, which is
  // where the dispatch table is canonicalized for the same reason.
  //
  // The registry is the ONLY holder of a mutable declaration's body Code once
  // its Function carries the trampoline, so a pin left pre-dedup keeps two
  // Code objects with identical Instructions reachable and the serializer
  // refuses that outright. Re-deriving the body from the Function is not an
  // option after Stage 2: CurrentCode() is the trampoline by then, and
  // re-deriving would point the cell's Code half at the trampoline, which
  // then branches to itself.
  static FunctionPtr CurrentImplAt(Thread* thread, intptr_t entry);
  static ArrayPtr DispatchCellAt(Thread* thread, intptr_t entry);
  static CodePtr CellImplCodeAt(Thread* thread, intptr_t entry);
  static StringPtr DeclarationIdAt(Thread* thread, intptr_t entry);
  // Records what DoUnlinkedCallAOT actually installed: the flag as read and
  // the class id of the resulting state object.
  static void NoteUnlinkedTransition(bool can_patch_to_monomorphic,
                                     intptr_t resulting_cid);
  static intptr_t UnlinkedTransitionCount(bool can_patch_to_monomorphic,
                                          intptr_t resulting_cid);
  static intptr_t NoteSwitchableStateHit(const char* state, bool converges);
  static intptr_t SwitchableStateHits(const char* state);
  static intptr_t SwitchableStateDivergences(const char* state);
  static bool ShouldRecordSwitchableState(intptr_t hit_number);
  static bool IsTrampolineCode(Thread* thread, ObjectPtr code);
  static void BlockingRecordsFor(Thread* thread,
                                 const String& declaration_id,
                                 BaseTextBuffer* out);

  // True when writing `impl_code` into this entry's cell would make its own
  // trampoline branch to itself. Checked at every cell write.
  static bool CellCodeWouldSelfCycle(Thread* thread,
                                     intptr_t entry,
                                     const Object& impl_code);
  static void SetTrampolineFor(Thread* thread,
                               intptr_t entry,
                               const Code& trampoline);
  static CodePtr TrampolineAt(Thread* thread, intptr_t entry);
  static intptr_t CellPoolIndexAt(Thread* thread, intptr_t entry);
  static void SetCellPoolIndexAt(Thread* thread,
                                 intptr_t entry,
                                 intptr_t index);
  // The seeded pool index for a function's cell, or -1.
  static intptr_t CellPoolIndexForFunction(Thread* thread,
                                           const Function& function);

  static void CanonicalizeCodePins(
      Thread* thread,
      Zone* zone,
      const std::function<CodePtr(const Code&)>& canonicalize);

  static void SetInlineCountsFor(Thread* thread,
                                 const String& declaration_id,
                                 intptr_t refusals,
                                 intptr_t admissions);

  // Compiler-path evidence, gathered during code generation and therefore
  // carried across the rebuild of the table at materialization.
  static intptr_t CallSiteCountFor(Thread* thread, const Function& function);
  static void SetCallSiteCountFor(Thread* thread,
                                  const String& declaration_id,
                                  intptr_t count);

  // Installs `implementation` as the current implementation of
  // `declaration_id` at `version`: stages through the normal compatibility
  // checks and then commits. Returns 0 on success, or a negative code saying
  // which check refused. Test-only entry point for the #67 harness -- #71 owns
  // real transactions.
  static intptr_t InstallForTesting(Thread* thread,
                                    const String& declaration_id,
                                    const String& implementation_id,
                                    intptr_t version,
                                    const String& patch_namespace);

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
                               const String& call_convention,
                               const String& patch_namespace,
                               const String& implementation_id =
                                   String::null_string());

  // Test-only: drops whatever is staged for `declaration_id` without
  // promoting it. The pairwise compatibility matrix in the self-test has to
  // attempt a real StageReplacement for every ordered pair -- a separate
  // "would this be accepted" predicate would be a second code path, and the
  // one that matters is the one production uses.
  static void AbandonStagedForTesting(Thread* thread,
                                      const String& declaration_id);

  // TEST-ONLY, AND DELIBERATELY WRONG. Resolves by the implementation
  // Function's NAME instead of by DeclarationId -- the exact defect the gate
  // has to be able to catch. Production lookup is IndexOf(), which is keyed on
  // the DeclarationId string and never on a name; this exists so the gate can
  // inject the name-keyed resolver against the real registry and show that the
  // resulting aliasing is refused. Returns the index it lands on, or -1.
  static intptr_t LookupByFunctionNameForFalsification(Thread* thread,
                                                       const String& name);

  // Writes the resolution probes -- the production DeclarationId resolver and
  // the deliberately name-keyed one -- over a PRISTINE registry. Must run in a
  // process that has not staged or committed anything; RunSelfTest has by
  // design, so the two cannot share an invocation.
  static void WriteResolutionProbes(Thread* thread, const char* path);

  // Whether anything in the registry has been staged or advanced past its
  // release state. Reported rather than asserted, so a consumer can refuse
  // evidence instead of trusting a flag the runtime set about itself.
  static bool AnyEntryHasStagedOrAdvanced(Thread* thread);

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
    kCurrentAbi,          // String -- Kernel/source-call shape
    kCurrentCallConv,     // String -- final AOT calling-convention shape
    // MAOT-3 (#67). The one-element Array that COMPILED CALL SITES load from.
    // It is part of the descriptor, not a separate mechanism: the only thing
    // that writes it is this class's mutation API, so installing a
    // replacement is a #66 state change and never a patch of machine bytes.
    // A call site references this object directly, from the object pool,
    // established while the Kernel binding was authoritative -- it is never
    // re-found.
    // MAOT-5 (#69). Array(2): [0] the implementation Function, [1] the
    // pinned executable Code for it.
    //
    // The Function alone is not the executable implementation -- #66 proved
    // that and pins the Code for exactly this reason. #69 needs the second
    // half in the CELL rather than only in the descriptor, because the
    // trampoline that instance dispatch resolves through must branch to a
    // CODE. Branching through cell[0]'s Function entry point would re-enter
    // the trampoline itself: the declaration Function's own CurrentCode IS
    // the trampoline, so the load returns to where it came from and every
    // mutable call recurses forever.
    //
    // Both halves advance together on installation. Neither is authoritative
    // alone: the Function half carries the VM calling convention, the Code
    // half is what actually executes.
    kDispatchCell,        // Array(2): [impl Function, impl Code]
    // The release implementation, captured once and never overwritten, so a
    // replaced declaration can still say what it shipped as. #71 owns real
    // version history; this is the one entry that history will need.
    kReleaseImpl,         // Function
    kReleaseCode,         // Code, or null
    // How many Mutable-AOT indirect call sites the compiler emitted for this
    // declaration. Compiler-path evidence: zero means every caller bound
    // somewhere else, whatever the program prints.
    kCallSiteCount,       // Smi
    // WHICH declaration currently supplies the implementation, as a #65
    // DeclarationId rather than a Function name. A name diagnostic is a
    // spelling; two declarations can share one, and #66 spent an arm proving
    // that. The install path knows the replacement's identity, so the
    // descriptor records it.
    kCurrentImplId,       // String
    kReleaseImplId,       // String
    kStagedImplId,        // String or null
    // MAOT-4 (#68). How many compiler decisions were made that could let a
    // caller reach an implementation without consulting the dispatch cell,
    // and why the first of them happened.
    //
    // This is NOT a statistic. StageReplacement refuses while it is non-zero,
    // so an escape is a fail-closed install refusal rather than a number in a
    // log -- which is the difference between evidence and decoration.
    kEscapeCount,         // Smi
    kEscapeReason,        // String or null
    // MAOT-4 (#68). How many times the AOT inliner considered this
    // declaration as a callee and REFUSED it, and how many times it took it.
    //
    // Two consumers, in opposite directions:
    //   * refusals > 0 is the precondition for the injected-inlining
    //     falsification. Without it, "inlining was prevented" is a claim
    //     about a callee no inliner ever looked at -- an arm that cannot run
    //     is not an arm that passed.
    //   * admissions must be 0 in any shipped build. A non-zero admission
    //     means a caller holds a copy that no dispatch cell mediates, so it
    //     is recorded as an ESCAPE too and StageReplacement fails closed on
    //     it. The counter is the measurement; the escape is the enforcement.
    kInlineRefusalCount,  // Smi
    kInlineAdmissionCount,  // Smi
    // MAOT-5 (#69). The trampoline installed as this declaration Function's
    // CurrentCode, so instance dispatch -- which resolves through
    // Function::CurrentCode() for the dispatch table and every switchable
    // call state -- reaches the cell instead of a frozen body address.
    //
    // Recorded because its presence CHANGES WHAT REPINNING MEANS. While it is
    // null, a descriptor's pinned Code is whatever the Function points at.
    // Once it is set, the Function points at the trampoline and the body is
    // reachable only from the registry's own pins, which are canonicalized in
    // ProgramVisitor::Dedup rather than rederived here.
    kTrampolineCode,      // Code, or null
    // MAOT-5 (#69). The ONE canonical global-object-pool index for this
    // declaration's cell, seeded while the pool builder is still live.
    //
    // Pool membership is a property of BEING SELECTED, not a side effect of
    // #67's static-call lowering having happened to run. A purely virtual
    // declaration has no static call site, so nothing ever added its cell to
    // the pool, so no trampoline could name it -- which is exactly why
    // virtual routing had nothing to route through.
    //
    // Both consumers read this one index: #67's call-site lowering and #69's
    // trampoline. There is deliberately no second registration path.
    kCellPoolIndex,       // Smi, -1 when unseeded
    kStagedKind,          // Smi, or -1 when nothing staged
    kStagedVersion,       // Smi
    kStagedImpl,          // Function or null
    kStagedAbi,           // String or null
    kStagedCallConv,      // String or null
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
