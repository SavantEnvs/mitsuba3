// Shared setup for the mitsuba3 fuzz harnesses (scalar_rgb variant only).
#pragma once
#include <mitsuba/core/bitmap.h>
#include <mitsuba/core/filesystem.h>
#include <mitsuba/core/fresolver.h>
#include <mitsuba/core/logger.h>
#include <mitsuba/core/profiler.h>
#include <mitsuba/core/spectrum.h>
#include <mitsuba/core/thread.h>
#include <mitsuba/core/util.h>
#include <mitsuba/render/scene.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

using namespace mitsuba;

// Same initialization sequence as the `mitsuba` CLI (src/mitsuba/mitsuba.cpp).
// The log level is set once here and is never changed by an input.
static inline void mi_fuzz_init() {
    static bool done = false;
    if (done) return;
    done = true;
    // ASan cannot dlopen() with RTLD_DEEPBIND; upstream skips it when this is set (plugin.cpp).
    setenv("DRJIT_NO_RTLD_DEEPBIND", "1", 1);
    Thread::static_initialization();
    Logger::static_initialization();
    Bitmap::static_initialization();
    Profiler::static_initialization();
    color_management_static_initialization(false, false, false);
    Scene<float, Color<float, 3>>::static_accel_initialization();
    // Like the CLI (mitsuba.cpp), make the directory holding libmitsuba.so a FileResolver
    // search path: PluginManager resolves "plugins/<name>.so" through it, and the default
    // resolver only holds the cwd, which is not build-fuzz/ under Mayhem.
    fs::path base_path = util::library_path().parent_path();
    ref<FileResolver> fr = file_resolver();
    if (!fr->contains(base_path))
        fr->prepend(base_path);
    Thread::thread()->logger()->set_log_level(mitsuba::LogLevel::Error);
    Thread::thread()->logger()->set_error_level(mitsuba::LogLevel::Error);
}

// Writes the input to a fresh file under $TMPDIR (relative paths only via
// mkstemps; never under the read-only image dir). Caller unlinks it.
static inline std::string mi_fuzz_write_tmp(const uint8_t *data, size_t size,
                                            const char *suffix) {
    const char *tmp = getenv("TMPDIR");
    std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/mifuzzXXXXXX" + suffix;
    std::string buf(tmpl);
    int fd = mkstemps(&buf[0], (int) strlen(suffix));
    if (fd < 0) abort();
    size_t off = 0;
    while (off < size) {
        ssize_t n = write(fd, data + off, size - off);
        if (n <= 0) abort();
        off += (size_t) n;
    }
    close(fd);
    return buf;
}
