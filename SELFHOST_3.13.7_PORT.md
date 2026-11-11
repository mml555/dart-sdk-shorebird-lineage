# SELFHOST 3.13.7 port record

Source-level port of the Shorebird-lineage Dart SDK fork from Dart 3.12.2 to
Dart 3.13.7. When written, nothing here was built or run; "Verified since"
lists what has been run on a build host since then. Read "Unverified" before
relying on anything else. No existing branch was moved, rewritten or deleted; the old
branches (`provenance/route-b-selfhost-v1.1.1`, `maot/*`) remain the
certification records for 3.12.2.

## Identities

| | commit |
| --- | --- |
| old base, Dart 3.12.2 | `d684a576a6aa954ae107a03b2b4e1d61c3bebe93` |
| new base, Dart 3.13.7 (tag 3.13.7; shorebirdtech/flutter e2c965ff DEPS `dart_revision`) | `416e33b0ffaef062a60ec966bb8c82ed2b83f128` |

Branches (new, local; created by cherry-picking with `-x`, authorship and
messages kept):

| branch | content |
| --- | --- |
| `selfhost/3.13.7/code-push-api` | 3.13.7 + layer 1 |
| `selfhost/3.13.7/route-b` | + layers 2 and 3 + this file |
| `maot/3.13.7/build` | route-b + 127 maot/build commits + port fix + doc update |
| `maot/3.13.7/identity` | route-b + 2 maot/identity commits + doc update |
| `maot/3.13.7/rescue-source-loader` | route-b + rescue commit (empty, see below) + doc update |

