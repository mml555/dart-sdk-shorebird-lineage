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
  const auto& storage =
      GrowableObjectArray::Handle(thread->zone(), EnsureStorage(thread));
  storage.SetLength(0);
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

void MaotRegistry::Register(Thread* thread,
                            const String& declaration_id,
                            bool selected,
                            const Function& implementation,
                            const String& abi_descriptor) {
  Zone* zone = thread->zone();
  if (IndexOf(thread, declaration_id) >= 0) {
    // Two runtime entities claiming one identity. A later patch would bind to
    // whichever won, so this is fatal rather than a warning.
    FATAL("MaotRegistry: duplicate declaration id '%s'",
          declaration_id.ToCString());
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
  storage.Add(abi_descriptor, Heap::kOld);
  storage.Add(Smi::Handle(zone, Smi::New(-1)), Heap::kOld);  // staged kind
  storage.Add(Smi::Handle(zone, Smi::New(0)), Heap::kOld);   // staged version
  storage.Add(Object::null_object(), Heap::kOld);            // staged impl
  storage.Add(Object::null_object(), Heap::kOld);            // staged abi
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
                                    const String& abi_descriptor) {
  const intptr_t entry = IndexOf(thread, declaration_id);
  if (entry < 0) return false;  // missing id is refused, never created

  Zone* zone = thread->zone();
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
  SetFieldAt(thread, entry, kCurrentAbi,
             Object::Handle(zone, FieldAt(thread, entry, kStagedAbi)));

  SetFieldAt(thread, entry, kStagedKind, Smi::Handle(zone, Smi::New(-1)));
  SetFieldAt(thread, entry, kStagedVersion, Smi::Handle(zone, Smi::New(0)));
  SetFieldAt(thread, entry, kStagedImpl, Object::null_object());
  SetFieldAt(thread, entry, kStagedAbi, Object::null_object());
  return true;
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
    writer.PrintProperty64(
        "version", Smi::Value(Smi::RawCast(FieldAt(thread, i, kCurrentVersion))));
    // The implementation is described by its LOGICAL relationship, never by an
    // address. A name here is diagnostic provenance, not identity: identity is
    // the declaration_id above.
    writer.PrintProperty("implementation_present", impl.IsNull() ? "no" : "yes");
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
