// Keep libc and Win32 symbols behind prefixed FFI names: moonc emits its own
// prototypes for extern bindings, which otherwise collide with system().
#include <stdlib.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <wchar.h>

int herdr_ffi_windows_host(void) { return 1; }

// This POSIX-only path is never used on Windows. Export the symbol so the
// MoonBit native package can link the same extern declaration on all OSes.
int herdr_ffi_system(const char *cmd) { (void)cmd; return -1; }

static wchar_t *herdr_utf8_to_wide(const char *s) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
  if (count <= 0) return NULL;
  wchar_t *wide = (wchar_t *)malloc((size_t)count * sizeof(wchar_t));
  if (!wide) return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, wide, count)) {
    free(wide);
    return NULL;
  }
  return wide;
}

// Input: NUL-separated UTF-8 argv, with an additional empty element marking
// the end. Spawn is detached/non-blocking; all streams go to NUL. Parsing and
// quoting happen here, never in a shell, so --message is not executable code.
int herdr_ffi_win_spawn_report(const char *payload) {
  if (!payload || !*payload) return -1;
  wchar_t line[32768];
  size_t used = 0;
  const char *arg = payload;
  unsigned count = 0;
  while (*arg && count < 32) {
    wchar_t *wide = herdr_utf8_to_wide(arg);
    if (!wide) return -1;
    if (count && !herdr_put(line, &used, L' ')) { free(wide); return -1; }
    int ok = herdr_append_arg(line, &used, wide);
    free(wide);
    if (!ok) return -1;
    arg += strlen(arg) + 1;
    ++count;
  }
  if (!count || *arg) return -1;
  line[used] = L'\0';

  SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
  HANDLE nul = CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (nul == INVALID_HANDLE_VALUE) return -1;
  STARTUPINFOW startup = {0};
  PROCESS_INFORMATION process = {0};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = startup.hStdOutput = startup.hStdError = nul;
  BOOL started = CreateProcessW(NULL, line, NULL, NULL, TRUE,
                                CREATE_NO_WINDOW, NULL, NULL,
                                &startup, &process);
  CloseHandle(nul);
  if (!started) return -1;
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return 0;
}

#else
#include <unistd.h>

int herdr_ffi_windows_host(void) { return 0; }
int herdr_ffi_system(const char *cmd) { return system(cmd); }
int herdr_ffi_win_spawn_report(const char *payload) { (void)payload; return -1; }
#endif
