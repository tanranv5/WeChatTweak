// Guard the downloaded native patch paths. WCDY also loads bundled code:
// preserve its first setConfig argument and redirect only the download root.
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <os/log.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern void wcdy_set_config(const char *, const char *)
    __asm("__ZN4WCDY9setConfigEPKcS1_") __attribute__((weak_import));

static const char container_anchor[] =
    "/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/";

static bool component(const char *path, const char *name) {
    size_t n = strlen(name);
    return strncmp(path, name, n) == 0 && (path[n] == '/' || path[n] == '\0');
}

// This is a path policy, not a general-purpose executable-code sandbox.
static bool patch_path(const char *path) {
    const char *anchor = strstr(path, container_anchor);
    if (!anchor) return false;
    const char *relative = anchor + sizeof(container_anchor) - 1;
    if (component(relative, "magic") || component(relative, "magicdy"))
        return true;
    static const char plugins[] = "xplugin/plugins/";
    if (strncmp(relative, plugins, sizeof(plugins) - 1) != 0) return false;
    relative += sizeof(plugins) - 1;
    return component(relative, "Magic") || component(relative, "Magicdy");
}

static bool blocked(int directory, const char *path) {
    if (!path) return false;
    char absolute[PATH_MAX];
    if (path[0] == '/') {
        if (strlen(path) >= sizeof(absolute)) return false;
        strcpy(absolute, path);
    } else {
        char base[PATH_MAX];
        if (directory == AT_FDCWD) {
            if (!getcwd(base, sizeof(base))) return false;
        } else if (fcntl(directory, F_GETPATH, base) == -1) {
            return false;
        }
        int n = snprintf(absolute, sizeof(absolute), "%s/%s", base, path);
        if (n < 0 || (size_t)n >= sizeof(absolute)) return false;
    }

    // Normalize dot components before matching. Do not reject a harmless
    // ".../magic/../other" path, or miss ".../app_data/./magic/update".
    char normalized[PATH_MAX];
    size_t length = 1;
    normalized[0] = '/';
    char *cursor = absolute;
    while (*cursor) {
        while (*cursor == '/') cursor++;
        char *start = cursor;
        while (*cursor && *cursor != '/') cursor++;
        size_t count = (size_t)(cursor - start);
        if (!count || (count == 1 && start[0] == '.')) continue;
        if (count == 2 && start[0] == '.' && start[1] == '.') {
            if (length > 1) {
                while (length > 1 && normalized[length - 1] != '/') length--;
                if (length > 1) length--;
            }
            continue;
        }
        if (length > 1) normalized[length++] = '/';
        memcpy(normalized + length, start, count);
        length += count;
    }
    normalized[length] = '\0';
    if (patch_path(normalized)) return true;
    // Also reject aliases into a patch directory.
    char resolved[PATH_MAX];
    return realpath(normalized, resolved) && patch_path(resolved);
}

static void denied(void) {
    static atomic_flag reported = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set(&reported)) {
        static const char message[] =
            "WeChatTweak: denied access to a Magic/Magicdy patch artifact\n";
        (void)write(STDERR_FILENO, message, sizeof(message) - 1);
        os_log(OS_LOG_DEFAULT, "WeChatTweakHotPatch: artifact-access-denied");
    }
    errno = EACCES;
}

static int guarded_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (blocked(AT_FDCWD, path)) { denied(); return -1; }
    return open(path, flags, mode);
}

static int guarded_openat(int directory, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (blocked(directory, path)) { denied(); return -1; }
    return openat(directory, path, flags, mode);
}

static FILE *guarded_fopen(const char *path, const char *mode) {
    if (blocked(AT_FDCWD, path)) { denied(); return NULL; }
    return fopen(path, mode);
}

static void *guarded_dlopen(const char *path, int mode) {
    if (blocked(AT_FDCWD, path)) {
        denied();
        // Ask dyld to set a real dlerror value for the caller.
        return dlopen("/dev/null/wechattweak-hotpatch-denied", mode);
    }
    return dlopen(path, mode);
}

static void guarded_set_config(const char *bundle, const char *download) {
    (void)download;
    // setConfig canonicalizes roots and adds a slash. /dev/null is a file,
    // so every attempted child lookup fails; an empty string would mean "/".
    if (wcdy_set_config) {
        static atomic_flag reported = ATOMIC_FLAG_INIT;
        if (!atomic_flag_test_and_set(&reported)) {
            static const char message[] =
                "WeChatTweak: WCDY downloaded-code root disabled; bundle root preserved\n";
            (void)write(STDERR_FILENO, message, sizeof(message) - 1);
            os_log(OS_LOG_DEFAULT, "WeChatTweakHotPatch: wcdy-download-root-disabled");
        }
        wcdy_set_config(bundle, "/dev/null");
    }
}

// Calls from this image to the original functions are not interposed by dyld.
// The weak WCDY import is checked by the installer before this library is used.
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replace; const void *original; } \
    interpose_##replacement = { (const void *)&replacement, (const void *)&original }

INTERPOSE(guarded_open, open);
INTERPOSE(guarded_openat, openat);
INTERPOSE(guarded_fopen, fopen);
INTERPOSE(guarded_dlopen, dlopen);
INTERPOSE(guarded_set_config, wcdy_set_config);
