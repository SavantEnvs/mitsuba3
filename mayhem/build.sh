#!/usr/bin/env bash
# mayhem/build.sh — build mitsuba3 (scalar_rgb variant) with ASan+UBSan and the fuzz harnesses,
# plus a separate normally-flagged build for mayhem/test.sh. Re-runnable and offline: every
# dependency is a git submodule under ext/ (checked out by CI with `submodules: recursive`).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS
cd "$SRC"

[ -f ext/drjit/ext/drjit-core/ext/nanothread/ext/cmake-defaults/CMakeLists.txt ] || {
  echo "git submodules are missing: run 'git submodule update --init --recursive'" >&2; exit 1; }

# Options shared by both builds:
#  - scalar_rgb only, no Python bindings, no Embree (native kd-tree);
#  - MI_ENABLE_JIT/MI_ENABLE_AUTODIFF=ON: libmitsuba references drjit-core/drjit-extra symbols
#    (src/core/packed.cpp, ad_traverse) even with only scalar variants, and only links them when
#    these are on (otherwise libmitsuba.so has undefined symbols). Dr.Jit's LLVM/CUDA backends are
#    loaded at runtime only and are never used by the scalar variant;
#  - MI_NATIVE_FLAGS: upstream defaults to -march=native; use upstream's own portable PyPI
#    baseline (haswell) so the binaries run on any fuzzing host;
#  - nanobind/include: object.h includes <nanobind/intrusive/ref.h>, which upstream only puts on
#    the include path when Python is enabled;
#  - `-include cmath`: kdtree.h uses std::nextafter in an Assert() that is only compiled without
#    NDEBUG (the fuzz build keeps assertions) and relies on a transitive <cmath>.
COMMON=(-G Ninja -DMI_ENABLE_PYTHON=OFF -DMI_ENABLE_EMBREE=OFF -DMI_ENABLE_JIT=ON
        -DMI_ENABLE_AUTODIFF=ON -DMI_DEFAULT_VARIANTS=scalar_rgb -DMI_NATIVE_FLAGS=-march=haswell)
EXTRA="-I$SRC/ext/nanobind/include -include cmath"

# 1) Sanitized + SanCov-instrumented project (libmitsuba + all plugins), assertions on.
#    Three UBSan checks are relaxed because they fire on EVERY input, before any input-dependent
#    code runs (kd-tree build of any scene: float->int cast in kdtree.h; memcpy(nullptr, .., 0)
#    in drjit/dynamic.h; `function`: struct-jit's Converter calls its runtime-generated pixel
#    conversion kernel through a function pointer, and -fsanitize=function reads the 8 bytes
#    before that JIT code, which start an mmap'd page -> SEGV in every Bitmap::convert()).
#    ASan's stack-use-after-return check is also off (-fsanitize-address-use-after-return=never):
#    the kd-tree builder's `static thread_local LocalBuildContext m_local` (kdtree.h:1089) keeps
#    `ctx` pointing at the BuildContext on build()'s stack, and its destructor writes through it
#    (kdtree.h:680) when the thread exits, so every process that built a scene's kd-tree crashes
#    in exit() after its input has finished (an upstream bug, independent of the input).
#    ASan's other checks and the rest of UBSan stay on and halting.
FZ="$SRC/build-fuzz"
UB_RELAX="-fno-sanitize=float-cast-overflow,nonnull-attribute,function"
case "$SANITIZER_FLAGS" in *address*) UB_RELAX="$UB_RELAX -fsanitize-address-use-after-return=never" ;; esac
[ -n "$SANITIZER_FLAGS" ] || UB_RELAX=""
FUZZ_FLAGS="$SANITIZER_FLAGS $UB_RELAX -fsanitize=fuzzer-no-link -O1 $DEBUG_FLAGS"
cmake -S "$SRC" -B "$FZ" "${COMMON[@]}" -DCMAKE_BUILD_TYPE=Debug \
      -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS $EXTRA" \
      -DCMAKE_C_FLAGS_DEBUG="" -DCMAKE_CXX_FLAGS_DEBUG=""
cmake --build "$FZ" -j"$MAYHEM_JOBS"

