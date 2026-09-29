#include <stdint.h>
#include "moonbit.h"

#if defined(_WIN32)
#define _CRT_RAND_S
#include <stdlib.h>

MOONBIT_FFI_EXPORT
moonbit_bytes_t board_random_bytes(int32_t n) {
  if (n <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t bytes = moonbit_make_bytes(n, 0);
  unsigned char *dst = (unsigned char *)bytes;
  int32_t i = 0;
  while (i < n) {
    unsigned int value = 0;
    if (rand_s(&value) != 0) {
      return moonbit_make_bytes(0, 0);
    }
    for (int j = 0; j < 4 && i < n; ++j, ++i) {
      dst[i] = (unsigned char)((value >> (j * 8)) & 0xffu);
    }
  }
  return bytes;
}

#elif defined(__APPLE__) || defined(__linux__)
#include <errno.h>
#include <sys/random.h>

MOONBIT_FFI_EXPORT
moonbit_bytes_t board_random_bytes(int32_t n) {
  if (n <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t bytes = moonbit_make_bytes(n, 0);
  unsigned char *dst = (unsigned char *)bytes;
  size_t filled = 0;
  while (filled < (size_t)n) {
    size_t chunk = (size_t)n - filled;
    if (chunk > 256) {
      chunk = 256;
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

#else

MOONBIT_FFI_EXPORT
moonbit_bytes_t board_random_bytes(int32_t n) {
  (void)n;
  return moonbit_make_bytes(0, 0);
}

#endif
