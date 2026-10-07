#!/bin/zsh
# Typechecks the iPhone app (iOS/Sources + the Mac files it shares) against an iOS build of MailCore.
# Needs no XcodeGen or Xcode project; catches breakage in shared code such as AppModel.swift.
set -euo pipefail
cd "${0:A:h}/.."

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
scratch=.build/ios-typecheck
swift build --target MailCore --scratch-path "$scratch" --triple arm64-apple-ios26.0 --sdk "$sdk"
module=$(find "$scratch" -maxdepth 4 -name MailCore.swiftmodule | head -1)

# Shared files: keep in sync with the "Shared" group in iOS/project.yml.
shared=(AppModel Theme Notifier ThreadWebView RelativeDate)
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios26.0 -sdk "$sdk" -swift-version 6 \
    -I "${module:h}" iOS/Sources/*.swift Sources/Mak8rMail/${^shared}.swift
echo "iOS typecheck OK"
