#!/usr/bin/env bash
# Assembles the Quick Action wrappers from the templates + engine.
#
# Automator .workflow bundles are built here in full. For the .shortcut
# wrappers this script generates their self-contained shell bodies
# (wrappers/shortcut-<fmt>.sh, with the engine embedded); the actual
# .shortcut files are built from those bodies via the shortcuts-playground
# skill and committed directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="$REPO_ROOT/wrappers/dispatcher.sh.tmpl"
SHORTCUT_TMPL="$REPO_ROOT/wrappers/shortcut-dispatcher.sh.tmpl"
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

  # Capture the workflow plist from a QUOTED heredoc so no shell expansion
  # happens — a future variable-name collision between the dispatcher
  # template and this script can no longer corrupt the generated workflow.
  # The escaped dispatcher is spliced in afterward via a literal placeholder.
  local template_plist
  template_plist="$(cat <<'PLIST'
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
					<string>@@DISPATCHER@@</string>
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
)"

  # Splice the escaped dispatcher into the placeholder using pure shell
  # parameter expansion — zero interpretation of $esc (no sed/awk regex or
  # & re-interpretation), so the embedded script lands byte-for-byte.
  local before after
  before="${template_plist%%@@DISPATCHER@@*}"
  after="${template_plist##*@@DISPATCHER@@}"
  printf '%s%s%s\n' "$before" "$esc" "$after" > "$contents/document.wflow"

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

# Generate the self-contained shell body for a .shortcut wrapper. Unlike the
# .workflow bundle, a .shortcut cannot carry a sibling engine file, so the full
# engine source is embedded into the script. Splicing is pure parameter
# expansion — zero interpretation of the engine source.
build_shortcut_script() {
  local format="$1"
  local out="$REPO_ROOT/wrappers/shortcut-$format.sh"

  # Read the Shortcut dispatcher template, substitute the format.
  local template
  template="$(sed "s/{{FORMAT}}/$format/g" "$SHORTCUT_TMPL")"

  # Read the engine source verbatim.
  local engine_src
  engine_src="$(cat "$ENGINE")"

  # Splice the engine into the {{ENGINE}} placeholder via parameter expansion.
  # The engine is written inside a quoted heredoc in the template, so its $
  # variables and backslashes survive untouched.
  local before after
  before="${template%%\{\{ENGINE\}\}*}"
  after="${template##*\{\{ENGINE\}\}}"
  printf '%s%s%s\n' "$before" "$engine_src" "$after" > "$out"

  echo "built: $out"
}

build_workflow jpg JPG
build_workflow png PNG
build_shortcut_script jpg
build_shortcut_script png
echo "workflows built; shortcut shell bodies generated."
echo "The .shortcut files are built from wrappers/shortcut-<fmt>.sh via the"
echo "shortcuts-playground skill."
