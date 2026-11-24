// Text spectrum (.spd) reader: spectrum_from_file (src/core/spectrum.cpp),
// used by the `irregular`/`regular` spectrum plugins.
#include "common.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    mi_fuzz_init();
    std::string path = mi_fuzz_write_tmp(data, size, ".spd");
    try {
        std::vector<double> w, v;
        spectrum_from_file<double>(fs::path(path), w, v);
    } catch (const std::exception &) {
    }
    unlink(path.c_str());
    return 0;
}
