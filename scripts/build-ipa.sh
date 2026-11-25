#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ "$(uname -s)" != Darwin ]]; then
  echo '生成 iOS IPA 需要 macOS 和带有 iOS SDK 的 Xcode 27。' >&2
  exit 1
fi

xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

root="$PWD"
mkdir -p "$root/.build" "$root/Frameworks"
staging="$(mktemp -d "$root/.build/package.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT

download() {
  local repo="$1" version="$2" name="$3" checksum="$4" archive="$staging/$3"
  if [[ -n "${GH_TOKEN:-}" ]] && command -v gh >/dev/null; then
    gh release download "$version" --repo "$repo" --pattern "$name" --output "$archive"
  else
    curl --fail --location --silent --show-error --retry 3 \
      --output "$archive" "https://github.com/$repo/releases/download/$version/$name"
  fi
  printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
}

download jkcoxson/idevice v0.1.68 idevice-xcframework-v0.1.68.zip \
  c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7
unzip -q "$staging/idevice-xcframework-v0.1.68.zip" -d "$staging/idevice"
ditto "$staging/idevice/swift/IDevice.xcframework" "$root/Frameworks/IDevice.xcframework"

download yonaskolb/XcodeGen 2.46.0 xcodegen.zip \
  4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
unzip -q "$staging/xcodegen.zip" -d "$staging"
"$staging/xcodegen/bin/xcodegen" generate --spec project.yml

xcodebuild -project LocationBench.xcodeproj -scheme LocationBench -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$root/.build/xcode" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build

app="$root/.build/xcode/Build/Products/Release-iphoneos/LocationBench.app"
plutil -lint "$app/Info.plist"
xcrun lipo -verify_arch arm64 "$app/LocationBench"
mkdir -p "$staging/Payload"
ditto "$app" "$staging/Payload/LocationBench.app"
ditto -c -k --keepParent "$staging/Payload" "$staging/LocationBench.ipa"
mkdir -p "$root/build"
mv -f "$staging/LocationBench.ipa" "$root/build/LocationBench.ipa"
printf 'IPA 已生成：%s\n' "$root/build/LocationBench.ipa"
