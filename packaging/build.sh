#!/bin/sh
# Assembles the fastslide-capi (runtime) and fastslide-capi-dev packages by
# hand instead of via debhelper: libfastslide_c.so is built with
# install: false upstream (it's shipped by manual copy for the Java FFM
# artifact, not `meson install`), so there is nothing for dh_auto_install to
# package in the first place.
#
# Depends: in control.in is a static, hand-maintained list (like openslide's
# debhelper-generated ${shlibs:Depends}, just without debhelper to compute
# it). If fastslide's dependency set changes, re-derive it with:
#   ldd builddir/libfastslide_c.so | awk '/=>/ {print $3}' | xargs -r dpkg -S
set -eu

cd "$(dirname "$0")/.."

VERSION=$(grep -oP "^\s*version\s*:\s*'\K[^']+" meson.build | head -1)
ARCH=$(dpkg --print-architecture)

# Runtime jpeg-turbo package name differs between Debian and Ubuntu (same
# split as the -dev package in deb.Dockerfile). Sourced in a subshell so
# os-release's own VERSION= doesn't clobber ours above.
ID=$(. /etc/os-release && echo "$ID")
case "$ID" in
  debian) JPEG_RUNTIME=libjpeg62-turbo ;;
  ubuntu) JPEG_RUNTIME=libjpeg-turbo8 ;;
  *) echo "Unsupported base image ID=$ID" >&2; exit 1 ;;
esac

RUNTIME=/tmp/fastslide-capi
DEV=/tmp/fastslide-capi-dev

# --- runtime package ---
install -d "$RUNTIME"/usr/lib/fastslide "$RUNTIME"/DEBIAN "$RUNTIME"/etc/ld.so.conf.d
cp builddir/libfastslide_c.so "$RUNTIME"/usr/lib/fastslide/
cp packaging/fastslide-capi.conf "$RUNTIME"/etc/ld.so.conf.d/
install -m 755 packaging/postinst "$RUNTIME"/DEBIAN/postinst

# --- dev package: headers + pkg-config + unversioned .so symlink ---
install -d "$DEV"/usr/include "$DEV"/usr/lib/fastslide "$DEV"/usr/lib/pkgconfig "$DEV"/DEBIAN
cp -a include/fastslide "$DEV"/usr/include/
ln -sf libfastslide_c.so "$DEV"/usr/lib/fastslide/libfastslide.so
sed "s/@VERSION@/${VERSION}/" packaging/fastslide.pc.in > "$DEV"/usr/lib/pkgconfig/fastslide.pc

# --- split the two-stanza control template, substitute placeholders ---
sed -n '/^Package: fastslide-capi$/,/^$/p' packaging/control.in \
  | sed -e "s/@VERSION@/${VERSION}/" -e "s/@ARCH@/${ARCH}/" -e "s/@JPEG_RUNTIME@/${JPEG_RUNTIME}/" \
  > "$RUNTIME"/DEBIAN/control
sed -n '/^Package: fastslide-capi-dev$/,/^$/p' packaging/control.in \
  | sed -e "s/@VERSION@/${VERSION}/" -e "s/@ARCH@/${ARCH}/" \
  > "$DEV"/DEBIAN/control

dpkg-deb --build --root-owner-group "$RUNTIME" /tmp/fastslide-capi_"${VERSION}"-1_"${ARCH}".deb
dpkg-deb --build --root-owner-group "$DEV" /tmp/fastslide-capi-dev_"${VERSION}"-1_"${ARCH}".deb

mkdir -p /export
cp /tmp/fastslide-capi_"${VERSION}"-1_"${ARCH}".deb /export/fastslide-capi_"${VERSION}"-1_"${DISTRO_LABEL}"_"${ARCH}".deb
cp /tmp/fastslide-capi-dev_"${VERSION}"-1_"${ARCH}".deb /export/fastslide-capi-dev_"${VERSION}"-1_"${DISTRO_LABEL}"_"${ARCH}".deb
