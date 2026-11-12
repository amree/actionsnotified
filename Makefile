.PHONY: build run clean install

APP     = ActionsNotified.app
SOURCES = $(wildcard Sources/ActionsNotified/*.swift)

build: $(APP)

$(APP): $(SOURCES) Resources/Info.plist Resources/AppIcon.icns
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@echo "==> Compiling (Apple Silicon, target macOS 26)"
	@swiftc \
		-swift-version 5 \
		-target arm64-apple-macosx26.0 \
		-O \
		-framework SwiftUI \
		-framework AppKit \
		-framework UserNotifications \
		-o $(APP)/Contents/MacOS/ActionsNotified \
		$(SOURCES)
	@echo "==> Bundling Info.plist and icons"
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	@echo "==> Ad-hoc signing"
	@codesign --force --deep --sign - $(APP)
	@echo "==> Built $(APP)"

run: build
	open $(APP)

clean:
	rm -rf $(APP)

install:
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	@echo "==> Compiling (Apple Silicon, target macOS 26)"
	@swiftc \
		-swift-version 5 \
		-target arm64-apple-macosx26.0 \
		-O \
		-framework SwiftUI \
		-framework AppKit \
		-framework UserNotifications \
		-o $(APP)/Contents/MacOS/ActionsNotified \
		$(SOURCES)
	@echo "==> Bundling Info.plist and icons"
	@cp Resources/Info.plist $(APP)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	@echo "==> Ad-hoc signing"
	@codesign --force --deep --sign - $(APP)
	@rm -rf /Applications/$(APP)
	@cp -R $(APP) /Applications/$(APP)
	@echo "==> Installed to /Applications/$(APP)"
