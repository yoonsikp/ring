.PHONY: project build run run-logging universal size sdk small clean

project:
	xcodegen generate

build: project
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'platform=macOS' build

run: build
	open build/Build/Products/Release/Ring.app

# Same, with detailed liblinphone logs written to ~/Library/Logs/Ring
run-logging: build
	open build/Build/Products/Release/Ring.app --args --logging

# Both Intel and Apple Silicon (about twice the size).
universal: project
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'generic/platform=macOS' \
		ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

# Minimal SDK built from source (audio only, this Mac's architecture). Slow the first time.
sdk:
	scripts/build-sdk.sh

# Build and run Ring against the minimal SDK from `make sdk` instead of the prebuilt one.
small:
	sed -e 's|    url: https://gitlab.linphone.org/BC/public/linphone-sdk-swift-macos.git|    path: build/linphone-sdk-min/linphone-sdk-swift-macos|' \
	    -e '/    exactVersion: 5.5.41/d' project.yml > project-small.yml
	xcodegen generate --spec project-small.yml
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'platform=macOS' build
	open build/Build/Products/Release/Ring.app

# Size of the built app and its biggest parts.
size:
	@du -sh build/Build/Products/Release/Ring.app
	@du -sh build/Build/Products/Release/Ring.app/Contents/Frameworks/* | sort -rh | head -8
	@du -sh build/Build/Products/Release/Ring.app/Contents/MacOS/Ring build/Build/Products/Release/Ring.app/Contents/Resources

# Keeps the (slow to build) minimal SDK; use `rm -rf build` to remove everything.
clean:
	rm -rf build/Build build/Logs build/ModuleCache.noindex build/SourcePackages Ring.xcodeproj project-small.yml
