/* Test-only permission observation on an already opened file. */
#include <moonbit.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/stat.h>
#endif

MOONBIT_FFI_EXPORT
#ifdef _WIN32
int cetas_workspace_test_file_mode(HANDLE fd) {
  (void)fd;
  return -1; /* @fs.open permissions are documented as ignored on Windows. */
#else
int cetas_workspace_test_file_mode(int fd) {
  struct stat info;
  if (fstat(fd, &info) < 0) return -1;
  return info.st_mode & 0777;
#endif
}
