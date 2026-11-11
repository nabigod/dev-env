#!/bin/bash

# Values are consumed by module.sh after this file is sourced.
# shellcheck disable=SC2034

# Temporary plugin floor until T-06 records the selected plugin requirements.
NVIM_PLUGIN_MIN_VERSION="0.10.0"

# Stable release assets and SHA-256 values from the v0.12.6 GitHub release API.
NVIM_RELEASE_VERSION="0.12.6"
NVIM_RELEASE_TAG="v0.12.6"
NVIM_RELEASE_MIN_GLIBC="2.34"
NVIM_RELEASE_X86_64_ASSET="nvim-linux-x86_64.tar.gz"
NVIM_RELEASE_X86_64_SHA256="474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87"
NVIM_RELEASE_ARM64_ASSET="nvim-linux-arm64.tar.gz"
NVIM_RELEASE_ARM64_SHA256="8f1f64a0bdb97247034038c3823c6cbad5bdf9ecd5751b85494b71c3ee04c815"
