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

	local tmp_dir
	tmp_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/demoflow-${helper_name}-dsym.XXXXXX")"
	local dwarf_file="${tmp_dir}/${helper_name}.dwarf"
	local dsym_bundle="${archive_dsyms_dir}/${helper_name}.dSYM"
	local info_plist="${dsym_bundle}/Contents/Info.plist"

	/usr/bin/dsymutil --flat "$helper_binary" -o "$dwarf_file" >/dev/null 2>/dev/null
	if [[ ! -s "$dwarf_file" ]]; then
		echo "[DemoFlow dSYM] Empty dSYM data for ${helper_name}; skip."
		rm -rf "$tmp_dir"
		return 0
	fi

	rm -rf "$dsym_bundle"
	mkdir -p "${dsym_bundle}/Contents/Resources/DWARF"
	/bin/cp "$dwarf_file" "${dsym_bundle}/Contents/Resources/DWARF/${helper_name}"

	rm -f "$info_plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string English" "$info_plist" >/dev/null
	/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.apple.xcode.dsym.${app_identifier}.${helper_name}" "$info_plist" >/dev/null
	/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$info_plist" >/dev/null
	/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string dSYM" "$info_plist" >/dev/null
	/usr/libexec/PlistBuddy -c "Add :CFBundleSignature string ????" "$info_plist" >/dev/null
	if [[ -n "$app_short_version" ]]; then
		/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${app_short_version}" "$info_plist" >/dev/null
	fi
	if [[ -n "$app_build_version" ]]; then
		/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${app_build_version}" "$info_plist" >/dev/null
	fi

	rm -rf "$tmp_dir"
	echo "[DemoFlow dSYM] Generated helper dSYM: ${dsym_bundle}"
}

create_helper_dsym_bundle "ffmpeg"
create_helper_dsym_bundle "ffprobe"

echo "[DemoFlow dSYM] Archive dSYM collection finished."
