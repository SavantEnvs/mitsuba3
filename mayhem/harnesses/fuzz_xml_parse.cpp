// Scene XML front end: parse_string -> transform_all -> write_string.
// Reaches src/core/parser.cpp (XML -> IR, version upgrade, reference resolution,
// merging, reordering) and pugixml, without loading any plugin.
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
        std::string out = parser::write_string(state, true);
        (void) out;
    } catch (const std::exception &) {
    }
    return 0;
}
