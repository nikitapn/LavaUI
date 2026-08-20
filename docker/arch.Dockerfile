# syntax=docker/dockerfile:1
# Arch: distro wlroots0.19, distro Boost, Swift from the extra package
# or the Ubuntu 24.04 tarball if extra is too old.
#
#   scripts/docker-test.sh arch
#   docker build -f docker/arch.Dockerfile .

FROM archlinux:latest

ARG LAVA_SWIFT_VERSION=6.3.3
ENV LAVA_SWIFT_VERSION=${LAVA_SWIFT_VERSION}

RUN pacman-key --init \
 && pacman-key --populate archlinux \
 && pacman -Syu --noconfirm

COPY packaging/deps /src/lava/packaging/deps
COPY scripts /src/lava/scripts
RUN /src/lava/scripts/install-deps.sh --yes \
 && /src/lava/scripts/install-swift.sh

COPY . /src/lava
WORKDIR /src/lava

ENV PATH="/opt/swift/usr/bin:/usr/local/bin:${PATH}" \
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"

RUN /src/lava/scripts/bootstrap.sh --no-deps --yes

RUN meson test -C build --print-errorlogs
RUN swift test
