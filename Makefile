.PHONY: project build run run-logging native size sdk sdk-native small clean

project:
	xcodegen generate

# Universal app: runs on Intel and Apple Silicon Macs.
build: project
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'generic/platform=macOS' build

run: build
	open build/Build/Products/Release/Ring.app

# Same, with detailed liblinphone logs written to ~/Library/Logs/Ring
run-logging: build
	open build/Build/Products/Release/Ring.app --args --logging

# This Mac's processor only (about half the size; won't run on the other kind of Mac).
native: project
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'platform=macOS' \
		ARCHS='$$(NATIVE_ARCH_ACTUAL)' ONLY_ACTIVE_ARCH=YES build

# Minimal SDK built from source (audio only, universal). Slow the first time.
sdk:
	scripts/build-sdk.sh universal

# Same, for this Mac's processor only.
sdk-native:
	scripts/build-sdk.sh native

# Build and run Ring against the minimal SDK from `make sdk` instead of the prebuilt one.
small:
	sed -e 's|    url: https://gitlab.linphone.org/BC/public/linphone-sdk-swift-macos.git|    path: build/linphone-sdk-min/linphone-sdk-swift-macos|' \
	    -e '/    exactVersion: 5.5.41/d' project.yml > project-small.yml
	xcodegen generate --spec project-small.yml
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'generic/platform=macOS' build
	open build/Build/Products/Release/Ring.app

# Size of the built app and its biggest parts.
size:
	@du -sh build/Build/Products/Release/Ring.app
	@du -sh build/Build/Products/Release/Ring.app/Contents/Frameworks/* | sort -rh | head -8
	@du -sh build/Build/Products/Release/Ring.app/Contents/MacOS/Ring build/Build/Products/Release/Ring.app/Contents/Resources

# Keeps the (slow to build) minimal SDK; use `rm -rf build` to remove everything.
clean:
	rm -rf build/Build build/Logs build/ModuleCache.noindex build/SourcePackages Ring.xcodeproj project-small.yml
