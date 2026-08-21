.PHONY: generate typecheck smoke-mailbox smoke-server validate build open clean server server-fake server-health

generate:
	cd ios && xcodegen generate

typecheck:
	xcrun swiftc -typecheck \
		-swift-version 6 \
		-strict-concurrency=complete \
		-target arm64-apple-ios17.0 \
		-sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" \
		ios/App/Sources/*.swift \
		ios/Shared/Sources/*.swift \
		../../HexCore/Sources/HexCore/Models/WordRemoval.swift \
		../../HexCore/Sources/HexCore/Models/WordRemapping.swift \
		../../HexCore/Sources/HexCore/Models/TranscriptFormatting.swift
	xcrun swiftc -typecheck \
		-swift-version 6 \
		-strict-concurrency=complete \
		-target arm64-apple-ios17.0 \
		-sdk "$$(xcrun --sdk iphoneos --show-sdk-path)" \
		ios/Keyboard/Sources/*.swift \
		ios/Shared/Sources/*.swift

smoke-mailbox:
	mkdir -p ios/.derivedData
	xcrun swiftc \
		-swift-version 6 \
		-strict-concurrency=complete \
		ios/Shared/Sources/PrototypeMailbox.swift \
		ios/Shared/Sources/PrototypeWarmSession.swift \
		ios/Shared/Smoke/PrototypeMailboxSmoke.swift \
		-o ios/.derivedData/prototype-mailbox-smoke
	ios/.derivedData/prototype-mailbox-smoke

smoke-server:
	npm --prefix server run validate
	bash server/smoke.sh

validate: generate typecheck smoke-mailbox smoke-server
	plutil -lint \
		ios/App/Info.plist \
		ios/Keyboard/Info.plist \
		ios/App/HexKeyboardTracer.entitlements \
		ios/Keyboard/HexKeyboardExtension.entitlements
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' ios/App/Info.plist)" = hextracer
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :UIBackgroundModes:0' ios/App/Info.plist)" = audio
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleDisplayName' ios/Keyboard/Info.plist)" = 'Hex Prototype'
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :NSExtension:NSExtensionAttributes:RequestsOpenAccess' ios/Keyboard/Info.plist)" = true
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :com.apple.security.application-groups:0' ios/App/HexKeyboardTracer.entitlements)" = group.com.nmarch213.HexKeyboardTracer
	test "$$('/usr/libexec/PlistBuddy' -c 'Print :com.apple.security.application-groups:0' ios/Keyboard/HexKeyboardExtension.entitlements)" = group.com.nmarch213.HexKeyboardTracer

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

open: generate
	open ios/HexKeyboardTracer.xcodeproj

clean:
	xcodebuild -project ios/HexKeyboardTracer.xcodeproj -scheme HexKeyboardTracer clean

server:
	docker compose --env-file server/.env -f server/compose.yaml up

server-fake:
	npm --prefix server run build
	HEX_LISTEN_HOST=127.0.0.1 HEX_PROXY_TOKEN=prototype HEX_FAKE_TRANSCRIPT='Hello from the Ronin tracer.' node server/dist/main.js

server-health:
	curl --fail --silent --show-error \
		-H 'Authorization: Bearer prototype' \
		http://127.0.0.1:8787/health
