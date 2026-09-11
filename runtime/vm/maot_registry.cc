// Copyright (c) 2026, the Shorebird authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/maot_registry.h"

#include "vm/dart_api_state.h"
#include "vm/flags.h"
#include "vm/isolate.h"
#include "vm/json_writer.h"
#include "vm/object_store.h"
#include "vm/thread.h"
#include "vm/zone_text_buffer.h"

namespace dart {

DEFINE_FLAG(charp,
            maot_dump_registry_precompile,
            nullptr,
            "Write the registry as the precompiler sees it, before snapshot "
            "serialization (diagnostic).");

DEFINE_FLAG(bool,
            maot_disable_constructor_seam,
            false,
            "FALSIFICATION CONTROL. Skip binding at the constructor creation "
            "seam, so a selected constructor silently has no slot while every "
            "ordinary procedure still succeeds.");

DEFINE_FLAG(bool,
            maot_materialize_unselected,
            false,
            "FALSIFICATION CONTROL. Let unselected declarations into the "
            "final registry, which must never happen: a slot is an "
            "authoritative promise of mutability.");

DEFINE_FLAG(charp,
            maot_selftest,
            nullptr,
            "Run the registry state self-test and write structured results "
            "to this path (test-only).");

DEFINE_FLAG(bool,
            maot_disable_seeding,
            false,
            "FALSIFICATION CONTROL. Skip feeding selected declarations into "
            "the precompiler's retention/compilation worklist, while leaving "
            "binding and the registry intact. Proves that registry existence "
            "is not sufficient: without the retention root a selected "
            "declaration reaches materialization with no executable body and "
            "must be refused.");

DEFINE_FLAG(bool,
            maot_trace_registration,
            false,
            "Trace each Mutable-AOT registry registration (diagnostic).");

DEFINE_FLAG(charp,
            maot_namespace,
            nullptr,
            "The #65 release namespace identity this snapshot's Mutable-AOT "
            "registry belongs to. Baked in at snapshot time and serialized, so "
            "the running program can answer which release it is without "
            "consulting an external sidecar.");

DEFINE_FLAG(charp,
            maot_dump_registry,
            nullptr,
            "Write the Mutable-AOT implementation registry to this path as "
            "JSON at isolate group startup (test-only introspection).");

GrowableObjectArrayPtr MaotRegistry::EnsureStorage(Thread* thread) {
  auto* object_store = thread->isolate_group()->object_store();
  if (object_store->maot_registry() == GrowableObjectArray::null()) {
    object_store->set_maot_registry(
        GrowableObjectArray::Handle(thread->zone(),
                                    GrowableObjectArray::New(Heap::kOld)));
  }
  if (object_store->maot_namespace() == String::null() &&
      FLAG_maot_namespace != nullptr) {
    object_store->set_maot_namespace(String::Handle(
        thread->zone(), String::New(FLAG_maot_namespace, Heap::kOld)));
  }
  return object_store->maot_registry();
}

ObjectPtr MaotRegistry::FieldAt(Thread* thread,
                                intptr_t entry,
                                EntryField field) {
  const auto& storage =
      GrowableObjectArray::Handle(thread->zone(), EnsureStorage(thread));
  return storage.At(entry * kEntrySize + field);
}

void MaotRegistry::SetFieldAt(Thread* thread,
                              intptr_t entry,
                              EntryField field,
                              const Object& value) {
  const auto& storage =
      GrowableObjectArray::Handle(thread->zone(), EnsureStorage(thread));
  storage.SetAt(entry * kEntrySize + field, value);
}

intptr_t MaotRegistry::Length(Thread* thread) {
  const auto& storage =
      GrowableObjectArray::Handle(thread->zone(), EnsureStorage(thread));
  return storage.Length() / kEntrySize;
}

static intptr_t maot_stat_selected = -1;
static intptr_t maot_stat_retained = -1;
static intptr_t maot_stat_dropped = -1;

void MaotRegistry::SetMaterializationStats(intptr_t selected,
                                           intptr_t retained,
                                           intptr_t dropped) {
  maot_stat_selected = selected;
  maot_stat_retained = retained;
  maot_stat_dropped = dropped;
}

void MaotRegistry::EntryAt(Thread* thread,
                           intptr_t index,
                           String* declaration_id,
                           bool* selected,
                           Function* implementation,
                           String* abi_descriptor) {
  *declaration_id = String::RawCast(FieldAt(thread, index, kDeclarationId));
  *selected = Smi::Value(Smi::RawCast(FieldAt(thread, index, kSelected))) == 1;
  *implementation = Function::RawCast(FieldAt(thread, index, kCurrentImpl));
  *abi_descriptor = String::RawCast(FieldAt(thread, index, kCurrentAbi));
}

void MaotRegistry::Clear(Thread* thread) {
  // SetLength(0) is NOT enough here, and the difference is not cosmetic.
  //
  // A GrowableObjectArray's backing Array keeps its full capacity, and every
  // slot past the new length still holds the old pointer. The GC and the
  // snapshot serializer both walk the BACKING ARRAY, not the logical length,
  // so a Function cleared this way stays reachable from an ObjectStore root.
  // In the precompiler that resurrects Functions whose owner Class the drop
  // phase has already removed from the class table, and the serializer then
  // aborts with "Unexpected object (Class with illegal cid, full-aot)" --
  // which is exactly how this was found, on a program that selected nothing
  // at all.
  //
  // Replacing the storage outright is the only form that leaves no slot
  // holding anything: it is the array itself that has to go, not its length.
  thread->isolate_group()->object_store()->set_maot_registry(
      GrowableObjectArray::Handle(thread->zone(),
                                  GrowableObjectArray::New(Heap::kOld)));
}

intptr_t MaotRegistry::IndexOf(Thread* thread, const String& declaration_id) {
  Zone* zone = thread->zone();
  const auto& storage = GrowableObjectArray::Handle(zone, EnsureStorage(thread));
  auto& candidate = String::Handle(zone);
  const intptr_t entries = storage.Length() / kEntrySize;
  for (intptr_t i = 0; i < entries; i++) {
    candidate ^= storage.At(i * kEntrySize + kDeclarationId);
    if (candidate.Equals(declaration_id)) {
      return i;
    }
  }
  return -1;
}

bool MaotRegistry::Register(Thread* thread,
                            const String& declaration_id,
                            bool selected,
                            const Function& implementation,
                            const String& abi_descriptor) {
  Zone* zone = thread->zone();
  if (IndexOf(thread, declaration_id) >= 0) {
    return false;  // duplicate: the caller decides how loudly to fail
  }
  if (FLAG_maot_trace_registration) {
    OS::PrintErr("[maot] register id=%s selected=%d fn=%s\n",
                 declaration_id.ToCString(), selected ? 1 : 0,
                 implementation.ToCString());
  }
  const auto& storage = GrowableObjectArray::Handle(zone, EnsureStorage(thread));
  storage.Add(declaration_id, Heap::kOld);
  storage.Add(Smi::Handle(zone, Smi::New(selected ? 1 : 0)), Heap::kOld);
  storage.Add(Smi::Handle(zone, Smi::New(kAot)), Heap::kOld);
  storage.Add(Smi::Handle(zone, Smi::New(1)), Heap::kOld);
  storage.Add(implementation, Heap::kOld);
  // Pin the Code the descriptor is being made against. Function::CurrentCode()
  // is a mutable field, so a descriptor that holds only the Function follows
  // whatever is later attached to it and can never report that it has been
  // bypassed.
  storage.Add(implementation.IsNull() || !implementation.HasCode()
                  ? Object::null_object()
                  : Object::Handle(zone, implementation.CurrentCode()),
              Heap::kOld);
  storage.Add(abi_descriptor, Heap::kOld);
  storage.Add(Smi::Handle(zone, Smi::New(-1)), Heap::kOld);  // staged kind
  storage.Add(Smi::Handle(zone, Smi::New(0)), Heap::kOld);   // staged version
  storage.Add(Object::null_object(), Heap::kOld);            // staged impl
  storage.Add(Object::null_object(), Heap::kOld);            // staged abi
  return true;
}

bool MaotRegistry::RepinCurrentCode(Thread* thread, intptr_t index) {
  Zone* zone = thread->zone();
  const auto& fn =
      Function::Handle(zone, Function::RawCast(FieldAt(thread, index,
                                                       kCurrentImpl)));
  const auto& before = Object::Handle(zone, FieldAt(thread, index,
                                                    kCurrentCode));
  const auto& now = Object::Handle(zone,
      fn.IsNull() || !fn.HasCode() ? Object::null() : fn.CurrentCode());
  if (before.ptr() == now.ptr()) return false;
  SetFieldAt(thread, index, kCurrentCode, now);
  return true;
}

intptr_t MaotRegistry::CountDivergedImplementations(Thread* thread,
                                                    String* diverged_id) {
  Zone* zone = thread->zone();
  const intptr_t entries = Length(thread);
  auto& fn = Function::Handle(zone);
  auto& pinned = Object::Handle(zone);
  auto& id = String::Handle(zone);
  intptr_t diverged = 0;
  for (intptr_t i = 0; i < entries; i++) {
    fn ^= FieldAt(thread, i, kCurrentImpl);
    pinned = FieldAt(thread, i, kCurrentCode);
    if (pinned.IsNull()) continue;  // nothing was pinned; nothing to compare
    const bool same = !fn.IsNull() && fn.HasCode() &&
                      fn.CurrentCode() == Code::RawCast(pinned.ptr());
    if (!same) {
      if (diverged == 0 && diverged_id != nullptr) {
        id ^= FieldAt(thread, i, kDeclarationId);
        *diverged_id = id.ptr();
      }
      diverged++;
    }
  }
  return diverged;
}

void MaotRegistry::SetNamespace(Thread* thread,
                                const String& namespace_identity) {
  thread->isolate_group()->object_store()->set_maot_namespace(
      namespace_identity);
}

StringPtr MaotRegistry::GetNamespace(Thread* thread) {
  return thread->isolate_group()->object_store()->maot_namespace();
}

bool MaotRegistry::LookupCurrent(Thread* thread,
                                 const String& declaration_id,
                                 Kind* kind,
                                 intptr_t* version,
                                 Function* implementation,
                                 String* abi_descriptor) {
  const intptr_t entry = IndexOf(thread, declaration_id);
  if (entry < 0) return false;
  Zone* zone = thread->zone();
  if (kind != nullptr) {
    *kind = static_cast<Kind>(
        Smi::Value(Smi::RawCast(FieldAt(thread, entry, kCurrentKind))));
  }
  if (version != nullptr) {
    *version =
        Smi::Value(Smi::RawCast(FieldAt(thread, entry, kCurrentVersion)));
  }
  if (implementation != nullptr) {
    *implementation =
        Function::RawCast(FieldAt(thread, entry, kCurrentImpl));
  }
  if (abi_descriptor != nullptr) {
    *abi_descriptor = String::RawCast(FieldAt(thread, entry, kCurrentAbi));
  }
  USE(zone);
  return true;
}

bool MaotRegistry::IsSelected(Thread* thread, const String& declaration_id) {
  const intptr_t entry = IndexOf(thread, declaration_id);
  if (entry < 0) return false;
  return Smi::Value(Smi::RawCast(FieldAt(thread, entry, kSelected))) == 1;
}

bool MaotRegistry::StageReplacement(Thread* thread,
                                    const String& declaration_id,
                                    Kind kind,
                                    intptr_t version,
                                    const Function& implementation,
                                    const String& abi_descriptor,
                                    const String& patch_namespace) {
  const intptr_t entry = IndexOf(thread, declaration_id);
  if (entry < 0) return false;  // missing id is refused, never created

  Zone* zone = thread->zone();
  // The release this patch was built against must be THIS release.
  const auto& ns = String::Handle(zone, GetNamespace(thread));
  if (ns.IsNull() || !ns.Equals(patch_namespace)) return false;
  // ABI compatibility is decided BEFORE anything changes. An incompatible
  // replacement must never leave the entry half-updated.
  const auto& current_abi =
      String::Handle(zone, String::RawCast(FieldAt(thread, entry, kCurrentAbi)));
  if (!current_abi.Equals(abi_descriptor)) {
    return false;
  }
  const intptr_t current_version =
      Smi::Value(Smi::RawCast(FieldAt(thread, entry, kCurrentVersion)));
  if (version <= current_version) {
    return false;  // a replacement must advance the version
  }

  SetFieldAt(thread, entry, kStagedKind,
             Smi::Handle(zone, Smi::New(static_cast<intptr_t>(kind))));
  SetFieldAt(thread, entry, kStagedVersion,
             Smi::Handle(zone, Smi::New(version)));
  SetFieldAt(thread, entry, kStagedImpl, implementation);
  SetFieldAt(thread, entry, kStagedAbi, abi_descriptor);
  return true;
}

bool MaotRegistry::HasStaged(Thread* thread, const String& declaration_id) {
  const intptr_t entry = IndexOf(thread, declaration_id);
  if (entry < 0) return false;
  return Smi::Value(Smi::RawCast(FieldAt(thread, entry, kStagedKind))) >= 0;
}

bool MaotRegistry::CommitStagedForTesting(Thread* thread,
                                          const String& declaration_id) {
  const intptr_t entry = IndexOf(thread, declaration_id);
  if (entry < 0) return false;
  Zone* zone = thread->zone();

  const intptr_t staged_kind =
      Smi::Value(Smi::RawCast(FieldAt(thread, entry, kStagedKind)));
  if (staged_kind < 0) return false;  // nothing staged

  const intptr_t staged_version =
      Smi::Value(Smi::RawCast(FieldAt(thread, entry, kStagedVersion)));
  const intptr_t current_version =
      Smi::Value(Smi::RawCast(FieldAt(thread, entry, kCurrentVersion)));
  if (staged_version <= current_version) return false;

  const auto& staged_impl =
      Object::Handle(zone, FieldAt(thread, entry, kStagedImpl));
  const auto& current_impl =
      Object::Handle(zone, FieldAt(thread, entry, kCurrentImpl));
  if (staged_impl.ptr() == current_impl.ptr()) {
    // A version bump with no implementation change is not a replacement.
    return false;
  }

  SetFieldAt(thread, entry, kCurrentKind,
             Smi::Handle(zone, Smi::New(staged_kind)));
  SetFieldAt(thread, entry, kCurrentVersion,
             Smi::Handle(zone, Smi::New(staged_version)));
  SetFieldAt(thread, entry, kCurrentImpl, staged_impl);
  // Re-pin: after a commit the descriptor describes the staged
  // implementation, so the Code it is compared against has to move with it.
  const auto& staged_fn = Function::Handle(zone,
      staged_impl.IsFunction() ? Function::Cast(staged_impl).ptr()
                               : Function::null());
  SetFieldAt(thread, entry, kCurrentCode,
             staged_fn.IsNull() || !staged_fn.HasCode()
                 ? Object::null_object()
                 : Object::Handle(zone, staged_fn.CurrentCode()));
  SetFieldAt(thread, entry, kCurrentAbi,
             Object::Handle(zone, FieldAt(thread, entry, kStagedAbi)));

  SetFieldAt(thread, entry, kStagedKind, Smi::Handle(zone, Smi::New(-1)));
  SetFieldAt(thread, entry, kStagedVersion, Smi::Handle(zone, Smi::New(0)));
  SetFieldAt(thread, entry, kStagedImpl, Object::null_object());
  SetFieldAt(thread, entry, kStagedAbi, Object::null_object());
  return true;
}


// ---------------------------------------------------------------------------
// Test-only self-test. #66 needs the STATE primitive proven -- staging,
// version, ABI, namespace, duplicate and missing semantics -- not execution
// of replacement code. #67 owns execution; #71 owns real transactions.
//
// Every arm records what it expected and what it observed, so the Shorebird
// gate derives the verdict from the observations rather than from a summary
// this file writes about itself.
// ---------------------------------------------------------------------------
void MaotRegistry::RunSelfTest(Thread* thread, const char* path) {
  Zone* zone = thread->zone();
  JSONWriter w;
  w.OpenObject();
  w.PrintProperty("schema", "maot.registry.selftest/1");

  const auto& ns = String::Handle(zone, GetNamespace(thread));
  w.PrintProperty("namespace_identity",
                  ns.IsNull() ? "<absent>" : ns.ToCString());

  const intptr_t n = Length(thread);
  w.PrintProperty64("entry_count", n);

  // Two entries with the SAME ABI are needed for a positive staging arm, and
  // one with a DIFFERENT ABI for the mismatch arm. Pick them by inspection
  // rather than by hard-coding names.
  auto& id_a = String::Handle(zone);
  auto& abi_a = String::Handle(zone);
  auto& fn_a = Function::Handle(zone);
  auto& id_b = String::Handle(zone);
  auto& abi_b = String::Handle(zone);
  auto& fn_b = Function::Handle(zone);
  auto& id_x = String::Handle(zone);
  auto& abi_x = String::Handle(zone);
  auto& fn_x = Function::Handle(zone);
  bool sel = false;
  bool have_pair = false, have_mismatch = false;

  for (intptr_t i = 0; i < n && !have_pair; i++) {
    EntryAt(thread, i, &id_a, &sel, &fn_a, &abi_a);
    for (intptr_t j = 0; j < n; j++) {
      if (i == j) continue;
      EntryAt(thread, j, &id_b, &sel, &fn_b, &abi_b);
      if (abi_a.Equals(abi_b)) { have_pair = true; break; }
    }
    if (!have_pair) EntryAt(thread, i, &id_a, &sel, &fn_a, &abi_a);
  }
  for (intptr_t i = 0; i < n && have_pair && !have_mismatch; i++) {
    EntryAt(thread, i, &id_x, &sel, &fn_x, &abi_x);
    if (!abi_x.Equals(abi_a)) have_mismatch = true;
  }

  w.PrintPropertyBool("found_same_abi_pair", have_pair);
  w.PrintPropertyBool("found_different_abi_entry", have_mismatch);

  auto arm = [&](const char* id, const char* expected, bool ok,
                 const char* observed) {
    w.OpenObject();
    w.PrintProperty("id", id);
    w.PrintProperty("expected", expected);
    w.PrintProperty("observed", observed);
    w.PrintProperty("result", ok ? "pass" : "FAIL");
    w.CloseObject();
  };

  w.OpenArray("arms");

  Kind kind = kAot;
  intptr_t version = 0;
  auto& impl = Function::Handle(zone);
  auto& abi = String::Handle(zone);

  if (have_pair) {
    // S01 -- the initial descriptor is the release implementation.
    bool found = LookupCurrent(thread, id_a, &kind, &version, &impl, &abi);
    const bool s01 = found && kind == kAot && version == 1 && !impl.IsNull();
    arm("S01", "current is AOT v1 with an implementation", s01,
        s01 ? "AOT v1 present" : "not as expected");

    // S02 -- staging must not be visible through the current lookup.
    const bool staged_ok = StageReplacement(thread, id_a, kPatchCode, 2, fn_b,
                                            abi_a, ns);
    LookupCurrent(thread, id_a, &kind, &version, &impl, &abi);
    const bool s02 = staged_ok && kind == kAot && version == 1;
    arm("S02", "stage PATCH_CODE v2; current still AOT v1", s02,
        staged_ok ? (s02 ? "staged, current unchanged"
                         : "staged but current CHANGED")
                  : "staging refused");
    arm("S03", "HasStaged reports the pending replacement",
        HasStaged(thread, id_a), HasStaged(thread, id_a) ? "true" : "false");

    // V01 -- a replacement must advance the version.
    const bool v01 = !StageReplacement(thread, id_a, kPatchCode, 1, fn_b,
                                       abi_a, ns);
    arm("V01", "staging at or below the current version is refused", v01,
        v01 ? "refused" : "ACCEPTED");

    // A01 -- an incompatible ABI is refused BEFORE anything changes.
    if (have_mismatch) {
      const bool a01 = !StageReplacement(thread, id_a, kPatchCode, 3, fn_x,
                                         abi_x, ns);
      LookupCurrent(thread, id_a, &kind, &version, &impl, &abi);
      arm("A01", "ABI mismatch refused, current untouched",
          a01 && kind == kAot && version == 1,
          a01 ? "refused" : "ACCEPTED");
    }

    // N01 -- a patch from another release is refused.
    const auto& wrong_ns =
        String::Handle(zone, String::New("0000000000000000", Heap::kOld));
    const bool n01 =
        !StageReplacement(thread, id_a, kPatchCode, 3, fn_b, abi_a, wrong_ns);
    arm("N01", "wrong release namespace refused", n01,
        n01 ? "refused" : "ACCEPTED");

    // S04 -- the explicit test-only mutation makes the staged one current.
    const bool committed = CommitStagedForTesting(thread, id_a);
    LookupCurrent(thread, id_a, &kind, &version, &impl, &abi);
    const bool s04 = committed && kind == kPatchCode && version == 2;
    arm("S04", "commit promotes staged to current", s04,
        committed ? (s04 ? "current is PATCH_CODE v2" : "commit did not apply")
                  : "commit refused");

    // V02 -- nothing staged means nothing to commit.
    const bool v02 = !CommitStagedForTesting(thread, id_a);
    arm("V02", "commit with nothing staged is refused", v02,
        v02 ? "refused" : "ACCEPTED");

    // V03 -- a version bump that changes no implementation is not a
    // replacement.
    LookupCurrent(thread, id_a, &kind, &version, &impl, &abi);
    StageReplacement(thread, id_a, kPatchCode, version + 1, impl, abi, ns);
    const bool v03 = !CommitStagedForTesting(thread, id_a);
    arm("V03", "version bump with the same implementation is refused", v03,
        v03 ? "refused" : "ACCEPTED");
  }

  // M01/M02 -- an unknown declaration is refused, never implicitly created.
  const auto& unknown =
      String::Handle(zone, String::New("lib:package:none/x.dart::fn:absent",
                                       Heap::kOld));
  const bool m01 = !LookupCurrent(thread, unknown, nullptr, nullptr, nullptr,
                                  nullptr);
  arm("M01", "lookup of an unknown id is refused", m01,
      m01 ? "refused" : "FOUND");
  const bool m02 =
      !StageReplacement(thread, unknown, kPatchCode, 2, fn_a, abi_a, ns);
  const bool m02b = IndexOf(thread, unknown) < 0;
  arm("M02", "staging an unknown id refuses and creates nothing",
      m02 && m02b, (m02 && m02b) ? "refused, not created" : "created or accepted");

  // D01 -- a duplicate registration is refused.
  const bool d01 = have_pair ? !Register(thread, id_a, true, fn_a, abi_a) : false;
  arm("D01", "duplicate registration is refused", d01,
      d01 ? "refused" : "ACCEPTED");

  // A01' -- the same declaration id spelled from a different release is a
  // different entity. Covered by N01; kept adjacent for readability.

  // L01 -- two declarations that share a VM Function NAME but differ in
  // DeclarationId must not resolve to one another. The issue asks the gate to
  // catch "lookup that accidentally succeeds by function name while
  // declaration IDs differ", and a lookup keyed by identity can only be shown
  // to be keyed by identity when two entries exist that a name-keyed lookup
  // would confuse.
  auto& name_i = String::Handle(zone);
  auto& name_j = String::Handle(zone);
  auto& id_i = String::Handle(zone);
  auto& id_j = String::Handle(zone);
  auto& fn_i = Function::Handle(zone);
  auto& fn_j = Function::Handle(zone);
  auto& abi_ij = String::Handle(zone);
  bool have_name_clash = false;
  for (intptr_t i = 0; i < n && !have_name_clash; i++) {
    EntryAt(thread, i, &id_i, &sel, &fn_i, &abi_ij);
    if (fn_i.IsNull()) continue;
    name_i = fn_i.name();
    for (intptr_t j = i + 1; j < n; j++) {
      EntryAt(thread, j, &id_j, &sel, &fn_j, &abi_ij);
      if (fn_j.IsNull()) continue;
      name_j = fn_j.name();
      if (name_i.Equals(name_j) && !id_i.Equals(id_j)) {
        have_name_clash = true;
        break;
      }
    }
  }
  // NOT here: this is inside the arms array, and a property emitted between
  // array elements produces JSON that no reader can parse. It is printed
  // after the array closes.
  if (have_name_clash) {
    Kind k_i = kAot, k_j = kAot;
    intptr_t v_i = 0, v_j = 0;
    auto& impl_i = Function::Handle(zone);
    auto& impl_j = Function::Handle(zone);
    auto& a_i = String::Handle(zone);
    auto& a_j = String::Handle(zone);
    const bool got_i = LookupCurrent(thread, id_i, &k_i, &v_i, &impl_i, &a_i);
    const bool got_j = LookupCurrent(thread, id_j, &k_j, &v_j, &impl_j, &a_j);
    const bool l01 = got_i && got_j && impl_i.ptr() != impl_j.ptr() &&
                     impl_i.ptr() == fn_i.ptr() && impl_j.ptr() == fn_j.ptr();
    arm("L01",
        "two declarations sharing a Function name resolve to their own "
        "implementations, not to each other",
        l01,
        l01 ? "both resolved to their own Function"
            : "one resolved to the other, or did not resolve");
  } else {
    arm("L01",
        "two declarations sharing a Function name resolve to their own "
        "implementations, not to each other",
        false,
        "NO SUCH PAIR IN THIS PROGRAM -- the arm could not run, which is not "
        "the same as passing");
  }

  // X01 -- nothing has diverged in the normal state. Without this the next
  // arm could pass because the check reports divergence unconditionally.
  auto& diverged_id = String::Handle(zone);
  const intptr_t diverged_before =
      CountDivergedImplementations(thread, &diverged_id);
  arm("X01", "no descriptor has diverged from its pinned implementation",
      diverged_before == 0,
      diverged_before == 0 ? "0 diverged"
                           : diverged_id.ToCString());

  // X02 -- a replacement that rewrites Function::CurrentCode() directly,
  // leaving the registry untouched, must be DETECTABLE. This is the defect
  // the issue names: "a replacement mutating a Function/Code object directly
  // while registry state remains old". Nothing here executes the swapped
  // code; the arm only proves the divergence cannot hide.
  // Pick the subject FRESH. The arms above mutate state -- S04 promotes a
  // staged replacement, so the entry that started out pointing at fn_a now
  // points at fn_b, and swapping fn_a's code would change nothing that any
  // descriptor is watching. An arm whose subject was chosen before the state
  // moved tests the wrong object and reports "no defect found".
  auto& swap_fn = Function::Handle(zone);
  auto& other_fn = Function::Handle(zone);
  auto& scratch_id = String::Handle(zone);
  auto& scratch_abi = String::Handle(zone);
  for (intptr_t i = 0; i < n && swap_fn.IsNull(); i++) {
    EntryAt(thread, i, &scratch_id, &sel, &swap_fn, &scratch_abi);
    if (swap_fn.IsNull() || !swap_fn.HasCode()) {
      swap_fn = Function::null();
      continue;
    }
    for (intptr_t j = 0; j < n; j++) {
      EntryAt(thread, j, &scratch_id, &sel, &other_fn, &scratch_abi);
      if (!other_fn.IsNull() && other_fn.HasCode() &&
          other_fn.CurrentCode() != swap_fn.CurrentCode()) {
        break;
      }
      other_fn = Function::null();
    }
    if (other_fn.IsNull()) swap_fn = Function::null();
  }

  if (!swap_fn.IsNull() && !other_fn.IsNull()) {
    const auto& original = Code::Handle(zone, swap_fn.CurrentCode());
    const auto& foreign = Code::Handle(zone, other_fn.CurrentCode());
    swap_fn.AttachCode(foreign);
    const intptr_t diverged_after =
        CountDivergedImplementations(thread, &diverged_id);
    // Put it back before anything else reads it: this is a diagnostic, and a
    // self-test that leaves the program mutated is a worse defect than the
    // one it is testing for.
    swap_fn.AttachCode(original);
    const intptr_t diverged_restored = CountDivergedImplementations(thread);
    const bool x02 = diverged_after >= 1 && diverged_restored == 0;
    arm("X02",
        "code swapped underneath a descriptor is reported as diverged, and "
        "restoring it clears the report",
        x02,
        x02 ? "diverged while swapped, 0 after restore"
            : "divergence was not observed, or did not clear");
  } else {
    arm("X02",
        "code swapped underneath a descriptor is reported as diverged, and "
        "restoring it clears the report",
        false,
        "NO TWO CODE-BEARING ENTRIES -- the arm could not run, which is not "
        "the same as passing");
  }

  w.CloseArray();
  w.PrintPropertyBool("found_name_clash_pair", have_name_clash);

  // --- measurements. Diagnostic only; no threshold is compared. ---
  w.OpenObject("measurements");
  const auto& storage =
      GrowableObjectArray::Handle(zone, EnsureStorage(thread));
  const intptr_t slots = storage.Length();
  w.PrintProperty64("entries", n);
  w.PrintProperty64("array_slots", slots);
  w.PrintProperty64("slots_per_entry", kEntrySize);
  w.PrintProperty64("registry_bytes_approx", slots * kWordSize);
  w.PrintProperty64("bytes_per_entry_approx",
                    n > 0 ? (slots * kWordSize) / n : 0);
  const int64_t t0 = OS::GetCurrentTimeMicros();
  const intptr_t kIters = 10000;
  intptr_t sink = 0;
  for (intptr_t i = 0; i < kIters && n > 0; i++) {
    sink += IndexOf(thread, id_a) >= 0 ? 1 : 0;
  }
  const int64_t t1 = OS::GetCurrentTimeMicros();
  w.PrintProperty64("lookup_iterations", kIters);
  w.PrintProperty64("lookup_total_micros", t1 - t0);
  w.PrintProperty("lookup_note",
                  "linear scan over a GrowableObjectArray; correctness first, "
                  "and the cost is recorded rather than optimised around");
  w.PrintProperty64("lookup_sink", sink);
  w.CloseObject();

  w.CloseObject();

  auto* f = fopen(path, "w");
  if (f == nullptr) {
    OS::PrintErr("MaotRegistry: cannot open '%s'\n", path);
    return;
  }
  fputs(w.ToCString(), f);
  fclose(f);
}

void MaotRegistry::DumpToFile(Thread* thread, const char* path) {
  Zone* zone = thread->zone();
  JSONWriter writer;
  writer.OpenObject();
  writer.PrintProperty("schema", "maot.registry/1");
  writer.PrintProperty64("schema_version", kSchemaVersion);

  const auto& ns = String::Handle(zone, GetNamespace(thread));
  writer.PrintProperty("namespace_identity",
                       ns.IsNull() ? "<absent>" : ns.ToCString());
  writer.PrintProperty(
      "runtime_mode",
#if defined(DART_PRECOMPILED_RUNTIME)
      "precompiled");
#else
      "jit_or_precompiler");
#endif

