/*
 * entropy_stub.c — native entropy probe for the PKCE browser flow.
 *
 * Returns a fresh MoonBit Bytes holding n bytes from getentropy(3) (same
 * Bytes-construction pattern as posoco-ext-kimi's identity_stub.c). On any
 * failure or unsupported platform (e.g. _WIN32) it returns an EMPTY Bytes so
 * the MoonBit side falls back to its time-seeded LCG. Never aborts.
 */

#include <string.h>
#include "moonbit.h"

#if defined(__APPLE__) || defined(__linux__)
#include <errno.h>
#include <sys/random.h>

MOONBIT_FFI_EXPORT
moonbit_bytes_t oauth_random_bytes(int32_t n) {
  if (n <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t bytes = moonbit_make_bytes(n, 0);
  unsigned char *dst = (unsigned char *)bytes;
  size_t filled = 0;
  while (filled < (size_t)n) {
    size_t chunk = (size_t)n - filled;
    if (chunk > 256) {
      chunk = 256; /* getentropy accepts at most 256 bytes per call */
    }
    if (getentropy(dst + filled, chunk) != 0) {
      if (errno == EINTR) {
        continue;
      }
      return moonbit_make_bytes(0, 0);
    }
    filled += chunk;
  }
  return bytes;
}

#else /* unsupported platform (e.g. _WIN32) */

MOONBIT_FFI_EXPORT
moonbit_bytes_t oauth_random_bytes(int32_t n) {
  (void)n;
  return moonbit_make_bytes(0, 0);
}

#endif
