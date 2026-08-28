.PHONY: generate glide-lexicon typecheck test-ios smoke-capture-storage smoke-mailbox smoke-server validate build build-release build-device-release open clean server server-configure server-rotate server-device-enroll server-device-list server-device-rotate server-device-revoke server-backup server-restore server-restore-finalize server-restore-reauthorize server-restore-auth-reset server-restore-auth-complete server-storage-drill server-status server-logs server-stop server-fake server-health server-latency

generate:
	cd ios && xcodegen generate

glide-lexicon:
	./generate-glide-lexicon.sh

typecheck:
	xcrun swiftc -typecheck \
		-swift-version 6 \
		-strict-concurrency=complete \
		-target arm64-apple-ios18.0 \
		-sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" \
		ios/App/Sources/*.swift \
		ios/Shared/Sources/*.swift \
		../../HexCore/Sources/HexCore/Logging.swift \
		../../HexCore/Sources/HexCore/Models/WordRemoval.swift \
		../../HexCore/Sources/HexCore/Models/WordRemapping.swift \
		../../HexCore/Sources/HexCore/Models/TranscriptFormatting.swift
	xcrun swiftc -typecheck \
		-swift-version 6 \
		-strict-concurrency=complete \
		-target arm64-apple-ios18.0 \
		-sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" \
		ios/Keyboard/Sources/*.swift \
		ios/Shared/Sources/*.swift \
		../../HexCore/Sources/HexCore/Logging.swift

test-ios: generate
	compatible_devices="$$(xcrun simctl list devices available | awk '/^-- iOS / { compatible = ($$3 + 0 >= 18); next } compatible && /iPhone/')"; \
		device_id="$$(printf '%s\n' "$$compatible_devices" | sed -nE 's/^[[:space:]]+iPhone.*\(([0-9A-F-]{36})\) \(Booted\)[[:space:]]*$$/\1/p' | head -n 1)"; \
		if test -z "$$device_id"; then \
			device_id="$$(printf '%s\n' "$$compatible_devices" | sed -nE 's/^[[:space:]]+iPhone.*\(([0-9A-F-]{36})\) \((Booted|Shutdown)\)[[:space:]]*$$/\1/p' | tail -n 1)"; \
		fi; \
		test -n "$$device_id"; \
		xcodebuild test -quiet \
			-project ios/HexKeyboardTracer.xcodeproj \
			-scheme HexKeyboardTracer \
			-configuration Debug \
			-destination "platform=iOS Simulator,id=$$device_id" \
			-derivedDataPath ios/.testDerivedData \
			CODE_SIGNING_ALLOWED=NO

smoke-mailbox:
	mkdir -p ios/.derivedData
	xcrun swiftc \
		-swift-version 6 \
		-strict-concurrency=complete \
		ios/Shared/Sources/PrototypeMailbox.swift \
		ios/Shared/Sources/PrototypeWarmCaptureCommand.swift \
		ios/Shared/Sources/PrototypeWarmSession.swift \
		ios/Shared/Smoke/PrototypeMailboxSmoke.swift \
		-o ios/.derivedData/prototype-mailbox-smoke
	ios/.derivedData/prototype-mailbox-smoke

smoke-capture-storage:
	mkdir -p ios/.derivedData
	xcrun swiftc \
		-swift-version 6 \
		-strict-concurrency=complete \
		ios/App/Sources/CapturedAudioStorage.swift \
		ios/App/Smoke/CapturedAudioStorageSmoke.swift \
		-o ios/.derivedData/captured-audio-storage-smoke
	ios/.derivedData/captured-audio-storage-smoke

smoke-server:
	npm --prefix server run validate
	bash server/smoke.sh

validate: generate typecheck test-ios smoke-capture-storage smoke-mailbox smoke-server
	plutil -lint \
		ios/App/Info.plist \
		ios/Keyboard/Info.plist \
		ios/App/Resources/PrivacyInfo.xcprivacy \
		ios/Keyboard/Resources/PrivacyInfo.xcprivacy \
		ios/App/HexKeyboardTracer.entitlements \
		ios/Keyboard/HexKeyboardExtension.entitlements
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :UIBackgroundModes:0' ios/App/Info.plist)" = audio
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleDisplayName' ios/Keyboard/Info.plist)" = Hex
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleShortVersionString' ios/App/Info.plist)" = '$$(MARKETING_VERSION)'
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleVersion' ios/App/Info.plist)" = '$$(CURRENT_PROJECT_VERSION)'
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleShortVersionString' ios/Keyboard/Info.plist)" = '$$(MARKETING_VERSION)'
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleVersion' ios/Keyboard/Info.plist)" = '$$(CURRENT_PROJECT_VERSION)'
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :NSExtension:NSExtensionAttributes:RequestsOpenAccess' ios/Keyboard/Info.plist)" = true
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :com.apple.security.application-groups:0' ios/App/HexKeyboardTracer.entitlements)" = group.com.nmarch213.HexKeyboardTracer
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :com.apple.security.application-groups:0' ios/Keyboard/HexKeyboardExtension.entitlements)" = group.com.nmarch213.HexKeyboardTracer
	test "$$(awk '!/^#/ { count += 1 } END { print count }' ios/Keyboard/Resources/english-glide-frequency.txt)" = 20000
	cd ios/Keyboard/Resources && shasum -a 256 -c english-glide-frequency.txt.sha256
	test -s ios/Keyboard/Resources/GlideLexiconNotices/SymSpell-MIT.txt
	test -s ios/Keyboard/Resources/GlideLexiconNotices/SCOWL-v1-Copyright.txt
	test -s ios/Keyboard/Resources/GlideLexiconNotices/CC-BY-3.0.txt

