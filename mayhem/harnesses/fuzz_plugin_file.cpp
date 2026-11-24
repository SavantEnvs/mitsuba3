// A file-loading plugin, instantiated through the PluginManager exactly as a
// scene's <shape type="ply"><string name="filename" .../></shape> would be.
// Built once per plugin with -DMI_FUZZ_PLUGIN=... -DMI_FUZZ_TYPE=... -DMI_FUZZ_SUFFIX=...
#include "common.h"
#include <mitsuba/core/plugin.h>
#include <mitsuba/core/properties.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    mi_fuzz_init();
    // A fresh file name per input: no file-level cache can carry state over.
    std::string path = mi_fuzz_write_tmp(data, size, MI_FUZZ_SUFFIX);
    try {
        Properties props(MI_FUZZ_PLUGIN);
        props.set("filename", path);
        ref<Object> obj = PluginManager::instance()->create_object(
            props, "scalar_rgb", ObjectType::MI_FUZZ_TYPE);
        (void) obj;
    } catch (const std::exception &) {
    }
    unlink(path.c_str());
    return 0;
}
