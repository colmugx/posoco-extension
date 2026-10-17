// Keep libc and Win32 symbols behind prefixed FFI names: moonc emits its own
// prototypes for extern bindings, which otherwise collide with system/access.
#include <stdlib.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include <wchar.h>

int herdr_ffi_windows_host(void) { return 1; }

// These two POSIX-only paths are never used on Windows. Export the symbols so
// the MoonBit native package can link the same extern declarations on all OSes.
int herdr_ffi_system(const char *cmd) { (void)cmd; return -1; }
int herdr_ffi_access_x(const char *path) { (void)path; return -1; }

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

static int herdr_regular_file(const wchar_t *path) {
  DWORD flags = GetFileAttributesW(path);
  return flags != INVALID_FILE_ATTRIBUTES && !(flags & FILE_ATTRIBUTE_DIRECTORY);
}

// Windows PATH uses ';', and executable names normally need a .exe suffix.
// SearchPathW implements native executable lookup without re-parsing PATH in
// MoonBit (which deliberately uses POSIX ':' semantics on Unix and JS).
int herdr_ffi_win_bin_runnable(const char *bin) {
  wchar_t *name = herdr_utf8_to_wide(bin);
  if (!name) return -1;
  int found = 0;
  if (wcschr(name, L'/') || wcschr(name, L'\\') || wcschr(name, L':')) {
    found = herdr_regular_file(name);
    if (!found) {
      const wchar_t *leaf = wcsrchr(name, L'\\');
      const wchar_t *slash = wcsrchr(name, L'/');
      if (!leaf || (slash && slash > leaf)) leaf = slash;
      leaf = leaf ? leaf + 1 : name;
      if (!wcschr(leaf, L'.')) {
        size_t len = wcslen(name);
        wchar_t *exe = (wchar_t *)malloc((len + 5) * sizeof(wchar_t));
        if (exe) {
          memcpy(exe, name, len * sizeof(wchar_t));
          memcpy(exe + len, L".exe", 5 * sizeof(wchar_t));
          found = herdr_regular_file(exe);
          free(exe);
        }
      }
    }
  } else {
    // SearchPathW returns the required buffer length when given a too-small
    // buffer. A fixed Windows maximum-sized buffer avoids truncation.
    wchar_t path[32768];
    DWORD len = SearchPathW(NULL, name, L".exe", 32768, path, NULL);
    found = len != 0 && len < 32768 && herdr_regular_file(path);
  }
  free(name);
  return found ? 0 : -1;
}

static int herdr_put(wchar_t *out, size_t *length, wchar_t ch) {
  if (*length >= 32766) return 0;  // Leave room for the terminating NUL.
  out[(*length)++] = ch;
  return 1;
}

// Quote one argv element following the Microsoft command-line parsing rules:
// a run of N backslashes before '"' expands to 2N+1, and trailing slashes
// before the closing quote expand to 2N. No cmd.exe is involved.
static int herdr_append_arg(wchar_t *out, size_t *length, const wchar_t *arg) {
  if (!herdr_put(out, length, L'"')) return 0;
  while (*arg) {
    size_t slashes = 0;
    while (*arg == L'\\') { ++slashes; ++arg; }
    if (*arg == L'"') {
      for (size_t i = 0; i < slashes * 2 + 1; ++i)
        if (!herdr_put(out, length, L'\\')) return 0;
      if (!herdr_put(out, length, L'"')) return 0;
      ++arg;
    } else if (!*arg) {
      for (size_t i = 0; i < slashes * 2; ++i)
        if (!herdr_put(out, length, L'\\')) return 0;
      break;
    } else {
      for (size_t i = 0; i < slashes; ++i)
        if (!herdr_put(out, length, L'\\')) return 0;
      if (!herdr_put(out, length, *arg++)) return 0;
    }
  }
  return herdr_put(out, length, L'"');
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
int herdr_ffi_access_x(const char *path) { return access(path, X_OK); }
int herdr_ffi_win_bin_runnable(const char *bin) { (void)bin; return -1; }
int herdr_ffi_win_spawn_report(const char *payload) { (void)payload; return -1; }
#endif
