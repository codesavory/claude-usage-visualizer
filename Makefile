SCHEME  = ClaudeUsageVisualizer
DERIVED = build/DerivedData
BUILT   = $(DERIVED)/Build/Products/Release/ClaudeUsageVisualizer.app
DEST    = /Applications/ClaudeUsageVisualizer.app
LSREG   = /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

.PHONY: install build clean

# Build and install in one step — the only way to deploy the Release build.
install: build
	pkill -x ClaudeUsageVisualizer 2>/dev/null || true
	sleep 0.5
	rm -rf "$(DEST)"
	cp -R "$(BUILT)" "$(DEST)"
	"$(LSREG)" -u "$(BUILT)" 2>/dev/null || true
	"$(LSREG)" -f "$(DEST)"
	rm -rf "$(DERIVED)"
	open "$(DEST)"
	@echo "Installed: $(DEST)"

build:
	xcodebuild -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build

clean:
	rm -rf build
	rm -rf ~/Library/Developer/Xcode/DerivedData/ClaudeUsageVisualizer-*
