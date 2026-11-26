// Copyright (c) 2026, the Shorebird self-host fork.
//
// Dart_RouteBActivatePatch runs from the embedder's pre-main hook, where no Dart
// frame is on the stack. The loader reports an already-loaded library by
// throwing a Dart StateError, and with no frame to land in that throw crashes
// the process (EXC_BAD_ACCESS in Exceptions::JumpToFrame). Every refusal must
// instead come back as a result code with the program untouched.

#include "include/dart_api.h"
#include "include/dart_route_b_trace.h"
#include "platform/assert.h"
#include "vm/unit_test.h"

namespace dart {

#if defined(DART_DYNAMIC_MODULES)

namespace {

constexpr const char kPayloadUri[] = "file:///route_b_payload.dart";

// A TEST_CASE has no Dart frame on its stack either, so a throw out of
// Dart_RouteBActivatePatch would take the same crash path the pre-main hook
// does.
//
// A function of dart:core is an ordinary compiled one: not interpreted, so it
// is a legal target.
constexpr const char kTargetLibrary[] = "dart:core";
constexpr const char kTargetName[] = "identityHashCode";

// Compiles a one-function library to bytecode. Returns false when this build's
// test compiler produces kernel instead, in which case there is nothing for the
// bytecode loader to be given.
bool CompilePayload(const uint8_t** buffer, intptr_t* size) {
  char* error = TestCase::CompileTestScriptWithDFE(
      kPayloadUri, "int main() => 42;\n", buffer, size,
      /*incrementally=*/true);
  EXPECT(error == nullptr);
  return error == nullptr && Dart_IsBytecode(*buffer, *size);
}

}  // namespace

// The target is missing: the answer is TargetMissing and the payload is never
// read. The payload here is not bytecode at all, and reading it would be a
// FATAL "Unexpected Dart bytecode magic".
TEST_CASE(RouteBActivate_MissingTargetLoadsNothing) {
  const uint8_t not_bytecode[] = {'n', 'o', 't', ' ', 'b', 'y', 't', 'e',
                                  'c', 'o', 'd', 'e', '!', '!', '!', '!'};
  EXPECT_EQ(Dart_RouteB_TargetMissing,
            Dart_RouteBActivatePatch(not_bytecode, sizeof(not_bytecode),
                                     kTargetLibrary, "noSuchFunction"));
  EXPECT_EQ(Dart_RouteB_TargetMissing,
            Dart_RouteBActivatePatch(not_bytecode, sizeof(not_bytecode),
                                     "dart:no_such_library", kTargetName));
}

// The payload's library is already loaded in this isolate group (what a second
// root isolate in the group, or a container whose later target repeats an
// earlier payload, presents). The loader would throw; the answer is a refusal.
TEST_CASE(RouteBActivate_AlreadyLoadedLibraryIsRefused) {
  const uint8_t* buffer = nullptr;
  intptr_t size = 0;
  if (!CompilePayload(&buffer, &size)) return;

  Dart_Handle td = Dart_NewExternalTypedData(
      Dart_TypedData_kUint8, const_cast<uint8_t*>(buffer), size);
  EXPECT_VALID(td);
  EXPECT_VALID(Dart_LoadLibraryFromBytecode(td));

  EXPECT_EQ(Dart_RouteB_InvalidBytecode,
            Dart_RouteBActivatePatch(buffer, size, kTargetLibrary,
                                     kTargetName));
}

// The same payload activated twice: the first attaches, the second is refused
// (the target is already interpreted, answered before the payload is loaded a
// second time) and the first stays attached until it is deactivated.
TEST_CASE(RouteBActivate_SamePayloadTwiceIsRefused) {
  const uint8_t* buffer = nullptr;
  intptr_t size = 0;
  if (!CompilePayload(&buffer, &size)) return;

  EXPECT_EQ(Dart_RouteB_Ok,
            Dart_RouteBActivatePatch(buffer, size, kTargetLibrary,
                                     kTargetName));
  EXPECT_EQ(Dart_RouteB_AlreadyInterpreted,
            Dart_RouteBActivatePatch(buffer, size, kTargetLibrary,
                                     kTargetName));
  EXPECT_EQ(Dart_RouteB_Ok,
            Dart_RouteBDeactivatePatch(kTargetLibrary, kTargetName));
}

#endif  // defined(DART_DYNAMIC_MODULES)

}  // namespace dart