  const intptr_t entries = Length(thread);
  writer.PrintProperty64("entry_count", entries);
  writer.PrintProperty64("diverged_implementations",
                         CountDivergedImplementations(thread));
  writer.PrintProperty64("selected_seen_at_materialization", maot_stat_selected);
  writer.PrintProperty64("retained_at_materialization", maot_stat_retained);
  writer.PrintProperty64("dropped_at_materialization", maot_stat_dropped);

  writer.OpenArray("entries");
  auto& id = String::Handle(zone);
  auto& abi = String::Handle(zone);
  auto& impl = Function::Handle(zone);
  for (intptr_t i = 0; i < entries; i++) {
    id ^= FieldAt(thread, i, kDeclarationId);
    abi ^= FieldAt(thread, i, kCurrentAbi);
    impl ^= FieldAt(thread, i, kCurrentImpl);
    writer.OpenObject();
    writer.PrintProperty("declaration_id", id.ToCString());
    writer.PrintPropertyBool(
        "selected",
        Smi::Value(Smi::RawCast(FieldAt(thread, i, kSelected))) == 1);
    writer.OpenObject("current");
    const intptr_t kind =
        Smi::Value(Smi::RawCast(FieldAt(thread, i, kCurrentKind)));
    writer.PrintProperty("kind", kind == kAot ? "AOT" : "PATCH_CODE");
    // Whether a Code is pinned, and whether the Function still points at it.
    // Not an address: an address is not identity, and #66 forbids using one
    // as such. This is a yes/no plus a size, which is all any decision reads.
    {
      const auto& pinned = Object::Handle(zone, FieldAt(thread, i,
                                                        kCurrentCode));
      const auto& fn = Function::Handle(zone,
          Function::RawCast(FieldAt(thread, i, kCurrentImpl)));
      writer.PrintPropertyBool("implementation_code_pinned", !pinned.IsNull());
      writer.PrintPropertyBool(
          "pinned_code_is_current",
          !pinned.IsNull() && !fn.IsNull() && fn.HasCode() &&
              fn.CurrentCode() == Code::RawCast(pinned.ptr()));
      writer.PrintProperty64(
          "pinned_code_size",
          pinned.IsNull() ? -1 : Code::Cast(pinned).Size());
    }
    writer.PrintProperty64(
        "version", Smi::Value(Smi::RawCast(FieldAt(thread, i, kCurrentVersion))));
    // The implementation is described by its LOGICAL relationship, never by an
    // address. A name here is diagnostic provenance, not identity: identity is
    // the declaration_id above.
    writer.PrintProperty("implementation_present", impl.IsNull() ? "no" : "yes");
    // Retaining a Function SHELL is not the same as having something to
    // replace. The instruction-size report is NOT authoritative here -- it
    // omitted functions that demonstrably had Code -- so the descriptor is
    // judged by the VM's own state.
    const bool has_code = !impl.IsNull() && impl.HasCode();
    writer.PrintPropertyBool("executable", has_code);
    writer.PrintProperty64(
        "implementation_size",
        has_code ? Code::Handle(impl.CurrentCode()).Size() : 0);
    // Retaining a Function SHELL is not the same as having something to
    // replace. A selected declaration the release never calls must still
    // carry real AOT code, or the initial AOT descriptor is a promise with
    // no implementation behind it.
    writer.PrintPropertyBool("has_code", !impl.IsNull() && impl.HasCode());
    writer.PrintProperty("implementation_name_diagnostic",
                         impl.IsNull() ? "<null>" : impl.ToCString());
    writer.CloseObject();
    writer.PrintProperty("abi", abi.IsNull() ? "<absent>" : abi.ToCString());
    writer.PrintPropertyBool(
        "has_staged",
        Smi::Value(Smi::RawCast(FieldAt(thread, i, kStagedKind))) >= 0);
    writer.CloseObject();
  }
  writer.CloseArray();
  writer.CloseObject();

  auto* file = fopen(path, "w");
  if (file == nullptr) {
    OS::PrintErr("MaotRegistry: cannot open '%s' for writing\n", path);
    return;
  }
  fputs(writer.ToCString(), file);
  fclose(file);
}

}  // namespace dart
