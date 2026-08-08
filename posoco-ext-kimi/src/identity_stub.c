/*
 * Native host identity probes for the Kimi identity headers.
 *
 * Mirrors packages/oauth/src/identity.ts (MoonshotAI/kimi-code):
 *   - hostname     -> uname(2).nodename
 *   - os release   -> uname(2).release
 *   - device model -> "macOS <sw_vers -productVersion> <arch>" on Darwin,
 *                     "<sysname> <release> <arch>" elsewhere
 *
 * Each helper returns a fresh MoonBit Bytes (UTF-8, null-terminated by the
 * runtime); the MoonBit side decodes via @utf8.decode_lossy. On any failure
 * the helper returns an empty buffer, and kimi_ascii_header falls back to
 * "unknown" so a header value is never silently empty.
 */

#include <string.h>
#include "moonbit.h"

/* Copy a UTF-8 C string into a fresh MoonBit Bytes. Empty on null/blank.
 * Defined unconditionally at the top so every branch below can use it. */
static moonbit_bytes_t kimi_string_from_cstr(const char *cstr) {
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

#include <stdio.h>
#include <sys/utsname.h>

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_hostname(void) {
  struct utsname buf;
  if (uname(&buf) != 0) {
    return moonbit_make_bytes(0, 0);
  }
  return kimi_string_from_cstr(buf.nodename);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_os_release(void) {
  struct utsname buf;
  if (uname(&buf) != 0) {
    return moonbit_make_bytes(0, 0);
  }
  return kimi_string_from_cstr(buf.release);
}

/* Run `sw_vers -productVersion` on Darwin and return its trimmed stdout.
 * Returns an empty buffer if anything goes wrong (non-Darwin, fork/exec
 * failure, blank output). */
MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_macos_product_version(void) {
#if defined(__APPLE__) && defined(__MACH__)
  FILE *fp = popen("/usr/bin/sw_vers -productVersion", "r");
  if (fp == NULL) {
    return moonbit_make_bytes(0, 0);
  }
  char buf[64] = {0};
  size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
  pclose(fp);
  if (n == 0) {
    return moonbit_make_bytes(0, 0);
  }
  /* Strip trailing whitespace/newlines. */
  while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
                   buf[n - 1] == ' ' || buf[n - 1] == '\t')) {
    buf[--n] = '\0';
  }
  if (n == 0) {
    return moonbit_make_bytes(0, 0);
  }
  return kimi_string_from_cstr(buf);
#else
  return moonbit_make_bytes(0, 0);
#endif
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_arch(void) {
#if defined(__aarch64__) || defined(_M_ARM64)
  return kimi_string_from_cstr("arm64");
#elif defined(__x86_64__) || defined(_M_X64)
  return kimi_string_from_cstr("x64");
#elif defined(__arm__)
  return kimi_string_from_cstr("arm");
#else
  return kimi_string_from_cstr("");
#endif
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_sysname(void) {
  struct utsname buf;
  if (uname(&buf) != 0) {
    return moonbit_make_bytes(0, 0);
  }
  return kimi_string_from_cstr(buf.sysname);
}

#else /* _WIN32 */

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_hostname(void) {
  return moonbit_make_bytes(0, 0);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_os_release(void) {
  return moonbit_make_bytes(0, 0);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_macos_product_version(void) {
  return moonbit_make_bytes(0, 0);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_arch(void) {
#if defined(_M_X64)
  return kimi_string_from_cstr("x64");
#elif defined(_M_ARM64)
  return kimi_string_from_cstr("arm64");
#else
  return moonbit_make_bytes(0, 0);
#endif
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t kimi_native_sysname(void) {
  return kimi_string_from_cstr("Windows");
}

#endif /* _WIN32 */

