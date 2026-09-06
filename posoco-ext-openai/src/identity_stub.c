/*
 * Native platform probes for the Codex identity headers.
 *
 *   - platform -> uname(2).sysname (lowercased on the MoonBit side)
 *   - release  -> uname(2).release
 *   - arch     -> preprocessor macros ("arm64" / "x64" / "arm")
 *
 * Each helper returns a fresh MoonBit Bytes (UTF-8, null-terminated by the
 * runtime); the MoonBit side decodes via @utf8.decode_lossy. On any failure
 * the helper returns an empty buffer and the MoonBit wrapper reports
 * "unknown".
 */

#include <string.h>
#include "moonbit.h"

static moonbit_bytes_t identity_string_from_cstr(const char *cstr) {
  if (cstr == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  size_t len = strlen(cstr);
  moonbit_bytes_t bytes = moonbit_make_bytes((int32_t)len, 0);
  if (len > 0) {
    memcpy(bytes, cstr, len);
  }
  return bytes;
}

#ifndef _WIN32

#include <sys/utsname.h>

MOONBIT_FFI_EXPORT
moonbit_bytes_t identity_native_sysname(void) {
  struct utsname buf;
  if (uname(&buf) != 0) {
    return moonbit_make_bytes(0, 0);
  }
  return identity_string_from_cstr(buf.sysname);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t identity_native_release(void) {
  struct utsname buf;
  if (uname(&buf) != 0) {
    return moonbit_make_bytes(0, 0);
  }
  return identity_string_from_cstr(buf.release);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t identity_native_arch(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
  return identity_string_from_cstr("arm64");
#elif defined(__x86_64__) || defined(_M_X64)
  return identity_string_from_cstr("x64");
#elif defined(__arm__)
  return identity_string_from_cstr("arm");
#else
  return identity_string_from_cstr("");
#endif
}

#else /* _WIN32 */

MOONBIT_FFI_EXPORT
moonbit_bytes_t identity_native_sysname(void) {
  return identity_string_from_cstr("Windows");
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t identity_native_release(void) {
  return moonbit_make_bytes(0, 0);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t identity_native_arch(void) {
  return moonbit_make_bytes(0, 0);
}

#endif /* _WIN32 */
