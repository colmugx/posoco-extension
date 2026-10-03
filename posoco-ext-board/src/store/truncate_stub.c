#include <stdint.h>
#include <errno.h>
#include "moonbit.h"

#if defined(__APPLE__) || defined(__linux__)
#include <unistd.h>

// The async fs API has fsync/rename but no truncate. No MoonBit objects
// cross this seam; the caller owns the descriptor throughout the call.
MOONBIT_FFI_EXPORT
int32_t board_store_truncate(int32_t fd, int64_t length) {
  int status;
  do {
    status = ftruncate(fd, (off_t)length);
  } while (status != 0 && errno == EINTR);
  return status == 0 ? 0 : errno;
}
#else
MOONBIT_FFI_EXPORT
int32_t board_store_truncate(int32_t fd, int64_t length) {
  (void)fd;
  (void)length;
  return ENOSYS;
}
#endif
