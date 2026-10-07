APP_NAME := Mak8r Mail
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
SECRETS := Config/Secrets.xcconfig
# Build number = commit count, so About shows which build is running (fork: seisemail).
BUILD := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
CLIENT_ID := $(shell [ -f $(SECRETS) ] && sed -n 's/^GOOGLE_CLIENT_ID *= *//p' $(SECRETS))
CLIENT_SECRET := $(shell [ -f $(SECRETS) ] && sed -n 's/^GOOGLE_CLIENT_SECRET *= *//p' $(SECRETS))
# A stable identity keeps the Keychain sign-in valid across rebuilds; ad-hoc signatures change every build.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)

.PHONY: test app run install clean icon ios screenshots daemon daemon-install daemon-uninstall daemon-restart daemon-status daemon-logs daemon-login

test:
	swift test

app:
	swift build -c release --product Mak8rMail
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$$(swift build -c release --show-bin-path)/Mak8rMail" "$(APP)/Contents/MacOS/Mak8rMail"
	cp Resources/Icon/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	mkdir -p "$(APP)/Contents/Resources/InboxZero"
	cp Resources/InboxZero/* "$(APP)/Contents/Resources/InboxZero/"
	sed -e 's|__BUILD__|$(BUILD)|' -e 's|__CLIENT_ID__|$(CLIENT_ID)|' -e 's|__CLIENT_SECRET__|$(CLIENT_SECRET)|' \
		Resources/Info.plist.template > "$(APP)/Contents/Info.plist"
	plutil -lint "$(APP)/Contents/Info.plist"
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Allekirjoitetaan: $(SIGN_IDENTITY)"; \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" "$(APP)"; \
	else \
		echo "Varoitus: ei Apple Development -varmennetta, allekirjoitetaan ad hoc (kirjautuminen katoaa joka käännöksessä)"; \
		codesign --force --sign - "$(APP)"; \
	fi

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@echo "Asennettu: /Applications/$(APP_NAME).app"

# README:n kuvat oikeasta sovelluksesta keksityllä esittelytilillä (DemoGmail): omat tiedostot väliaikaiskansiossa,
# oma bundle-tunniste (ei koske oikeisiin asetuksiin, tiliin eikä Keychainiin). Ikkuna näkyy noin 1,5 min.
SHOTS := $(BUILD_DIR)/shots/Mak8r Mail Shots.app
screenshots: app
	rm -rf "$(BUILD_DIR)/shots" && mkdir -p "$(BUILD_DIR)/shots/data" docs/images
	cp -R "$(APP)" "$(SHOTS)"
	plutil -replace CFBundleIdentifier -string fi.mak8r.mail.screenshots "$(SHOTS)/Contents/Info.plist"
	codesign --force --sign - "$(SHOTS)"
	MAK8R_DATA_DIR="$(CURDIR)/$(BUILD_DIR)/shots/data" "$(SHOTS)/Contents/MacOS/Mak8rMail" -screenshots "$(CURDIR)/docs/images"
	rm -rf "$(BUILD_DIR)/shots"

# iPhone-sovellus: luo Xcode-projektin (vaatii `brew install xcodegen`) ja avaa sen.
ios:
	cd iOS && xcodegen generate
	open iOS/Mak8rMail.xcodeproj

icon:
	rm -rf build/AppIcon.iconset
	swift Resources/Icon/AppIcon.swift build/AppIcon.iconset
	iconutil -c icns build/AppIcon.iconset -o Resources/Icon/AppIcon.icns
	cp build/AppIcon.iconset/icon_512x512@2x.png Resources/Icon/AppIcon-1024.png

clean:
	rm -rf $(BUILD_DIR) .build

# Mac mini -daemon (docs/design/phase2-daemon.md §13–§14). Aja sandboxin ulkopuolella.
DAEMON_LABEL := fi.seise.mail.daemon
SUPPORT_DIR  := $(HOME)/Library/Application Support/Mak8rMail
DAEMON_DIR   := $(SUPPORT_DIR)/daemon
DAEMON_BIN   := $(SUPPORT_DIR)/bin/mak8r-daemon
DAEMON_LINK  ?= $(HOME)/.local/bin/mak8r-daemon
DAEMON_PLIST := $(HOME)/Library/LaunchAgents/$(DAEMON_LABEL).plist
DAEMON_LOGS  := $(HOME)/Library/Logs/Mak8rMail
GUI_DOMAIN   := gui/$(shell id -u)

daemon:
	mkdir -p $(BUILD_DIR)/daemon
	sed -e 's|__BUILD__|$(BUILD)|' -e 's|__CLIENT_ID__|$(CLIENT_ID)|' -e 's|__CLIENT_SECRET__|$(CLIENT_SECRET)|' \
		Resources/Daemon/daemon-Info.plist.template > $(BUILD_DIR)/daemon/Info.plist
	plutil -lint $(BUILD_DIR)/daemon/Info.plist
	# The embedded plist is not a tracked input: remove the binary to force a relink.
	rm -f "$$(swift build -c release --show-bin-path)/mak8r-daemon"
	swift build -c release --product mak8r-daemon \
		-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(CURDIR)/$(BUILD_DIR)/daemon/Info.plist
	cp "$$(swift build -c release --show-bin-path)/mak8r-daemon" $(BUILD_DIR)/daemon/mak8r-daemon
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		codesign --force --options runtime --identifier $(DAEMON_LABEL) --sign "$(SIGN_IDENTITY)" $(BUILD_DIR)/daemon/mak8r-daemon; \
	else \
		codesign --force --identifier $(DAEMON_LABEL) --sign - $(BUILD_DIR)/daemon/mak8r-daemon; \
	fi

daemon-install: daemon
	install -d -m 0700 "$(DAEMON_DIR)" "$(DAEMON_DIR)/tokens" "$(DAEMON_DIR)/requests" "$(DAEMON_LOGS)"
	install -d -m 0755 "$(SUPPORT_DIR)/bin" "$(dir $(DAEMON_PLIST))"
	cp $(BUILD_DIR)/daemon/mak8r-daemon "$(DAEMON_BIN).new" && mv -f "$(DAEMON_BIN).new" "$(DAEMON_BIN)"
	@if [ -d "$(dir $(DAEMON_LINK))" ]; then ln -sf "$(DAEMON_BIN)" "$(DAEMON_LINK)"; fi
	sed -e 's|__BIN__|$(DAEMON_BIN)|' -e 's|__DAEMON_DIR__|$(DAEMON_DIR)|' -e 's|__LOGS__|$(DAEMON_LOGS)|' \
		Resources/Daemon/$(DAEMON_LABEL).plist.template > $(BUILD_DIR)/daemon/$(DAEMON_LABEL).plist
	plutil -lint $(BUILD_DIR)/daemon/$(DAEMON_LABEL).plist
	"$(DAEMON_BIN)" init
	-launchctl bootout $(GUI_DOMAIN)/$(DAEMON_LABEL) 2>/dev/null
	@for i in $$(seq 1 25); do launchctl print $(GUI_DOMAIN)/$(DAEMON_LABEL) >/dev/null 2>&1 || break; sleep 1; done
	install -m 0644 $(BUILD_DIR)/daemon/$(DAEMON_LABEL).plist "$(DAEMON_PLIST)"
	launchctl enable $(GUI_DOMAIN)/$(DAEMON_LABEL)
	launchctl bootstrap $(GUI_DOMAIN) "$(DAEMON_PLIST)"
	@"$(DAEMON_BIN)" status || true

daemon-uninstall:
	-launchctl bootout $(GUI_DOMAIN)/$(DAEMON_LABEL)
	rm -f "$(DAEMON_PLIST)" "$(DAEMON_BIN)"
	@if [ -L "$(DAEMON_LINK)" ]; then rm -f "$(DAEMON_LINK)"; fi
	@echo "Daemon poistettu ajosta. Tiedot jäivät (poista vain harkiten):"
	@echo "  $(DAEMON_DIR)  (tokenit ja tila)"
	@echo "  $(SUPPORT_DIR)/daemon.json, $(SUPPORT_DIR)/rules.json"
	@echo "  $(DAEMON_LOGS)"

daemon-restart: ; launchctl kickstart -k $(GUI_DOMAIN)/$(DAEMON_LABEL)
daemon-status:  ; @"$(DAEMON_BIN)" status
daemon-logs:    ; tail -n 100 -F "$(DAEMON_LOGS)/daemon.log"
daemon-login:   ; "$(DAEMON_BIN)" login $(EMAIL)
