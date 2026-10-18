#!/bin/bash
# Redraws Resources/AppIcon.icns and Resources/AppIconActive.icns.
# The halo is drawn by the same code as in the window (Sources/RDNS/HaloRenderer.swift).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/make_icons scripts/make_icon/main.swift Sources/RDNS/HaloRenderer.swift
build/make_icons
