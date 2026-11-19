.PHONY: project build run run-logging universal size clean

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

# Size of the built app and its biggest parts.
size:
	@du -sh build/Build/Products/Release/Ring.app
	@du -sh build/Build/Products/Release/Ring.app/Contents/Frameworks/* | sort -rh | head -8
	@du -sh build/Build/Products/Release/Ring.app/Contents/MacOS/Ring build/Build/Products/Release/Ring.app/Contents/Resources

clean:
	rm -rf build Ring.xcodeproj
