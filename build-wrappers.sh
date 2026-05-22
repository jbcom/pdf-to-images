#!/usr/bin/env bash
# Assembles the four Quick Action wrappers from the template + engine.
# Automator .workflow bundles are built here; .shortcut files are built
# separately via the shortcuts-playground skill and committed directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="$REPO_ROOT/wrappers/dispatcher.sh.tmpl"
ENGINE="$REPO_ROOT/pdf-to-images.swift"

build_workflow() {
  local format="$1" upper="$2"
  local wf="$REPO_ROOT/Convert PDF to $upper.workflow"
  local contents="$wf/Contents"
  rm -rf "$wf"
  mkdir -p "$contents"

  # Bundle the engine inside the workflow.
  cp "$ENGINE" "$contents/pdf-to-images.swift"

  # Render the dispatcher for this format.
  local dispatcher
  dispatcher="$(sed "s/{{FORMAT}}/$format/g" "$TMPL")"

  # Escape for embedding in the plist <string>.
  local esc
  esc="$(printf '%s' "$dispatcher" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"

  cat > "$contents/document.wflow" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key><string>523</string>
	<key>AMApplicationVersion</key><string>2.10</string>
	<key>AMDocumentVersion</key><string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Optional</key><true/>
					<key>Types</key>
					<array><string>com.apple.cocoa.path</string></array>
				</dict>
				<key>AMActionVersion</key><string>2.0.3</string>
				<key>AMProvides</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Types</key>
					<array><string>com.apple.cocoa.path</string></array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key><string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>$esc</string>
					<key>CheckedForUserDefaultShell</key><true/>
					<key>inputMethod</key><integer>1</integer>
					<key>shell</key><string>/bin/zsh</string>
					<key>source</key><string></string>
				</dict>
				<key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key><string>2.0.3</string>
				<key>Class Name</key><string>RunShellScriptAction</string>
				<key>InputUUID</key><string>00000000-0000-0000-0000-000000000001</string>
				<key>OutputUUID</key><string>00000000-0000-0000-0000-000000000002</string>
				<key>UUID</key><string>00000000-0000-0000-0000-000000000003</string>
			</dict>
		</dict>
	</array>
	<key>connectors</key><dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleID</key><string>com.apple.finder</string>
		<key>inputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.PDF</string>
		<key>outputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>presentationMode</key><integer>15</integer>
		<key>processesInput</key><false/>
		<key>serviceApplicationBundleID</key><string>com.apple.finder</string>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.PDF</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>serviceProcessesInput</key><false/>
		<key>systemImageName</key><string>NSActionTemplate</string>
		<key>useAutomaticInputType</key><false/>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
PLIST

  cat > "$contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Convert PDF to $upper</string></dict>
			<key>NSMessage</key><string>runWorkflowAsService</string>
			<key>NSRequiredContext</key>
			<dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
			<key>NSSendFileTypes</key>
			<array><string>com.adobe.pdf</string></array>
		</dict>
	</array>
</dict>
</plist>
INFO

  echo "built: $wf"
}

build_workflow jpg JPG
build_workflow png PNG
echo "workflows built. Shortcuts are built via the shortcuts-playground skill."