# 2) Harnesses: placed next to libmitsuba.so so $ORIGIN finds it and the plugins/ directory.
INC=(-I"$SRC/include" -I"$FZ/include" -I"$SRC/ext/tinyformat" -I"$SRC/ext/nanobind/include"
     -I"$SRC/ext/nanobind/ext/robin_map/include" -I"$SRC/ext/struct-jit/include"
     -I"$SRC/ext/drjit/include" -I"$SRC/ext/drjit/ext/drjit-core/include"
     -I"$SRC/ext/drjit/ext/drjit-core/ext/nanothread/include")
HFLAGS="$SANITIZER_FLAGS $UB_RELAX $DEBUG_FLAGS -O1 -std=gnu++17 -march=haswell -include cmath -DLITTLE_ENDIAN -DMI_ENABLE_AUTODIFF=1"
LIBS=(-L"$FZ" -Wl,-rpath,'$ORIGIN' -lmitsuba -ldrjit-core -ldrjit-extra -lnanothread -lstruct-jit -ldl -lpthread)
H="$SRC/mayhem/harnesses"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FZ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FZ/standalone_main.o"

build_harness() {  # name source [extra -D flags...]
  local name="$1" src="$2"; shift 2
  $CXX $HFLAGS "${INC[@]}" "$@" -c "$src" -o "$FZ/$name.o"
  $CXX $HFLAGS $LIB_FUZZING_ENGINE "$FZ/$name.o" "$FZ/lsan_off.o" "${LIBS[@]}" -o "$FZ/$name"
  $CXX $HFLAGS "$FZ/$name.o" "$FZ/standalone_main.o" "$FZ/lsan_off.o" "${LIBS[@]}" -o "$FZ/$name-standalone"
}
build_harness fuzz_xml_parse     "$H/fuzz_xml_parse.cpp"
build_harness fuzz_scene_load    "$H/fuzz_scene_load.cpp"
build_harness fuzz_bitmap        "$H/fuzz_bitmap.cpp"
build_harness fuzz_volumegrid    "$H/fuzz_volumegrid.cpp"
build_harness fuzz_spectrum_file "$H/fuzz_spectrum_file.cpp"
build_harness fuzz_shape_ply        "$H/fuzz_plugin_file.cpp" -DMI_FUZZ_PLUGIN='"ply"'        -DMI_FUZZ_TYPE=Shape   -DMI_FUZZ_SUFFIX='".ply"'
build_harness fuzz_shape_obj        "$H/fuzz_plugin_file.cpp" -DMI_FUZZ_PLUGIN='"obj"'        -DMI_FUZZ_TYPE=Shape   -DMI_FUZZ_SUFFIX='".obj"'
build_harness fuzz_shape_serialized "$H/fuzz_plugin_file.cpp" -DMI_FUZZ_PLUGIN='"serialized"' -DMI_FUZZ_TYPE=Shape   -DMI_FUZZ_SUFFIX='".serialized"'
build_harness fuzz_emitter_envmap   "$H/fuzz_plugin_file.cpp" -DMI_FUZZ_PLUGIN='"envmap"'     -DMI_FUZZ_TYPE=Emitter -DMI_FUZZ_SUFFIX='".img"'
build_harness fuzz_tensorfile     "$H/fuzz_tensorfile.cpp"
build_harness fuzz_bsdf_measured      "$H/fuzz_plugin_file.cpp" -DMI_FUZZ_PLUGIN='"measured"'     -DMI_FUZZ_TYPE=BSDF  -DMI_FUZZ_SUFFIX='".bsdf"'
build_harness fuzz_shape_packed       "$H/fuzz_plugin_file.cpp" -DMI_FUZZ_PLUGIN='"packed"'       -DMI_FUZZ_TYPE=Shape -DMI_FUZZ_SUFFIX='".packed"'

# 3) Test build: upstream's default (Release) flags, no sanitizers; test.sh renders with its CLI.
TB="$SRC/build-tests"
cmake -S "$SRC" -B "$TB" "${COMMON[@]}" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$EXTRA $COVERAGE_FLAGS"
cmake --build "$TB" -j"$MAYHEM_JOBS"
