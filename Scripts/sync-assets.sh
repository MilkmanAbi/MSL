#!/bin/bash
# Pushes Assets/ out to every place the build reads artwork from.
#
# See Assets/README.md for why these are copies and not symlinks. Run this
# after changing anything in Assets/; `AssetParityTests` is what notices if
# you don't.
set -euo pipefail

cd "$(dirname "$0")/.."

for file in Abi_Logo-Dark.png Abi_Logo-Light.png App_Logo.png License.md Mascot.png; do
    cp "Assets/$file" "Sources/MSLApp/Resources/$file"
    echo "  -> Sources/MSLApp/Resources/$file"
done

# MSLCore needs the melon of its own: LinuxAppBundle falls back to it when a
# Linux app ships no icon, and that runs from the CLI too.
mkdir -p Sources/MSLCore/Resources
cp "Assets/App_Logo.png" "Sources/MSLCore/Resources/App_Logo.png"
echo "  -> Sources/MSLCore/Resources/App_Logo.png"

./Scripts/make-icon.sh --force
