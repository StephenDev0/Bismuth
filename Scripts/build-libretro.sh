#!/usr/bin/env bash
# Builds the Bismuth libretro core for every Apple platform.
#
#   Scripts/build-libretro.sh            # all targets
#   Scripts/build-libretro.sh ios        # just the iOS device framework
#
# Outputs (in dist/):
#   ios/bismuth.libretro.framework      iOS device framework
#   bismuth.libretro.xcframework        iOS device + simulator, for other iOS hosts
#   tvos/bismuth.libretro.framework     tvOS device framework (RetroArch tvOS)
#   macos/bismuth_libretro.dylib        RetroArch desktop core
#   bismuth_libretro.info               core info file
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="1.0.0"
MIN_IOS="16.0"
MIN_TVOS="16.0"

# iOS SDKs need a full Xcode, not just the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if xcode-select -p | grep -q CommandLineTools; then
        for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
            if [[ -d "$candidate" ]]; then export DEVELOPER_DIR="$candidate/Contents/Developer"; break; fi
        done
    fi
fi
export BISMUTH_FAST=1   # compile the emulation targets without dynamic exclusivity checks

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then targets=(macos ios ios-simulator tvos); fi

build() { # triple sdk build-path
    local triple="$1" sdk="$2" path="$3"
    echo "==> Building $triple" >&2
    local args=(-c release --product bismuth_libretro --build-path "$path")
    if [[ "$sdk" != "macosx" ]]; then
        args+=(--triple "$triple" --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)")
    fi
    (cd "$ROOT" && swift build "${args[@]}" >&2)
    find "$path" -name "libbismuth_libretro.dylib" -type f -not -path "*dSYM*" | head -1
}

make_framework() { # dylib output-dir platform-name min-os
    local dylib="$1" out="$2" platform="$3" minos="$4"
    local fw="$out/bismuth.libretro.framework"
    rm -rf "$fw"
    mkdir -p "$fw"
    cp "$dylib" "$fw/bismuth.libretro"
    install_name_tool -id "@rpath/bismuth.libretro.framework/bismuth.libretro" "$fw/bismuth.libretro" 2>/dev/null
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>bismuth.libretro</string>
	<key>CFBundleIdentifier</key>
	<string>bismuth.libretro</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>bismuth.libretro</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>$platform</string>
	</array>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>MinimumOSVersion</key>
	<string>$minos</string>
</dict>
</plist>
PLIST
    # Ad-hoc signature; Xcode re-signs embedded frameworks with the app's identity (CodeSignOnCopy).
    codesign --force --sign - "$fw" >/dev/null 2>&1 || true
    echo "$fw"
}

mkdir -p "$DIST"
cp "$ROOT/bismuth_libretro.info" "$DIST/bismuth_libretro.info"
ios_fw="" sim_fw=""
for target in "${targets[@]}"; do
    case "$target" in
        macos)
            dylib=$(build "arm64-apple-macosx13.0" macosx "$ROOT/.build/dist-macos")
            mkdir -p "$DIST/macos"
            cp "$dylib" "$DIST/macos/bismuth_libretro.dylib"
            install_name_tool -id "@rpath/bismuth_libretro.dylib" "$DIST/macos/bismuth_libretro.dylib" 2>/dev/null
            codesign --force --sign - "$DIST/macos/bismuth_libretro.dylib" >/dev/null 2>&1 || true
            echo "    $DIST/macos/bismuth_libretro.dylib"
            ;;
        ios)
            dylib=$(build "arm64-apple-ios$MIN_IOS" iphoneos "$ROOT/.build/dist-ios")
            ios_fw=$(make_framework "$dylib" "$DIST/ios" iPhoneOS "$MIN_IOS")
            echo "    $ios_fw"
            ;;
        ios-simulator)
            dylib=$(build "arm64-apple-ios$MIN_IOS-simulator" iphonesimulator "$ROOT/.build/dist-ios-sim")
            sim_fw=$(make_framework "$dylib" "$DIST/ios-simulator" iPhoneSimulator "$MIN_IOS")
            echo "    $sim_fw"
            ;;
        tvos)
            dylib=$(build "arm64-apple-tvos$MIN_TVOS" appletvos "$ROOT/.build/dist-tvos")
            tv_fw=$(make_framework "$dylib" "$DIST/tvos" AppleTVOS "$MIN_TVOS")
            echo "    $tv_fw"
            ;;
        *)
            echo "unknown target $target (use macos, ios, ios-simulator, tvos)" >&2; exit 2 ;;
    esac
done

if [[ -n "$ios_fw" && -n "$sim_fw" ]]; then
    rm -rf "$DIST/bismuth.libretro.xcframework"
    xcodebuild -create-xcframework -framework "$ios_fw" -framework "$sim_fw" \
        -output "$DIST/bismuth.libretro.xcframework" >/dev/null
    echo "    $DIST/bismuth.libretro.xcframework"
fi
echo "Done."
