.PHONY: project build run clean

project:
	xcodegen generate

build: project
	xcodebuild -project Ring.xcodeproj -scheme Ring -configuration Release \
		-derivedDataPath build -destination 'platform=macOS' build

run: build
	open build/Build/Products/Release/Ring.app

clean:
	rm -rf build Ring.xcodeproj
