#!/bin/sh
# Builds Agent Privilege Manager, the Touch ID helper of the omp command guard, as an app
# bundle so the system dialog shows its name. It is installed into ~/.omp/agent/guard,
# which omp restricts for agents (tools.restrictedFolders), so an agent cannot swap the
# binary without an explicit approval.
set -eu

src="$(cd "$(dirname "$0")" && pwd)/agent-privilege-manager.swift"
app="$HOME/.omp/agent/guard/bin/Agent Privilege Manager.app"

mkdir -p "$app/Contents/MacOS"
swiftc -O "$src" -o "$app/Contents/MacOS/agent-privilege-manager"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>cloud.gistrec.agent-privilege-manager</string>
	<key>CFBundleName</key>
	<string>Agent Privilege Manager</string>
	<key>CFBundleDisplayName</key>
	<string>Agent Privilege Manager</string>
	<key>CFBundleExecutable</key>
	<string>agent-privilege-manager</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app"
echo "$app"
