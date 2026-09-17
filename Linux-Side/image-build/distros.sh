#!/bin/sh
# The distros MSL builds images for. Sourced, not executed.
#
# `distro_base_image NAME` prints the official arm64 container image a
# distro's disk is built from. Every one of these was checked on 2026-09-14
# to publish a linux/arm64 manifest and to carry every package in
# provision/packages.sh's REQUIRED tier.
#
# Red Hat's own UBI 10 image is deliberately absent: its repositories have no
# e2fsprogs (REQUIRED - resize2fs, e2fsck) and no xterm, and full RHEL needs a
# subscription. Rocky, Alma, CentOS Stream and Oracle Linux cover that
# family.

distro_base_image() {
    case "$1" in
    alpine)  echo "alpine:3.24" ;;
    debian)  echo "debian:13-slim" ;;
    ubuntu)  echo "ubuntu:26.04" ;;
    kali)    echo "kalilinux/kali-rolling:latest" ;;
    # Arch Linux ARM; plain archlinux has no arm64. menci's rather than
    # lopsided's: lopsided/archlinux ships no /etc/os-release, so nothing can
    # tell what distro it is.
    arch)    echo "menci/archlinuxarm:latest" ;;
    fedora)  echo "fedora:44" ;;
    rocky)   echo "rockylinux/rockylinux:10" ;;
    alma)    echo "almalinux:10" ;;
    centos)  echo "quay.io/centos/centos:stream10" ;;
    oracle)  echo "oraclelinux:10" ;;
    opensuse) echo "opensuse/leap:16.0" ;;
    nix)     echo "debian:13-slim" ;;                  # Nix the package manager, on Debian
    *) return 1 ;;
    esac
}

# `distro_release NAME` prints the release tag that goes in a published
# image's file name - msl-<name>-<release>-arm64.img.xz. Written out rather
# than read from the image's /etc/os-release: that file is a symlink on some
# distros and has already been misread once, and a file name that silently
# changes with a point release would break every link to it.
distro_release() {
    case "$1" in
    alpine)  echo "3.24" ;;
    debian)  echo "13" ;;
    ubuntu)  echo "26.04" ;;
    kali)    echo "rolling" ;;
    arch)    echo "rolling" ;;
    fedora)  echo "44" ;;
    rocky)   echo "10.2" ;;
    alma)    echo "10.2" ;;
    centos)  echo "stream10" ;;
    oracle)  echo "10.2" ;;
    opensuse) echo "leap16.0" ;;
    nix)     echo "debian13" ;;
    *) return 1 ;;
    esac
}

MSL_DISTROS="alpine debian ubuntu kali arch fedora rocky alma centos oracle opensuse nix"
