#!/bin/sh
set -eu
export LD_LIBRARY_PATH=/opt/native/lib
for name in libubox uci libnl-tiny ubus; do
    cmake -S "/src/$name" -B "/tmp/$name" \
        -DCMAKE_INSTALL_PREFIX=/opt/native -DCMAKE_PREFIX_PATH=/opt/native \
        -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DBUILD_STATIC=ON
    cmake --build "/tmp/$name" -j2
    cmake --install "/tmp/$name"
done
cd /src/odhcpd
patch -p1 < /tmp/lifetimes.patch
# Link the native daemon statically; the router keeps its packaged ubus/UCI ABI.
sed -i '/project(odhcpd LANGUAGES C)/a set(CMAKE_FIND_LIBRARY_SUFFIXES .a)' CMakeLists.txt
cmake -S . -B /tmp/odhcpd -DUBUS=ON -DDHCPV4_SUPPORT=OFF \
    -DCMAKE_PREFIX_PATH=/opt/native -Dlibuci=/tmp/uci/libuci.a -DCMAKE_EXE_LINKER_FLAGS=-static
cmake --build /tmp/odhcpd -j2
strip /tmp/odhcpd/odhcpd
cp /tmp/odhcpd/odhcpd /odhcpd
