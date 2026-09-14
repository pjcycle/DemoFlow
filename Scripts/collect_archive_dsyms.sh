#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 ]]; then
	echo "usage: $0 <archive_path> <build_products_dir>" >&2
	exit 1
fi

archive_path="$1"
build_products_dir="$2"

apps_dir="${archive_path}/Products/Applications"
archive_dsyms_dir="${archive_path}/dSYMs"

if [[ ! -d "$apps_dir" ]]; then
	echo "[DemoFlow dSYM] Missing archive app directory: $apps_dir" >&2
	exit 1
fi

app_bundle="$(/usr/bin/find "$apps_dir" -maxdepth 1 -type d -name "*.app" | /usr/bin/head -n 1)"
if [[ -z "${app_bundle}" || ! -d "$app_bundle" ]]; then
	echo "[DemoFlow dSYM] No .app bundle found in archive; skip dSYM collection."
	exit 0
fi

app_name="${app_bundle:t:r}"
app_info_plist="${app_bundle}/Contents/Info.plist"
app_identifier="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_info_plist" 2>/dev/null || true)"
app_short_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_info_plist" 2>/dev/null || true)"
app_build_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_info_plist" 2>/dev/null || true)"
if [[ -z "$app_identifier" ]]; then
	app_identifier="pjln.top.demoflow"
fi

mkdir -p "$archive_dsyms_dir"

copy_app_dsym() {
	local src_dsym="$1"
	local dst_dsym="${archive_dsyms_dir}/${app_name}.app.dSYM"
	if [[ -d "$src_dsym" ]]; then
		rm -rf "$dst_dsym"
		/usr/bin/ditto "$src_dsym" "$dst_dsym"
		echo "[DemoFlow dSYM] Copied app dSYM: ${dst_dsym}"
		return 0
	fi

	local app_binary="${app_bundle}/Contents/MacOS/${app_name}"
	if [[ ! -f "$app_binary" ]]; then
		echo "[DemoFlow dSYM] App binary not found: ${app_binary}; skip app dSYM generation."
		return 0
	fi

	rm -rf "$dst_dsym"
	/usr/bin/dsymutil "$app_binary" -o "$dst_dsym" >/dev/null 2>/dev/null
	echo "[DemoFlow dSYM] Generated app dSYM from binary: ${dst_dsym}"
}

copy_app_dsym "${build_products_dir}/${app_name}.app.dSYM"

create_helper_dsym_bundle() {
	local helper_name="$1"
	local helper_binary="${app_bundle}/Contents/Helpers/${helper_name}"
	if [[ ! -f "$helper_binary" ]]; then
		echo "[DemoFlow dSYM] Helper not found: ${helper_binary}; skip."
		return 0
	fi

	local dsym_bundle="${archive_dsyms_dir}/${helper_name}.dSYM"
	local binary_uuid
	binary_uuid="$(/usr/bin/dwarfdump --uuid "$helper_binary" | awk 'NR == 1 { print $2 }')"
	if [[ -z "$binary_uuid" ]]; then
		echo "[DemoFlow dSYM] Unable to read UUID for ${helper_name}: ${helper_binary}" >&2
		return 1
	fi

	rm -rf "$dsym_bundle"
	if ! /usr/bin/dsymutil "$helper_binary" -o "$dsym_bundle"; then
		echo "[DemoFlow dSYM] Failed to generate dSYM for ${helper_name}" >&2
		return 1
	fi
	local dsym_uuid
	dsym_uuid="$(/usr/bin/dwarfdump --uuid "$dsym_bundle" | awk 'NR == 1 { print $2 }')"
	if [[ "$binary_uuid" != "$dsym_uuid" ]]; then
		echo "[DemoFlow dSYM] UUID mismatch for ${helper_name}: binary=${binary_uuid}, dsym=${dsym_uuid}" >&2
		return 1
	fi
	echo "[DemoFlow dSYM] Generated helper dSYM: ${dsym_bundle}"
}

create_helper_dsym_bundle "ffmpeg"
create_helper_dsym_bundle "ffprobe"
create_helper_dsym_bundle "whisper-cli"

echo "[DemoFlow dSYM] Archive dSYM collection finished."