build: generate
	xcodebuild \
		-project ios/HexKeyboardTracer.xcodeproj \
		-scheme HexKeyboardTracer \
		-configuration Debug \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath ios/.derivedData \
		CODE_SIGNING_ALLOWED=NO \
		build

build-release: generate
	xcodebuild \
		-project ios/HexKeyboardTracer.xcodeproj \
		-scheme HexKeyboardTracer \
		-configuration Release \
		-sdk iphonesimulator \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath ios/.releaseDerivedData \
		CODE_SIGNING_ALLOWED=NO \
		build

build-device-release: generate
	xcodebuild \
		-project ios/HexKeyboardTracer.xcodeproj \
		-scheme HexKeyboardTracer \
		-configuration Release \
		-sdk iphoneos \
		-destination 'generic/platform=iOS' \
		-derivedDataPath ios/.deviceDerivedData \
		CODE_SIGNING_ALLOWED=NO \
		build

open: generate
	open ios/HexKeyboardTracer.xcodeproj

clean:
	xcodebuild -project ios/HexKeyboardTracer.xcodeproj -scheme HexKeyboardTracer clean

server:
	bash server/deploy.sh

server-configure:
	bash server/configure-secret.sh

server-rotate:
	bash server/rotate-secret.sh

server-device-enroll:
	test -n "$(DEVICE_NAME)"
	test -n "$(DEVICE_PLATFORM)"
	test -n "$(CREDENTIAL_OUTPUT)"
	bash server/device-admin.sh enroll \
		"$(DEVICE_NAME)" "$(DEVICE_PLATFORM)" "$(CREDENTIAL_OUTPUT)"

server-device-list:
	bash server/device-admin.sh list

server-device-rotate:
	test -n "$(DEVICE_ID)"
	test -n "$(CREDENTIAL_OUTPUT)"
	bash server/device-admin.sh rotate "$(DEVICE_ID)" "$(CREDENTIAL_OUTPUT)"

server-device-revoke:
	test -n "$(DEVICE_ID)"
	bash server/device-admin.sh revoke "$(DEVICE_ID)"

server-backup:
	bash server/storage-backup.sh

server-restore:
	test -n "$(BACKUP)"
	bash server/storage-restore.sh "$(BACKUP)"

server-restore-finalize:
	test -n "$(RECOVERY_ID)"
	bash server/storage-finalize-recovery.sh "$(RECOVERY_ID)"

server-restore-reauthorize:
	test -n "$(DEVICE_NAME)"
	test -n "$(DEVICE_PLATFORM)"
	test -n "$(CREDENTIAL_OUTPUT)"
	bash server/reauthorize-after-restore.sh \
		"$(DEVICE_NAME)" "$(DEVICE_PLATFORM)" "$(CREDENTIAL_OUTPUT)"

server-restore-auth-reset:
	bash server/device-admin.sh restore-reset

server-restore-auth-complete:
	bash server/device-admin.sh restore-complete

server-storage-drill:
	npm --prefix server run build
	npm --prefix server run storage:drill
	bash server/storage-startup-guard-smoke.sh

server-status:
	docker compose --project-name server -f server/compose.yaml ps

server-logs:
	docker compose --project-name server -f server/compose.yaml logs --tail=200

server-stop:
	bash server/stop.sh

server-fake:
	npm --prefix server run build
	test -n "$$HEX_DEVICE_REGISTRY_DB_PATH"
	HEX_LISTEN_HOST=127.0.0.1 HEX_FAKE_TRANSCRIPT='Hello from the Ronin tracer.' npm --prefix server run start:fake

server-health:
	if test -f server/secrets/health-probe-token; then \
		node server/authenticated-health-check.mjs \
			server/secrets/health-probe-token 200; \
	else \
		node server/authenticated-health-check.mjs - 200; \
	fi

server-latency:
	node server/latency-report.mjs