Branch names are not provenance (SUPPORTED_STATE.yaml: "BRANCHES ARE NOT
PROVENANCE"): record repository plus the full immutable SHA, and consider
annotated tags once a branch is certified. The `provenance/` prefix was not
used because these branches are not certified and `provenance/route-b-selfhost-v1.1.1`
names one frozen 3.12.2 tree.

## Layer map (old sha -> new sha)

| layer | old | new | result |
| --- | --- | --- | --- |
| 1 snapshot size accessors | `6b58bb3a72e` | `f48767de1db` | clean |
| 2 Route B SDK support, bytecode producer, target->pool instrument | `9e8c898a4d2` | `a1bf5b9e59d` | 4 conflicts, resolved |
| 3 producing-source guard (selfhost-v1.1.1 effective tree) | `5f37e75fbe0` | `3963501cb5f` | clean |
| (doc, preliminary) | | `a091a3460b0` | |

Layer 3 is SOURCE (a 15-line platform-library refusal in
`pkg/front_end/lib/src/source/source_loader.dart`), not only a record, so it is
on route-b. Its old commit existed to preserve tree `7b04b01b` byte for byte;
that identity cannot carry over (the base changed, and this file is added), so
the new tree hash is a new identity, not a reproduction of the old one.

maot/identity (2 commits) and maot/rescue-source-loader (1 commit) were based
on layer 2 (`9e8c898a4d2`), not layer 3. The rescue commit `d9e4e60a552`
carries the same 15-line change as layer 3, so on top of route-b it is empty.
It was kept as an empty commit (`--keep-redundant-commits`) so the branch
still records the original message. maot/build also forks from
`9e8c898a4d2`, without layer 3: the guard arrives on it through route-b.

The full per-commit map for the 130 maot commits is in the appendix.

## Conflicts and how they were resolved

Layer 2 (`9e8c898a4d2`):

* `pkg/front_end/lib/src/api_prototype/compiler_options.dart`: upstream added
  `allowDynamicCallsInDynamicModules` / `dynamicCallsSelectorAllowList` and
  removed the unused `declaredVariables` option (daadde51d86). Kept upstream's
  fields and added `resolvePrivateNamesInLibrary` plus its `==` clause. Did
  NOT re-add `declaredVariables`: the fork's diff only carried it as hunk
  context, it was never used by the fork. Doc reference
  `[additionalDills]` became `[additionalDillModules]` (upstream rename).
* `pkg/front_end/lib/src/base/processed_options.dart`: both getters kept.
* `pkg/dart2bytecode/lib/dart2bytecode.dart`: kept upstream's two new
  `CompilerOptions` assignments and the fork's `resolvePrivateNamesInLibrary`
  (`Uri.parse`, not `resolveInputUri`).
* `runtime/bin/gen_snapshot.cc`: upstream added `ffi_callback_stub` to the
  string-options macro; the fork added `load_obfuscation_map`. Both kept (the
  fork's entry before `ffi_callback_stub`, backslash continuation fixed), and
  `--load-obfuscation-map` was also added to the new `app-aot-pecoff-obj`
  usage block so the help text stays consistent.

maot/build (`maot/3.13.7/build`):

* `38b31d7cd2e` and `c5f214a0f63`, `runtime/vm/object_store.h`: upstream moved
  the stubs out of ObjectStore (the `RW(Code, ..._stub)` list is gone) and
  `to_snapshot(kFullAOT)` now ends at `ffi_callback_functions_` (was
  `slow_tts_stub_`). The fork's rule was: the maot fields must sit before the
  AOT snapshot cut-off, and after the last field exported in
  runtime_offsets_extracted.h. Re-expressed: `maot_registry`, `maot_namespace`,
  `maot_decisions` are placed immediately BEFORE `ffi_callback_functions`,
  inside the AOT/JIT snapshot range. The second constraint no longer applies
  because 3.13.7 exports no ObjectStore field offsets (checked: no
  `ObjectStore_` entries in runtime_offsets_extracted.h / _list.h). The
  comment in the file says so.
* `bf64eb2b883`, `2f0288cda70`, `d020d2d2c24`, `runtime/vm/app_snapshot.cc`,
  `runtime/vm/compiler/relocation.cc` (diagnostic tracing): upstream removed
  the VM isolate (d36adbacafe). The Serializer's local `clusters` array is now
  member `clusters_`, `RelocateCodeObjects` and `CodeRelocator::Relocate`
  lost their `is_vm` / `vm_` parameter. Adapted the fork's trace code to the
  new signatures (`clusters_`, `RelocateCodeObjects(&code_objects, ...)`,
  `Relocate()`), and dropped `is_vm=` from the `RELOC LOOP BEGIN` trace line.
  One residual `clusters.length()` from `bf64eb2b883` was fixed inside the
  `2f0288cda70` pick (a one-line deviation from that commit's text).

Port fix commit (only on `maot/3.13.7/build`), not a cherry-pick:
`pkg/vm/lib/metadata/maot_declaration_id.dart` read `NamedParameter.name`;
upstream 4feee97fe8e removed `Variable.name`, the non-null name is
`parameterName`. Without this the file does not compile.

## Not carried over, or changed in meaning

* `declaredVariables` (CompilerOptions): not re-added, upstream removed it and
  nothing used it.
* The old ObjectStore placement rules for the maot fields changed (see above);
  field ORDER in the object store is new, so the AOT snapshot layout of these
  roots differs from the 3.12.2 fork (it also differs from every 3.12.2 cell
  anyway: see SNAPSHOT_HASH below).
* The layer-3 / `d9e4e60a552` tree identity (`7b04b01b`) cannot be reproduced.
* Layer 1 keeps `Dart_SnapshotDataSize` / `Dart_SnapshotInstrSize` working on
  3.13.7, but the thing they size has changed (next section).
* The fork's `Dart_RouteBActivatePatch*` / `--patchable_static_calls` /
  `--load_obfuscation_map` surface is unchanged textually. Upstream did not
  provide any of it (checked by identifier), so no fork commit became
  redundant except the rescue commit (above).

## Upstream 3.12.2 -> 3.13.7 changes that matter without a textual conflict

1. VM isolate / VM snapshot removed (d36adbacafe). There is no `vm_data` /
   `vm_instructions` any more: one `kDartSnapshotData` / `kDartSnapshotText`
   pair, `Dart_Initialize` no longer takes VM snapshot buffers,
   `Dart_CreateSnapshot` / `Dart_CreateAppJITSnapshotAsBlobs` take one pair,
   `Dart_CreateVMAOTSnapshotAsAssembly` is gone. The Shorebird engine's
   `snapshots_data_handle.cc` presents FOUR blobs to the updater as one
   stream; the engine at Flutter 3.47.7 must be checked against the
   2-blob layout. The two accessors still compile (`Snapshot::SetupFromBuffer`,
   `Snapshot::length()`, `Image(const void*)`, `Image::snapshot_size()` all
   exist) but only apply to the single pair. The fork's `--load_obfuscation_map`
   comment says the Obfuscator is built inside
   `Object::Init -> CreateIsolate -> Dart_CreateIsolateGroupFromKernel`; with
   no VM isolate that call order has changed and the claim must be re-measured.
2. Kernel binary format 130 -> 138 (Contexts: scopes, variables serialized,
   `VariableDeclaration` -> `Variable`, `FunctionParameter`). Every dill
   produced by the 3.12.2 toolchain is unreadable by 3.13.7 and vice versa.
3. Bytecode format 1 -> 3 and a heavily changed interpreter
   (`runtime/vm/interpreter.cc` +487/-, `bytecode_reader.cc`,
   `pkg/dart2bytecode` +1.7k lines). Route B payloads produced earlier will
   not load. The `Dart_RouteBActivatePatch` / `Internal_attachBytecodeToFunction`
   paths run the new interpreter and `InterpretCall` stub; the kill-gate
   behaviour of `patchable_static_calls` (call through `Function::entry_point_`,
   R0/R4 register contract in `flow_graph_compiler_arm64.cc`) must be re-proved.
4. `SNAPSHOT_HASH`: `object.cc/.h`, `object_store.h` are snapshot-hash inputs
   and upstream changed them heavily (app_snapshot.cc +/-1.4k lines). The hash
   differs from 3.12.2 cells and from vanilla 3.13.7; a snapshot produced by
   one will be refused by the other. Re-measure the "hash identical across
   cells" property from the layer 2 commit message on the new tree.
5. Factories no longer take an irregular type-arguments parameter (6195ea86bc4):
   native arg counts for factories dropped by one. The fork's new natives are
   not factories, so unaffected; the `vm:recognized` hash-map accessor kinds
   used by the AOT call specializer guard (`kLinkedHashBase_*`) still exist.
6. The `external-effect` pragma, `Variable` rename and removed
   `Variable.name` in Kernel (see port fix); `Constructor.enclosingClass` is
   now non-nullable, so `pkg/kernel/lib/maot_identity.dart:483` has an always
   true `cls != null` (analyzer warning, harmless).
7. Dynamic-module work (cca62984989 dcall target validation, dynamicallyCallable
   pragmas in TFA, 14517e3735c): `DynModuleDynamicallyCallablePragma` etc. now
   change what TFA keeps and which entry points `loadDynamicModule` accepts;
   this interacts with Route B's relaxed entry-point arity check in
   `bytecode_generator.dart` and with maot selection in
   `type_flow/transformer.dart`.
8. `Dart_IsolateFlags` / `Dart_InitializeParams` versions bumped (flags 0xd ->
   0xe, init params 0xA -> 0xB): embedders built against the old header must
   be rebuilt.

## What was checked here, and what was not

Checked (no build):
* No conflict markers anywhere in runtime/, pkg/, sdk/.
* Identifier check: every identifier on a line the fork added, that existed
  in 3.12.2's runtime/pkg/sdk-lib vocabulary but not in 3.13.7's, was listed:
  the only hits were comments and a fork-local variable. So no fork code names
  a symbol that upstream deleted (this does NOT catch signature or semantics
  changes, nor members removed from a class that still exists; the
  `NamedParameter.name` bug was found by reading, not by this check).
* Declarations the fork hooks into still exist in 3.13.7: `Function::AttachBytecode`,
  `ClearBytecode`, `BytecodeLoader`, `FlowGraphCompiler::GenerateStaticDartCall`,
  `EmitCallsiteMetadata`, `FUNCTION_REG`/`ARGS_DESC_REG`, `CLOBBERS_LR`,
  `Dart::InitializeIsolate`, `KernelBytecode::kBytecodeFormatVersion`,
  `lookupLibraryBuilder`, `KernelTarget.dillTarget`, `SourceCompilationUnitImpl(resolveInLibrary:)`,
  the `MethodRecognizer::k*LinkedHashBase_*` kinds, `Snapshot::SetupFromBuffer`.
* `dart analyze` (standalone 3.13.7) on `pkg/kernel/lib/maot_identity.dart`:
  clean apart from lints and the warning in item 6. An attempt to analyze
  pkg/vm and pkg/dart2bytecode failed to resolve `package:kernel` outside a
  gclient/pub workspace and was abandoned; its output was not used.

NOT verified (needs the build host):
* Any C++ compilation: all of runtime/ (object.cc/h, app_snapshot.cc,
  relocation.cc, precompiler.cc, program_visitor.cc, runtime_entry.cc,
  flow_graph_compiler_arm64.cc, inliner.cc, kernel_loader.cc,
  kernel_binary_flowgraph.cc, maot_registry.cc), including the app_snapshot.cc
  trace code adapted by hand, and whether `maot_registry.cc` (3.3k lines, new
  file) uses VM APIs whose signatures changed.
* Dart analysis/compile of pkg/vm (transformer.dart, analysis.dart,
  maot_selection.dart, maot_declaration_id.dart, maot_identity_manifest.dart),
  pkg/dart2bytecode, pkg/front_end. Kernel API changes (`Variable`,
  `FunctionParameter`, `Constructor.enclosingClass`) may break more than the
  one fix applied.
* `CheckOffsets` in gen_snapshot, `runtime_offsets_*` consistency.
* The maot_registry surviving into the AOT snapshot (the reason for the
  object_store.h placement rule) and the dispatch-cell / slot-preserving
  behaviour.
* Route B: detach/rollback, the engine-side lifecycle, and everything on a
  device. The host kill gate (attach, `patchable_static_calls`, the
  interpreter path, bytecode v3 producer + loader) now passes: see
  "Verified since".
* The gates in selfhost: M1/M2 (`run_m1.sh`, `run_m2.sh`), G15 evidence,
  and all certification claims. None of the 3.12.2 evidence applies to this tree.
* Engine side: the Shorebird engine at 3.47.7 against the single-snapshot API.
* Upstream's own test suites (this port touched dart2bytecode / vm / CFE code
  with testcases that expect old output).

## Verified since: Route B host kill gate (2026-11-10)

Host: macOS arm64 (Apple silicon). `patchable_static_calls` is implemented
only in `flow_graph_compiler_arm64.cc`, so an x64 host such as ci-build cannot
run this gate. Tree: Flutter `7806e0fb682`, this lineage at `d2df9606d11`
(`selfhost/3.13.7/route-b` tip). Build: `./flutter/tools/gn
--runtime-mode=release --mac-cpu arm64 --no-prebuilt-dart-sdk
--dart-dynamic-modules --target-dir host_release_arm64_ddm`, then `ninja
gen_snapshot dartaotruntime dart dart_sdk vm_platform.dill`. It compiled with no
source change (4818/4818 steps; `args.gn` has `dart_dynamic_modules = true`;
`dartaotruntime` has 4 `AttachBytecode` symbols). Scripts are from
mml555/shorebird `main`, `selfhost/engine/route_b/`.

`verify_binding.sh`: **PASS**. The patch bound to `dart:core` `print` through
a generated dynamic interface, and all four call shapes reached the new body:

```
ATTACH: before -> IsInterpreted=0 HasBytecode=0
ATTACH: after  -> IsInterpreted=1 HasBytecode=1
ATTACH: pool len=2350, rewrote 0 slot(s) (other Code slots=113)
ATTACH: C++ invoke of target returned: NEW-PRINTED
after  direct   : NEW-PRINTED
after  tear-off : NEW-PRINTED
after  dynamic  : NEW-PRINTED
after  apply    : NEW-PRINTED
GATE: PASS -- interpreted body replaced AOT body, direct calls included
```

`inventory/run_inventory.sh` (`--patchable_static_calls`):

```
topLevelStatic          topLevelStatic        PATCHABLE
Holder.staticMethod     staticMethod          PATCHABLE
Holder.monomorphic      monomorphic           PATCHABLE
Holder.get:getter       getter                PATCHABLE
Circle.describe         polymorphic-first     not reachable
Circle.describe         dynamic-instance      PATCHABLE
```

The one `not reachable` row is the statically-typed polymorphic call through
the dispatch table, which `selfhost/ROUTE_B.md` already lists as not patchable
on 3.12.2. Same result as before the port, so it is not a regression.

So item 3 of the section above holds on the host: the 3.13.7 interpreter, the
`InterpretCall` stub and the arm64 register contract work with
`patchable_static_calls`. Still open: engine-side activation and lifecycle,
detach/rollback, the iOS build, and a device run.

## Build-host steps

Build host: ci-build (10.0.0.41); farm layout used by the repo's scripts is
`/Volumes/build/route-b/flutter/engine/src` with the Dart tree at
`engine/src/flutter/third_party/dart` and depot_tools at
`/Volumes/build/ios-engine/depot_tools`. Sources: selfhost/ENGINE_BUILD.md,
selfhost/engine/build.sh, selfhost/engine/mutable_aot/m2/build_maot.sh,
selfhost/engine/dart-fork/README.md. One heavy job at a time on a shared host.

1. Flutter side: check out the Flutter revision whose `DEPS` pins
   `dart_revision` 416e33b0 (Flutter 3.47.7 / shorebirdtech/flutter e2c965ff),
   with a `.gclient` whose solution name is `"."` at the checkout root.
2. Point the engine's Dart at this lineage, not at the private
   `shorebirdtech/dart-sdk` and not at vanilla: in `.gclient` add
   `custom_deps: {"engine/src/flutter/third_party/dart":
   "https://github.com/mml555/dart-sdk-shorebird-lineage.git@<FULL SHA of the branch tip>"}`
   (or a `file://` clone, as dart-fork/README.md does), then
   `gclient sync --no-history` (set `GIT_CONFIG_GLOBAL` to a scratch config if
   a rewrite is needed on the shared host). Use the full SHA, never the branch
   name. Code-push-only engine: `selfhost/3.13.7/route-b` is NOT needed, use
   `selfhost/3.13.7/code-push-api`; Route B engine: `.../route-b`; Mutable-AOT:
   `maot/3.13.7/build`.
3. Engine build (selfhost/engine/build.sh): `./flutter/tools/gn --no-rbe
   --no-enable-unittests ...` for the cell, then
   `ninja -C out/<dir> -j3 default gen_snapshot`. For Route B / dynamic modules
   the GN args must set `dart_dynamic_modules=true` (the code under
   `DART_DYNAMIC_MODULES` is compiled out otherwise).
   Do not combine `--dart-dynamic-modules` with `--no-enable-unittests`:
   the engine's `tools/gn` sets `dart_dynamic_modules = false` whenever
   `--no-enable-unittests` is passed, with no message. Check `args.gn`
   after gn runs.
4. Mutable-AOT host tools (m2/build_maot.sh): set `MAOT_FORK` to the
   third_party/dart checkout, `MAOT_SRC_ROOT` to engine/src, run it; it runs
   `ninja -C out/maot_host gen_snapshot dartaotruntime` (never pipe ninja to
   tail) and records source digests. Its SOURCES list must still match the
   gates' lists.
5. Verify, in this order: (a) compile errors from step 3/4, fixing against the
   "Unverified" list; (b) `dart pub get` + `dart analyze` for pkg/vm,
   pkg/dart2bytecode, pkg/front_end inside the gclient checkout; (c) upstream
   tests touching changed areas (`tools/test.py -m release` for the vm/cfe/
   dart2bytecode suites; cap workers); (d) selfhost gates
   `mutable_aot/m1/run_m1.sh`, `m2/run_m2.sh`, then the Route B kill gate and
   device runs; (e) re-measure SNAPSHOT_HASH; (f) re-check the engine against
   the single-snapshot API (`Dart_SnapshotDataSize/InstrSize` callers).
6. Re-qualify: any `SUPPORTED_STATE.yaml` / `compatibility.yaml` update needs
   the new full SHAs, new `dart_revision` and new evidence; nothing certified
   on 3.12.2 carries over.

## Appendix: maot commit map (old -> new, first 12 hex)


### build
commit -> 4af75c3cbd81
commit -> ed143f857da1
commit -> b1fb8e1341bb
commit -> 9879db6c5633
commit -> 95d0bf974e80
commit -> dbfafe54006b
commit -> e1bafef4cb69
commit -> 29465d82fea5
commit -> a3a996f15b6b
commit -> d0eba23b55ab
commit -> 200620b77a8d
commit -> f632de47aded
commit -> 5fbb638be76a
commit -> 88475b278653
commit -> 5b7427abf214
commit -> 81a5e31e6914
commit -> 669be430f9d2
commit -> ea7c94a72e52
commit -> 10ddfd759ea6
commit -> 2b2f52697288
commit -> 65079008b9a1
commit -> 841c352a49e0
commit -> 39d67a4e3b7d
commit -> 0c0f77541673
commit -> f8f4056edbbb
commit -> fead56a38a38
commit -> 31e305c17af1
commit -> b205d5395e4e
commit -> 009eb6a4de2e
commit -> e03635a1afd1
commit -> ef9b54bbfb9b
commit -> 35c9ef6b21c2
commit -> d8c86b93596a
commit -> 22b3fe33af73
commit -> 42944a5f8f9f
commit -> 1de9f06543de
commit -> f7c8523c474b
commit -> 7e48c259a80d
commit -> df3d096776e8
commit -> 9581111b32a8
commit -> 1c43838ca425
commit -> 413486b6d08e
commit -> 30e8bc7b4068
commit -> de3e96f0c05f
commit -> 3f43a7ae1dec
commit -> 3f7d22266723
commit -> 47312551575f
commit -> 02fa2710be33
commit -> 316a17fbf81c
commit -> e4b8cbcdd9bd
commit -> 3906508f5f2b
commit -> f7c9967ca405
commit -> 79bd3fb2aa72
commit -> 1432317fbbe7
commit -> 540ca8a661a3
commit -> 0eb4fd5c68a9
commit -> 308dbc904cd5
commit -> d7b0fdc23faa
commit -> fd194366e8cc
commit -> bba5124d0818
commit -> 21975cfce580
commit -> dc7b88c535e4
commit -> 3e593b9f0611
commit -> 807421e3e6f8
commit -> af844c5d2866
commit -> 41302b395bfa
commit -> ecd0289a3c67
commit -> f7d95e41941e
commit -> c59e5b46226f
commit -> 25ff51e1e1e8
commit -> 7675e0906e62
commit -> 52303cba6bc2
commit -> fe9a8fad6bb7
commit -> abbe8ed783a0
commit -> 3df2541d84f0
commit -> 7ce5169a1650
commit -> 101ec1c58f80
commit -> 0809a1444377
commit -> 8a7563b098cd
commit -> 365129472e80
commit -> 9c4723d8cca8
commit -> fe5d39233bf4
commit -> c7820df30ebe
commit -> 41523d75352b
commit -> 0d30c663826c
commit -> c036d6f45477
commit -> e6392acb93fe
commit -> 01a5f1386050
commit -> 2d86af6d0fde
commit -> 8d912f55ce07
commit -> f8452c215593
commit -> 7ac19c76aa2c
commit -> 68b55dea2270
commit -> 8d38ec7c82a8
commit -> 315ff54e5665
commit -> 198eb1a358c3
commit -> f6a0124e4c69
commit -> 975e4e4939da
commit -> 832ecb6275e7
commit -> c89920e2fa26
commit -> ba576567902a
commit -> ee50f2d121c9
commit -> d57f6c5ecbc6
commit -> 1a389b9ac150
commit -> ec389c031f5a
commit -> 575037366d7e
commit -> a9eb9389316d
commit -> fa84d22d2ecd
commit -> ed475b86a850
commit -> 8114ffc1ea82
commit -> 34673993e23a
commit -> b188d3f3ffcf
commit -> a834672b33c9
commit -> a2f0c61e3a80
commit -> ce82ebe4e454
commit -> e1659341b52b
commit -> ee974ea0b252
commit -> d7b4f6fa4187
commit -> d671ba7a5d23
commit -> 88531e379137
commit -> 9bf69da66e6a
commit -> 752136b2607d
commit -> fe60c0b45419
commit -> 2cfc9cca45c2
commit -> aa1fe2e22bde
commit -> be9a639e917a
commit -> 713bddc4bc92

### identity
commit -> 6b14acee9af5
commit -> 0c2bd682eb26

### rescue-source-loader
commit -> 57ca12ec15ed
