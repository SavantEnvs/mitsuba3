#!/usr/bin/env bash
# mayhem/test.sh — known-answer render tests for mitsuba3, run with the normally-flagged `mitsuba`
# CLI that mayhem/build.sh built in build-tests/. Each test renders a tiny analytic scene to a PFM
# and checks pixel values (or, for a malformed scene, the reported error). Does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

MI="$SRC/build-tests/mitsuba"
[ -x "$MI" ] || { echo "missing $MI — mayhem/build.sh did not build the test CLI" >&2; emit_ctrf mitsuba-render 0 1; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/mitest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
passed=0; failed=0

# check_pfm <pfm> <x> <y> <r> <g> <b> [tol]   — pixel (x,y), y counted from the top
check_pfm() {
  python3 -I - "$@" <<'PY'
import struct, sys
path, x, y, r, g, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), *map(float, sys.argv[4:7])
tol = float(sys.argv[7]) if len(sys.argv) > 7 else 1e-3
data = open(path, 'rb').read()
parts = data.split(b'\n', 3)
assert parts[0] == b'PF', parts[0]
w, h = map(int, parts[1].split()); scale = float(parts[2])
fmt = '<' if scale < 0 else '>'
px = struct.unpack(fmt + 'f' * (w * h * 3), parts[3][:w * h * 12])
row = h - 1 - y  # PFM stores rows bottom-to-top
got = px[(row * w + x) * 3:(row * w + x) * 3 + 3]
ok = all(abs(a - e) <= tol for a, e in zip(got, (r, g, b)))
print(f"  pixel({x},{y}) = {tuple(round(v, 4) for v in got)} expected {(r, g, b)}")
sys.exit(0 if ok else 1)
PY
}

scene() {  # scene <file> <width> <extra xml>
  cat > "$1" <<XML
<scene version="3.0.0">
  <integrator type="path"><integer name="max_depth" value="4"/></integrator>
  <sensor type="perspective">
    <float name="fov" value="30"/>
    <transform name="to_world"><lookat origin="0, 0, -5" target="0, 0, 0" up="0, 1, 0"/></transform>
    <sampler type="independent"><integer name="sample_count" value="16"/></sampler>
    <film type="hdrfilm">
      <integer name="width" value="$2"/><integer name="height" value="$2"/>
      <string name="file_format" value="pfm"/><string name="pixel_format" value="rgb"/>
      <rfilter type="box"/>
    </film>
  </sensor>
  <emitter type="constant"><rgb name="radiance" value="0.25, 0.5, 0.75"/></emitter>
  $3
</scene>
XML
}

run_test() {  # run_test <name> <commands...>
  local name="$1"; shift
  if "$@"; then echo "PASS $name"; passed=$((passed + 1)); else echo "FAIL $name"; failed=$((failed + 1)); fi
}

render() {  # render <scene.xml> <out.pfm>
  rm -f "$2"
  "$MI" -o "$2" "$1" > "$W/log.txt" 2>&1 || { cat "$W/log.txt"; return 1; }
  [ -s "$2" ] || { echo "  no output image"; return 1; }
}

# 1) Empty scene lit by a constant environment: every pixel sees exactly the env radiance.
t_env() {
  scene "$W/env.xml" 4 ""
  render "$W/env.xml" "$W/env.pfm" &&
  check_pfm "$W/env.pfm" 0 0 0.25 0.5 0.75 && check_pfm "$W/env.pfm" 3 2 0.25 0.5 0.75
}
run_test constant_environment t_env

# 2) A black (zero-albedo) sphere in the middle: centre pixels are 0, corners see the environment.
t_sphere() {
  scene "$W/sphere.xml" 16 '<shape type="sphere"><float name="radius" value="1"/><bsdf type="diffuse"><rgb name="reflectance" value="0"/></bsdf></shape>'
  render "$W/sphere.xml" "$W/sphere.pfm" &&
  check_pfm "$W/sphere.pfm" 8 8 0 0 0 && check_pfm "$W/sphere.pfm" 0 0 0.25 0.5 0.75 &&
  check_pfm "$W/sphere.pfm" 15 15 0.25 0.5 0.75
}
run_test black_sphere t_sphere

# 3) A white diffuse sphere under a uniform environment (furnace test): radiance is conserved,
#    so the sphere is invisible up to path-depth truncation — centre pixel ~ environment.
t_furnace() {
  scene "$W/furnace.xml" 16 '<shape type="sphere"><float name="radius" value="1"/><bsdf type="diffuse"><rgb name="reflectance" value="1"/></bsdf></shape>'
  sed -i 's/name="max_depth" value="4"/name="max_depth" value="64"/' "$W/furnace.xml"
  render "$W/furnace.xml" "$W/furnace.pfm" && check_pfm "$W/furnace.pfm" 8 8 0.25 0.5 0.75 0.02
}
run_test white_furnace t_furnace

# 4) A malformed scene is rejected with a parser error and no image.
t_bad() {
  printf '<scene version="3.0.0"><shape type="sphere">\n' > "$W/bad.xml"
  rm -f "$W/bad.pfm"
  "$MI" -o "$W/bad.pfm" "$W/bad.xml" > "$W/bad.log" 2>&1
  grep -q "Parsing of XML file" "$W/bad.log" && [ ! -e "$W/bad.pfm" ] || { cat "$W/bad.log"; return 1; }
}
run_test malformed_scene t_bad

emit_ctrf mitsuba-render "$passed" "$failed"
