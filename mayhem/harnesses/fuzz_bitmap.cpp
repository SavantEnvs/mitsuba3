// Bitmap image decoding from a stream through the public
// Bitmap(Stream*, FileFormat) constructor: the BMP / JPEG / OpenEXR / RGBE /
// PFM / PPM / TGA / PNG readers in src/core/bitmap.cpp (and the bundled
// OpenEXR, libpng, libjpeg-turbo), then a format conversion.
//
// Input layout: byte 0 selects the decoder (value % 8), the rest is the image.
// The decoder is named explicitly instead of FileFormat::Auto because
// Bitmap::detect_file_format() seeks to `stream->size() - 18` without a size
// check: any input shorter than 18 bytes without a known magic wraps that
// offset and MemoryStream::read() reads out of bounds (a real upstream bug,
// found on the first mutation, which would stop this target from reaching the
// decoders at all). Explicit formats are what Bitmap(path) uses for files with
// a known extension (format_from_extension), so this is the same API path a
// scene's bitmap textures and envmaps take.
//
// The image is read through a FileStream on a temp file, as Bitmap(path) does,
// not a MemoryStream: MemoryStream::read() (src/core/mstream.cpp) silently
// short-reads at EOF without throwing or writing the buffer, so
// Stream::read_line() (read_rgbe's header parser) spins forever on an
// uninitialized char for any truncated RGBE header -- an upstream hang that
// only exists on the in-memory path and that stopped Mayhem from fuzzing.
#include "common.h"
#include <mitsuba/core/fstream.h>

static const Bitmap::FileFormat kFormats[8] = {
    Bitmap::FileFormat::BMP,  Bitmap::FileFormat::JPEG, Bitmap::FileFormat::OpenEXR,
    Bitmap::FileFormat::RGBE, Bitmap::FileFormat::PFM,  Bitmap::FileFormat::PPM,
    Bitmap::FileFormat::TGA,  Bitmap::FileFormat::PNG,
};

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // No selector byte: nothing to decode.
    if (size == 0) return -1;
    mi_fuzz_init();
    Bitmap::FileFormat fmt = kFormats[data[0] % 8];
    std::string path = mi_fuzz_write_tmp(data + 1, size - 1, ".img");
    try {
        ref<FileStream> s = new FileStream(path, FileStream::ERead);
        ref<Bitmap> b = new Bitmap(s.get(), fmt);
        ref<Bitmap> c = b->convert(Bitmap::PixelFormat::RGB,
                                   sj::Type::Float32, false);
        (void) c;
    } catch (const std::exception &) {
    }
    unlink(path.c_str());
    return 0;
}
