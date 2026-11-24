// Full scene loading: parse_string -> transform_all -> instantiate (scalar_rgb),
// i.e. what `mitsuba scene.xml` does before rendering. Constructs every plugin
// the XML names (BSDFs, emitters, shapes, textures, sensors, films, integrators)
// and the Scene / kd-tree. No rendering.
#include "common.h"
#include <mitsuba/core/parser.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    mi_fuzz_init();
    parser::ParserConfig cfg("scalar_rgb");
    cfg.parallel = false;
    try {
        parser::ParserState state =
            parser::parse_string(cfg, std::string_view((const char *) data, size));
        parser::transform_all(cfg, state);
        std::vector<ref<Object>> objs = parser::instantiate(cfg, state);
        (void) objs;
    } catch (const std::exception &) {
    }
    return 0;
}
