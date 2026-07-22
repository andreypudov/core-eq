APP        := CoreEQ
CONFIG     := Release
APP_BUNDLE := build/$(CONFIG)/$(APP).app
DIST_DIR   := dist

# Use the full Xcode toolchain even when xcode-select points at the
# Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

.PHONY: build install release icons clean

build:
	xcodebuild -project $(APP).xcodeproj -target $(APP) -configuration $(CONFIG) build

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
# Design/. Requires ImageMagick (brew install imagemagick).
icons:
	rm -rf build/AppIcon.iconset
	mkdir -p build/AppIcon.iconset
	magick -background none -density 384 Design/logo.svg -resize 1024x1024 build/logo_1024.png
	for s in 16 32 128 256 512; do \
	  magick build/logo_1024.png -resize $${s}x$${s} build/AppIcon.iconset/icon_$${s}x$${s}.png; \
	  magick build/logo_1024.png -resize $$((s*2))x$$((s*2)) build/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns build/AppIcon.iconset -o $(APP)/AppIcon.icns
	magick -background none -density 96 Design/menubar.svg -resize x18 $(APP)/MenuBarIconTemplate.png
	magick -background none -density 192 Design/menubar.svg -resize x36 $(APP)/MenuBarIconTemplate@2x.png
	@echo "Regenerated $(APP)/AppIcon.icns and $(APP)/MenuBarIconTemplate*.png"

clean:
	rm -rf build $(DIST_DIR)
