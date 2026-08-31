APP        := CoreEQ
CONFIG     := Release
APP_BUNDLE := build/$(CONFIG)/$(APP).app
DIST_DIR   := dist

# Use the full Xcode toolchain even when xcode-select points at the
# Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

.PHONY: build test format lint install release icons clean

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
