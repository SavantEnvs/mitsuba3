// Mitsuba .vol volume grid reader (src/render/volumegrid.cpp), as used by the
// `gridvolume` plugin.
#include "common.h"
#include <mitsuba/core/mstream.h>
#include <mitsuba/render/volumegrid.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    mi_fuzz_init();
    try {
        std::string copy((const char *) data, size);
        ref<MemoryStream> s = new MemoryStream(copy.data(), copy.size());
        ref<VolumeGrid<float, Color<float, 3>>> g =
            new VolumeGrid<float, Color<float, 3>>(s.get());
        (void) g;
    } catch (const std::exception &) {
    }
    return 0;
}
