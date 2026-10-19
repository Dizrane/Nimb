#!/bin/bash
# The icons of the app (Resources/AppIcon.icns and Resources/AppIconActive.icns) are made by the art studio and are
# copied from art-studio/deliver/app-icon. They are no longer drawn by code.
set -euo pipefail
cd "$(dirname "$0")/.."
cp art-studio/deliver/app-icon/icon-idle.icns Resources/AppIcon.icns
cp art-studio/deliver/app-icon/icon-active.icns Resources/AppIconActive.icns
echo "Icons copied from art-studio/deliver/app-icon"
