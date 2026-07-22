APP        := CoreEQ
CONFIG     := Release
APP_BUNDLE := build/$(CONFIG)/$(APP).app
DIST_DIR   := dist

# Use the full Xcode toolchain even when xcode-select points at the
# Command Line Tools.
ifneq (,$(findstring CommandLineTools,$(shell xcode-select -p)))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif

.PHONY: build install release clean

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

clean:
	rm -rf build $(DIST_DIR)
