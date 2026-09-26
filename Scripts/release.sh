#!/bin/zsh
# Archives, exports and uploads iOS + macOS builds. Bump CURRENT_PROJECT_VERSION in project.yml and run
# `xcodegen generate` first. Usage: Scripts/release.sh [iOS] [mac]  (default: both). Needs the Legitimate ASC API key config and the distribution/installer certs.

set -u
cd "${0:A:h}/.."
A="/Volumes/Crucial X8/DerivedData/readaloud-release"
DD="/Volumes/Crucial X8/DerivedData/readaloud-app"
source ~/.appstoreconnect/config-legitimate.sh
PLATFORMS=(${@:-iOS mac})
for P in $PLATFORMS; do
  if [[ $P == iOS ]]; then DEST='generic/platform=iOS'; else DEST='generic/platform=macOS'; fi
  rm -rf "$A/$P.xcarchive" "$A/export-${(L)P}"
  xcodebuild archive -project ReadAnythingAloud.xcodeproj -scheme ReadAnythingAloud -configuration Release -destination "$DEST" -archivePath "$A/$P.xcarchive" -derivedDataPath "$DD" -allowProvisioningUpdates 2>&1 | grep -E "error:|ARCHIVE" | tail -3
  xcodebuild -exportArchive -archivePath "$A/$P.xcarchive" -exportPath "$A/export-${(L)P}" -exportOptionsPlist "Scripts/export-${(L)P}.plist" 2>&1 | grep -E "error|EXPORT" | tail -3
done
for P in $PLATFORMS; do
  if [[ $P == iOS ]]; then
    echo "iOS embedded frameworks: $(ls "$A/iOS.xcarchive/Products/Applications/ReadAnythingAloud.app/Frameworks" 2>/dev/null)"
    FILE="$A/export-ios/ReadAnythingAloud.ipa"; TYPE=ios
  else
    echo "mac embedded frameworks: $(ls "$A/mac.xcarchive/Products/Applications/ReadAnythingAloud.app/Contents/Frameworks" 2>/dev/null)"
    FILE="$A/export-mac/ReadAnythingAloud.pkg"; TYPE=macos
  fi
  [[ -f $FILE ]] || { echo "$P: no package to upload"; continue; }
  xcrun altool --upload-app --file "$FILE" --type $TYPE --apiKey "$ASC_AUTH_KEY_ID" --apiIssuer "$ASC_AUTH_ISSUER_ID" 2>&1 \
    | grep -E "UUID|ERROR|error|WARN|No errors|SUCCEEDED" | cut -c1-300
done
