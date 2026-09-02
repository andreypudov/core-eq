APP        := CoreEQ
CONFIG     := Release
APP_BUNDLE := build/$(CONFIG)/$(APP).app
DIST_DIR   := dist

# Use the full Xcode toolchain even when xcode-select points at the
# Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

.PHONY: build test audio-test format lint install release icons clean

build:
	xcodebuild -project $(APP).xcodeproj -target $(APP) -configuration $(CONFIG) build

# Unit tests for the pure logic: filter math, profiles, and the analyzer ring
# buffer. The bundle has no test host, so nothing launches the app or touches
# audio hardware — it runs anywhere, including CI.
# Apple's formatter, bundled with the toolchain — no install, no dependency.
# Configuration is in .swift-format.
format:
	xcrun swift-format format --in-place --recursive --configuration .swift-format CoreEQ CoreEQTests

# The same rules, reported rather than applied. Fails on any finding, so CI can
# gate on it.
lint:
	xcrun swift-format lint --strict --recursive --configuration .swift-format CoreEQ CoreEQTests

test:
	xcodebuild test -project $(APP).xcodeproj -scheme $(APP) -destination 'platform=macOS'

# End-to-end check on real hardware: plays a known signal through the built app
# and measures what actually reaches the device. Silent — it captures through
# BlackHole rather than speakers — and it puts the audio settings back
# afterwards, including after a failure.
#
# This is the counterpart to `test`, not a replacement. Everything that has
# gone seriously wrong in this app went wrong at a boundary the unit tests
# cannot reach: Core Audio reporting success for a device that plays nothing, a
# tap created without permission, a channel map pointing somewhere else. Those
# are only visible in what comes out.
#
# Requires BlackHole (brew install blackhole-16ch) and takes about a minute,
# most of it waiting for the idle timer.
audio-test: build
	@mkdir -p build
	@xcrun swiftc -O -parse-as-library -o build/audio-test Tools/AudioTest.swift
	@./build/audio-test

install: build
	rm -rf /Applications/$(APP).app
	ditto $(APP_BUNDLE) /Applications/$(APP).app
	@echo "Installed /Applications/$(APP).app"

release: build
	mkdir -p $(DIST_DIR)
	@version=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $(APP_BUNDLE)/Contents/Info.plist); \
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST_DIR)/$(APP)-$$version.zip; \
	echo "Created $(DIST_DIR)/$(APP)-$$version.zip"

# Regenerate the app icon and menu bar template from the SVG sources in
# design/. Requires ImageMagick (brew install imagemagick).
icons:
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	magick -background none -density 384 design/logo.svg -resize 1024x1024 build/logo_1024.png
	for s in 16 32 128 256 512; do \
	  magick build/logo_1024.png -resize $${s}x$${s} build/AppIcon.iconset/icon_$${s}x$${s}.png; \
	  magick build/logo_1024.png -resize $$((s*2))x$$((s*2)) build/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(APP)/Resources/AppIcon.icns
	for v in "" -slash; do \
	  name=$$(printf '%s' "$$v" | sed 's/-slash/Slash/'); \
	  magick -background none -density 96 design/menubar$$v.svg -resize x18 \
	    $(APP)/Resources/MenuBarIcon$${name}Template.png; \
	  magick -background none -density 192 design/menubar$$v.svg -resize x36 \
	    $(APP)/Resources/MenuBarIcon$${name}Template@2x.png; \
	done
	@echo "Regenerated $(APP)/Resources/AppIcon.icns and $(APP)/Resources/MenuBarIconTemplate*.png"

clean:
	rm -rf build $(DIST_DIR)
