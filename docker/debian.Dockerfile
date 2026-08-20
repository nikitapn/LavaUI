# syntax=docker/dockerfile:1
# Debian 13 (trixie): the path a real Debian box takes — distro packages,
# wlroots 0.19 from source (trixie still has 0.18), NPRPC from GitHub,
# Swift from the Ubuntu 24.04 tarball.
#
#   scripts/docker-test.sh debian
#   docker build -f docker/debian.Dockerfile .
#
# The last two RUN steps are the test: meson test + swift test. A failed
# test fails the image.

FROM debian:trixie

ARG LAVA_SWIFT_VERSION=6.3.3
ENV DEBIAN_FRONTEND=noninteractive \
    LAVA_SWIFT_VERSION=${LAVA_SWIFT_VERSION}

# Layer 1: package lists + installer. Changing Lava sources does not
# re-download Swift or apt packages.
COPY packaging/deps /src/lava/packaging/deps
COPY scripts /src/lava/scripts
RUN /src/lava/scripts/install-deps.sh --yes \
 && /src/lava/scripts/install-swift.sh

# Layer 2: the tree. fetch-nprpc is a no-op if third-party/nprpc arrived
# in the context (sibling checkout / previous fetch).
COPY . /src/lava
WORKDIR /src/lava

ENV PATH="/opt/swift/usr/bin:/usr/local/bin:${PATH}" \
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig"

RUN /src/lava/scripts/bootstrap.sh --no-deps --yes

RUN meson test -C build --print-errorlogs
RUN swift test
