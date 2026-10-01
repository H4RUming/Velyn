#!/bin/zsh
# Build an unsigned device IPA for users to sign with their own Apple identity.
set -euo pipefail
cd "${0:A:h:h}"
release_version="${1:-1.0.0}"
if [[ ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 'Usage: ./Scripts/package-release.sh MAJOR.MINOR.PATCH'
  exit 1
fi
release_dir="$PWD/.work/releases/v$release_version"
if [[ -e "$release_dir" ]]; then
  print -u2 "Output already exists: $release_dir. Use a fresh version or preserve and move the previous output."
  exit 1
fi
mkdir -p "$release_dir/Payload"
print "Building unsigned iPhone archive; log: $release_dir/build.log"
xcodebuild -project Velyn.xcodeproj -scheme Velyn -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$release_dir/DerivedData" \
  -archivePath "$release_dir/Velyn.xcarchive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= PRODUCT_BUNDLE_IDENTIFIER=com.h4ruming.velyn \
  MARKETING_VERSION="$release_version" archive > "$release_dir/build.log" 2>&1

ditto "$release_dir/Velyn.xcarchive/Products/Applications/Velyn.app" "$release_dir/Payload/Velyn.app"
release_app="$release_dir/Payload/Velyn.app"
cp LICENSE "$release_app/Velyn-LICENSE.txt"
# Never publish a personal provisioning profile or signing identity.
if [[ -e "$release_app/embedded.mobileprovision" || -e "$release_app/_CodeSignature" ]]; then
  print -u2 'Unexpected signing material in unsigned build; packaging stopped.'
  exit 1
fi
if codesign --verify "$release_app" > /dev/null 2>&1; then
  print -u2 'Unexpected valid app signature; packaging stopped.'
  exit 1
fi
for release_model in aotgan DepthAnythingV2SmallF16 VelynGainMap VelynGainMap1024; do
  [[ -d "$release_app/$release_model.mlmodelc" ]]
done
for release_language in en ko; do
  [[ -f "$release_app/$release_language.lproj/Localizable.strings" ]]
done
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$release_app/Info.plist")" == "$release_version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$release_app/Info.plist")" == com.h4ruming.velyn ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print MinimumOSVersion' "$release_app/Info.plist")" == 27.0 ]]
(
  cd "$release_dir"
  COPYFILE_DISABLE=1 /usr/bin/zip -q -r "Velyn-$release_version-unsigned.ipa" Payload
  shasum -a 256 "Velyn-$release_version-unsigned.ipa" > SHA256SUMS.txt
)
print "Created $release_dir/Velyn-$release_version-unsigned.ipa"
