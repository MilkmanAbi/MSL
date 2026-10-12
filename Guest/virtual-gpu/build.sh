#!/bin/bash
# Builds the MSL virtual-GPU host renderer (virglrenderer + vtest) for macOS.
# See README.md. Usage: build.sh [workdir]   (default: ./build-tree)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=${1:-$here/build-tree}
tap=/opt/homebrew/Library/Taps/startergo/homebrew-virglrenderer/patches
A=/opt/homebrew/opt/angle; E=/opt/homebrew/opt/libepoxy
[ -d "$A" ] || { echo "need: brew install startergo/virglrenderer/virglrenderer (see README)"; exit 1; }

mkdir -p "$work" && cd "$work"
if [ ! -d virglrenderer-1.3.0 ]; then
    curl -L "https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/virglrenderer-1.3.0.tar.gz?ref_type=tags" -o v.tgz
    tar xzf v.tgz
    cd virglrenderer-1.3.0
    for p in "$tap"/virglrenderer-*.patch; do patch -p1 --batch -s -i "$p" || echo "skipped $(basename "$p")"; done
    patch -p1 --batch -i "$here/patches/msl-virglrenderer-macos.patch"
    cd ..
fi
cd virglrenderer-1.3.0
python3 -c "import yaml" 2>/dev/null || python3 -m pip install --user --quiet pyyaml
[ -d build ] || meson setup build --buildtype=release \
    "-Dc_args=-I$A/include" "-Dcpp_args=-I$A/include" \
    "--pkg-config-path=$A/lib/pkgconfig:$E/lib/pkgconfig" \
    "-Ddrm-renderers=[]" -Dvenus=false -Dtests=false -Dvideo=false -Dtracing=none
ninja -C build src/libvirglrenderer.1.dylib vtest/libvtest.a
# meson drops our extra link args for the server binary, so link it here.
cd build && clang -o vtest/virgl_test_server \
    vtest/virgl_test_server.p/meson-generated_.._.._src_gallium_u_format_table.c.o \
    vtest/virgl_test_server.p/vtest_main.c.o \
    -Wl,-headerpad_max_install_names -Wl,-rpath,@loader_path/../src \
    -Wl,-rpath,"$E/lib" -Wl,-rpath,"$A/lib" \
    vtest/libvtest.a src/libvirglrenderer.1.dylib src/libvirgl.a \
    src/gallium/libgallium.a src/mesa/libmesa.a -lm "$E/lib/libepoxy.dylib" \
    -L"$A/lib" -lEGL -framework OpenGL -framework Metal -framework CoreFoundation
echo "built: $PWD/vtest/virgl_test_server   (run with --no-fork, see README)"
