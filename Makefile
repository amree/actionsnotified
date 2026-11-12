.PHONY: build run clean install release publish

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
	@codesign --force --sign - $(APP)
	@echo "==> Built $(APP)"

run: build
	open $(APP)

clean:
	rm -rf $(APP) ActionsNotified-*.zip

install: build
	@rm -rf /Applications/$(APP)
	@cp -R $(APP) /Applications/$(APP)
	@echo "==> Installed to /Applications/$(APP)"

# --- Direct-download release (Developer ID + notarization) ---------------
# Signing: a "Developer ID Application" certificate in the login keychain
# (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application).
# Notarizing: an App Store Connect API key. Set ASC_KEY_ID and ASC_ISSUER in the
# environment or in an untracked local.mk; the key file is read from
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
-include local.mk
VERSION    = $(shell /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ZIP        = ActionsNotified-$(VERSION).zip
SIGN_ID   ?= Developer ID Application

release: build ## sign with Developer ID, notarize, staple, zip
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	rm -f $(ZIP) && ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --wait \
	  --key $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8 \
	  --key-id $(ASC_KEY_ID) --issuer $(ASC_ISSUER)
	xcrun stapler staple $(APP)
	rm -f $(ZIP) && ditto -c -k --keepParent $(APP) $(ZIP)
	spctl --assess --type execute --verbose=2 $(APP)
	@echo "==> $(ZIP) is ready"

publish: release ## upload the zip as a GitHub release (v$(VERSION))
	gh release create v$(VERSION) $(ZIP) --title "ActionsNotified $(VERSION)" --generate-notes
