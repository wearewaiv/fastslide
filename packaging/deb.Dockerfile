# syntax=docker/dockerfile:1.7
#
# Builds FastSlide C API .deb packages (runtime + dev) for a given
# Debian/Ubuntu base image and architecture, exported via the `export`
# stage. `smoke-test` installs both .debs with `apt install` in a clean
# container to check they actually work.
#
# Usage:
#   docker buildx build \
#     --platform linux/amd64 \
#     --build-arg BASE_IMAGE=debian:trixie-slim \
#     --build-arg DISTRO_LABEL=debian-trixie \
#     --target export \
#     --output type=local,dest=dist \
#     -f packaging/deb.Dockerfile .
#
#   docker buildx build \
#     --platform linux/amd64 \
#     --build-arg BASE_IMAGE=debian:trixie-slim \
#     --target smoke-test \
#     -f packaging/deb.Dockerfile .

ARG BASE_IMAGE=debian:trixie-slim

FROM ${BASE_IMAGE} AS builder

ARG TARGETARCH
ARG DISTRO_LABEL=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    DISTRO_LABEL=${DISTRO_LABEL}

# jxrlib's test harness (a wrap dependency we don't even use) hits GCC 14's
# strict -Werror=incompatible-pointer-types. Static libstdc++/libgcc avoids a
# runtime libstdc++6 dependency (everything else static-linkable is already
# baked in via default_library=static).
ENV CFLAGS="-Wno-error=incompatible-pointer-types" \
    CXXFLAGS="-Wno-error=incompatible-pointer-types -Wno-error" \
    LDFLAGS="-static-libstdc++ -static-libgcc"

# jpeg-dev package name differs between Debian and Ubuntu.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    . /etc/os-release && \
    case "$ID" in \
      debian) JPEG_DEV=libjpeg-dev ;; \
      ubuntu) JPEG_DEV=libjpeg-turbo8-dev ;; \
      *) echo "Unsupported base image ID=$ID" >&2; exit 1 ;; \
    esac && \
    apt-get update && apt-get upgrade -y && \
    apt-get install --no-install-recommends -y \
      build-essential ninja-build meson pkg-config git \
      ca-certificates python3 \
      "$JPEG_DEV" libopenjp2-7-dev libpng-dev libtiff-dev libzstd-dev zlib1g-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/src/fastslide
COPY . .

RUN meson setup builddir \
      -Db_lto=true -Dbuild_tests=false -Dbuild_tool=false \
      -Dbuild_python=false -Dbuild_c_api=true -Dshared_c_api=true \
      -Dsimpletiff:default_library=static

# Genuine upstream bug: jpeglib.h uses FILE* without pulling in
# <cstdio>/<stdio.h> transitively. The pinned simpletiff wrap revision
# predates the fix.
RUN IO_UTILS="subprojects/simpletiff/src/io_utils_libjpeg.cpp" && \
    grep -q '<cstdio>' "$IO_UTILS" || sed -i '1i #include <cstdio>' "$IO_UTILS"

RUN meson compile -C builddir fastslide_c

RUN packaging/build.sh

FROM scratch AS export
COPY --from=builder /export/*.deb /

# Installs both .debs with `apt install` (resolves Depends: automatically,
# unlike `dpkg -i`) in a clean container, then compiles+links+runs a program
# against the dev package to prove it actually works for a consumer.
FROM ${BASE_IMAGE} AS smoke-test

COPY --from=builder /export/*.deb /tmp/

RUN apt-get update && \
    apt-get install --no-install-recommends -y gcc libc6-dev pkg-config \
      /tmp/fastslide-capi_*.deb /tmp/fastslide-capi-dev_*.deb && \
    rm -rf /var/lib/apt/lists/* /tmp/*.deb && \
    ldconfig && \
    ldconfig -p | grep -q 'libfastslide_c\.so' && \
    PKG_CONFIG_PATH=/usr/lib/pkgconfig pkg-config --exists fastslide && \
    PKG_CONFIG_PATH=/usr/lib/pkgconfig pkg-config --modversion fastslide && \
    printf '%s\n' \
      '#include <fastslide/c/registry.h>' \
      '#include <stdio.h>' \
      'int main(void) {' \
      '  printf("fastslide_get_version: %s\n", fastslide_get_version());' \
      '  return 0;' \
      '}' \
      > /tmp/test.c && \
    cc /tmp/test.c $(PKG_CONFIG_PATH=/usr/lib/pkgconfig pkg-config --cflags --libs fastslide) -o /tmp/test && \
    ! ldd /tmp/test | grep -qi 'not found' && \
    /tmp/test
