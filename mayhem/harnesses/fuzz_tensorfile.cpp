// TensorFile container parsing (src/core/tensor.cpp): the header, the field
// table (name, dtype, rank, offset, shape) of the .tensor/.bsdf files used by
// measured BSDFs and sdfgrid, then a field lookup and the summary printer.
#include "common.h"
#include <mitsuba/core/tensor.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    mi_fuzz_init();
    // TensorFile maps a file by path; a fresh name per input, unlinked after.
    std::string path = mi_fuzz_write_tmp(data, size, ".tensor");
    try {
        ref<TensorFile> tf = new TensorFile(path);
        std::string s = tf->to_string();
        if (tf->has_field("data"))
            (void) tf->field("data").to_string();
        (void) s;
    } catch (const std::exception &) {
    }
    unlink(path.c_str());
    return 0;
}
