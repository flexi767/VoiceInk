# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build
LOCAL_SIGNING_IDENTITY := Apple Development: i@jlzov.com (SFRBKW6P78)
LOCAL_SIGNING_CERT_SHA1 := 158D75C090FD771527624707372E63CB8952B69A
LOCAL_DEVELOPMENT_TEAM := NKW2BHRJH2
LOCAL_APP_PATH := /Applications/VoiceInk.app

.PHONY: all clean whisper setup build local check healthcheck help dev run

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build, verify, install, and launch a persistently signed local app.
local: check setup
	@security find-identity -v -p codesigning | grep -q "$(LOCAL_SIGNING_CERT_SHA1)" || { \
		echo "Required signing certificate is unavailable: $(LOCAL_SIGNING_IDENTITY)"; \
		exit 1; \
	}
	@echo "Building VoiceInk with $(LOCAL_SIGNING_IDENTITY)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGNING_REQUIRED=YES \
		CODE_SIGNING_ALLOWED=YES \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		codesign --verify --deep --strict "$$APP_PATH"; \
		codesign -dvv "$$APP_PATH" 2>&1 | grep -q "Authority=$(LOCAL_SIGNING_IDENTITY)"; \
		codesign -dvv "$$APP_PATH" 2>&1 | grep -q "TeamIdentifier=$(LOCAL_DEVELOPMENT_TEAM)"; \
		echo "Installing VoiceInk.app in /Applications..."; \
		pkill -x VoiceInk >/dev/null 2>&1 || true; \
		rm -rf "$(LOCAL_APP_PATH)"; \
		ditto "$$APP_PATH" "$(LOCAL_APP_PATH)"; \
		xattr -cr "$(LOCAL_APP_PATH)"; \
		codesign --verify --deep --strict "$(LOCAL_APP_PATH)"; \
		/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "$$APP_PATH" >/dev/null 2>&1 || true; \
		rm -rf "$$APP_PATH"; \
		open "$(LOCAL_APP_PATH)"; \
		echo ""; \
		echo "Build complete, signature verified, and app launched: $(LOCAL_APP_PATH)"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$(LOCAL_APP_PATH)" ]; then \
		echo "Opening $(LOCAL_APP_PATH)..."; \
		open "$(LOCAL_APP_PATH)"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build, sign, install, and launch the local app"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
