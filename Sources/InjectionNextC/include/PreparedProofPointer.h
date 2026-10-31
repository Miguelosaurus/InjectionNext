#pragma once
#include <stdint.h>
#include <objc/runtime.h>
#include <ptrauth.h>

// Introspection only: normalize a runtime-provided IMP for equality, mapped
// image range checks and dladdr. Never call this stripped pointer. The compiler
// owns the architecture-specific representation; do not mask address bits.
static inline uintptr_t SwiftSimPreparedIMPAddress(IMP _Nonnull implementation) {
    return (uintptr_t)ptrauth_strip(implementation, ptrauth_key_function_pointer);
}
