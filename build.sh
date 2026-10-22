#!/bin/bash
# 编 CodeWeavers 公开的 CrossOver wine 源码（x86_64 + i386 wow64），打包成 work/cx-wine.tar.gz。源码现场下载，不入库。
set -euo pipefail
VER=${CX_VERSION:-26.3.0}
W=$PWD/work; mkdir -p "$W/logs"; cd "$W"
step(){ echo "::group::$1"; }; end(){ echo "::endgroup::"; }

step deps
brew install mingw-w64 bison pkgconf gettext freetype gnutls sdl2 sdl3 molten-vk > logs/brew.log 2>&1 || { tail -30 logs/brew.log; exit 1; }
export PATH="$(brew --prefix bison)/bin:$PATH"
end

step source
curl -fL --retry 3 -o src.tgz "https://media.codeweavers.com/pub/crossover/source/crossover-sources-$VER.tar.gz"
tar -xzf src.tgz sources/wine && rm src.tgz
[ -f sources/wine/configure ] || { echo "源码包布局不对"; ls sources; exit 1; }
end

step configure
mkdir build install && cd build
../sources/wine/configure --prefix="$W/install" --disable-option-checking --disable-tests \
  --enable-archs=i386,x86_64 --without-x --without-wayland --without-alsa --without-capi --without-dbus \
  --without-oss --without-pulse --without-udev --without-v4l2 --without-gstreamer --without-cups \
  CFLAGS="-O2 -g0" CROSSCFLAGS="-O2 -g0" > ../logs/configure.log 2>&1 || { tail -40 ../logs/configure.log; exit 1; }
grep -q 'define SONAME_LIBVULKAN' include/config.h   # CW HACK 25909：win32u/vulkan.c 无条件引用，缺了会在 make 80 分钟后才炸
end

step make
make -j"$(sysctl -n hw.ncpu)" > ../logs/make.log 2>&1 || { tail -60 ../logs/make.log; exit 1; }
make install > ../logs/install.log 2>&1 || { tail -30 ../logs/install.log; exit 1; }
cd ..
end

step gate
nm -gU install/lib/wine/x86_64-unix/winemac.so | grep macdrv_functions
install/bin/wine --version
end

step bundle   # Wine 运行时 dlopen 这些 x86_64 dylib，目标机没有，连同依赖闭包一起带上
mkdir -p install/lib/ext
todo=("$(brew --prefix freetype)/lib/libfreetype.6.dylib" "$(brew --prefix gnutls)/lib/libgnutls.30.dylib" "$(brew --prefix sdl2)/lib/libSDL2-2.0.0.dylib" "$(brew --prefix sdl3)/lib/libSDL3.dylib")   # sdl2 现在是 sdl2-compat，运行时才 dlopen SDL3
while [ ${#todo[@]} -gt 0 ]; do
  f=${todo[0]}; todo=("${todo[@]:1}"); b=$(basename "$f")
  [ -e "install/lib/ext/$b" ] && continue
  cp -L "$f" "install/lib/ext/$b"
  while read -r dep; do todo+=("$dep"); done < <(otool -L "$f" | awk 'NR>1{print $1}' | grep -E '^/(usr/local|opt/homebrew)/' || true)
done
# @rpath/@loader_path 依赖上面的过滤会漏掉，补一道：闭包里没有同名文件就失败
while read -r f d; do [ -e "install/lib/ext/$(basename "$d")" ] || { echo "缺依赖 $d（来自 $f）"; exit 1; }; done \
  < <(for f in install/lib/ext/*; do otool -L "$f" | awk -v f="$f" 'NR>1 && $1 ~ /^@/ {print f, $1}'; done)
[ -e install/lib/ext/libSDL3.dylib ]
# 绝对路径 install name 改成 @loader_path，改完 ad-hoc 重签（改 install name 会使原签名失效）。
# Wine 经 DYLD_FALLBACK_LIBRARY_PATH 找到 ext 里的库，闭包内部互相引用靠这一步
for f in install/lib/ext/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$f")" "$f"
  while read -r dep; do install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f"; done \
    < <(otool -L "$f" | awk 'NR>1{print $1}' | grep -E '^/(usr/local|opt/homebrew)/' || true)
  codesign -f -s - "$f"
done
! otool -L install/lib/ext/*.dylib | grep -E "^[[:space:]]+/(usr/local|opt/homebrew)/"   # 不许残留绝对引用
ls install/lib/ext | tee logs/bundle.txt
tar -C install -czf cx-wine.tar.gz .
ls -l cx-wine.tar.gz
end
