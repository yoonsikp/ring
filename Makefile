.PHONY: project build run run-logging clean

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

clean:
	rm -rf build Ring.xcodeproj
