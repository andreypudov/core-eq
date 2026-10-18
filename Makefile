APP        := CoreEQ
CONFIG     := Release
APP_BUNDLE := build/$(CONFIG)/$(APP).app
DIST_DIR   := dist

# Extra build settings for xcodebuild, e.g. `make build XCODE_FLAGS=ARCHS=arm64`
# — which is what the CodeQL job does, since extraction is source-level and the
# second architecture only doubles the traced compile. Empty by default, so
# `release` is universal unless someone overrides this deliberately.
XCODE_FLAGS ?=

# A code-signing identity to re-sign the app with, e.g.
# `make install SIGN_IDENTITY="CoreEQ Release"`. Empty by default, which keeps
# Xcode's ad-hoc signature. The difference is the System Audio Recording
# permission: macOS records an ad-hoc grant against that exact binary, so every
# rebuild is a stranger and is asked again, while a grant made to a certificate
# covers every build signed with it. Releases are signed this way from CI.
SIGN_IDENTITY ?=

# Use the full Xcode toolchain even when xcode-select points at the
# Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

.PHONY: build sign test audio-test format lint strings install release icons screenshot clean

build:
	xcodebuild -project $(APP).xcodeproj -target $(APP) -configuration $(CONFIG) $(XCODE_FLAGS) build

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

# Merges every string the compiler extracted into the String Catalog, the way
# Xcode does on build — xcodebuild extracts them but leaves the catalog alone.
# Strings no longer in the code are marked stale rather than dropped. One
# architecture's extraction is enough: both see the same source.
STRINGSDATA_DIR := build/$(APP).build/$(CONFIG)/$(APP).build/Objects-normal/arm64

strings: build
	xcrun xcstringstool sync $(APP)/Resources/Localizable.xcstrings \
		--stringsdata $$(find $(STRINGSDATA_DIR) -name '*.stringsdata')

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

# Re-signs the whole bundle with SIGN_IDENTITY, then refuses to continue if the
# result would still be pinned to this one binary. The identifier is passed
# explicitly: without it codesign can derive one that changes between builds,
# and a permission granted to one identifier does not cover another. No
# timestamp, because a self-signed certificate has no timestamp authority to
# vouch for it. Nothing is nested inside the app, so one signature covers it.
sign: build
ifneq ($(strip $(SIGN_IDENTITY)),)
	@bundle_id=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" $(APP_BUNDLE)/Contents/Info.plist); \
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier "$$bundle_id" --timestamp=none $(APP_BUNDLE)
	codesign --verify --strict $(APP_BUNDLE)
	@requirement=$$(codesign -d -r - $(APP_BUNDLE) 2>&1 | grep '^designated'); \
	echo "$$requirement"; \
	case "$$requirement" in \
	  *"certificate "*) ;; \
	  *) echo "error: the signature still names this exact build, not a certificate"; exit 1 ;; \
	esac
endif

install: sign
	rm -rf /Applications/$(APP).app
	ditto $(APP_BUNDLE) /Applications/$(APP).app
	@echo "Installed /Applications/$(APP).app"

release: sign
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

# The README screenshot of the build, at a fixed window size, saved as
# design/screenshots/core-eq-<version>.png. Details in Tools/screenshot.sh.
# Signed with the CoreEQ Release certificate when the keychain has it and no
# other identity was given, so the audio permission is asked for once rather
# than on every build.
SCREENSHOT_IDENTITY = $(or $(SIGN_IDENTITY),$(shell security find-identity -p codesigning 2>/dev/null | grep -q '"CoreEQ Release"' && echo "CoreEQ Release"))
screenshot:
	@$(MAKE) sign SIGN_IDENTITY="$(SCREENSHOT_IDENTITY)"
	@Tools/screenshot.sh $(APP_BUNDLE)

clean:
	rm -rf build $(DIST_DIR)
