#!/bin/zsh
set -euo pipefail

app_bundle="${CODESIGNING_FOLDER_PATH:-}"
if [[ -z "$app_bundle" ]]; then
	app_bundle="${TARGET_BUILD_DIR:-}/${FULL_PRODUCT_NAME:-}"
fi
if [[ "$app_bundle" != /* ]]; then
	app_bundle="${TARGET_BUILD_DIR:-}/${app_bundle}"
fi

if [[ -z "$app_bundle" || ! -d "$app_bundle" ]]; then
	echo "[DemoFlow codesign] App bundle not found; skipping embedded tool signing."
	exit 0
fi

contents_dir="${app_bundle}/Contents"
resources_dir="${contents_dir}/Resources"
helpers_dir="${contents_dir}/Helpers"
runtime_resources_dir="${resources_dir}/Runtime"
script_dir="${0:A:h}"
srcroot="${SRCROOT:-${script_dir:h}}"
collect_dsyms_script="${script_dir}/collect_archive_dsyms.sh"

write_script_output_stamp() {
	local stamp="${SCRIPT_OUTPUT_FILE_0:-}"
	if [[ -z "$stamp" ]]; then
		return 0
	fi
	/bin/mkdir -p "${stamp:h}"
	/usr/bin/touch "$stamp"
}
trap write_script_output_stamp EXIT

pick_existing_dir() {
	local candidate
	for candidate in "$@"; do
		if [[ -d "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

ffmpeg_source_dir="${DEMOFLOW_FFMPEG_SOURCE_DIR:-}"
if [[ -z "$ffmpeg_source_dir" ]]; then
	ffmpeg_source_dir="$(pick_existing_dir \
		"${srcroot}/DemoFlow/ThirdParty/ffmpeg/arm64" \
		"${srcroot}/ThirdParty/ffmpeg/arm64")" || {
		echo "[DemoFlow codesign] Unable to locate ffmpeg source directory from SRCROOT=${srcroot}" >&2
		exit 1
	}
fi

ytdlp_source_dir="${DEMOFLOW_YT_DLP_SOURCE_DIR:-}"
if [[ -z "$ytdlp_source_dir" ]]; then
	ytdlp_source_dir="$(pick_existing_dir \
		"${srcroot}/DemoFlow/ThirdParty/yt-dlp/arm64" \
		"${srcroot}/ThirdParty/yt-dlp/arm64")" || {
		echo "[DemoFlow codesign] Unable to locate yt-dlp source directory from SRCROOT=${srcroot}" >&2
		exit 1
	}
fi

entitlements_path="${DEMOFLOW_EMBEDDED_TOOL_ENTITLEMENTS:-${script_dir}/EmbeddedTool.entitlements}"

if [[ ! -d "$resources_dir" ]]; then
	echo "[DemoFlow codesign] Resources directory not found; skipping embedded tool signing."
	exit 0
fi

if [[ ! -f "$entitlements_path" ]]; then
	echo "[DemoFlow codesign] Missing helper entitlements: ${entitlements_path}" >&2
	exit 1
fi

mkdir -p "$helpers_dir"

copy_path() {
	local source="$1"
	local destination="$2"
	if [[ ! -e "$source" ]]; then
		echo "[DemoFlow codesign] Missing source path: $source" >&2
		exit 1
	fi
	rm -rf "$destination"
	/usr/bin/ditto "$source" "$destination"
}

remove_stale_resource_code() {
	local candidate
	for candidate in \
		"${resources_dir}/ffmpeg" \
		"${resources_dir}/ffprobe" \
		"${resources_dir}/yt-dlp" \
		"${resources_dir}/yt-dlp_macos_onedir" \
		"${resources_dir}/Runtime"
	do
		if [[ -e "$candidate" ]]; then
			rm -rf "$candidate"
			echo "[DemoFlow codesign] Removed stale resource code ${candidate#${app_bundle}/}"
		fi
	done
}

collect_archive_dsyms_if_needed() {
	# During "Archive", TARGET_BUILD_DIR points into *.xcarchive/Products/Applications.
	# In normal build/run this pattern won't match, so we skip safely.
	if [[ "$app_bundle" != *.xcarchive/Products/Applications/*.app ]]; then
		return 0
	fi

	local archive_path="${app_bundle%/Products/Applications/*}"
	if [[ -z "$archive_path" || "$archive_path" != *.xcarchive ]]; then
		return 0
	fi

	if [[ ! -x "$collect_dsyms_script" ]]; then
		echo "[DemoFlow codesign] dSYM collector script not executable, skipping archive dSYM collection."
		return 0
	fi

	local build_products_dir="${DWARF_DSYM_FOLDER_PATH:-${CONFIGURATION_BUILD_DIR:-${TARGET_BUILD_DIR:-}}}"
	if [[ -z "$build_products_dir" || ! -d "$build_products_dir" ]]; then
		echo "[DemoFlow codesign] Unable to resolve dSYM build products directory, skipping archive dSYM collection."
		return 0
	fi

	echo "[DemoFlow codesign] Collecting archive dSYMs into ${archive_path}/dSYMs"
	/bin/zsh "$collect_dsyms_script" "$archive_path" "$build_products_dir"
}

copy_path "${ffmpeg_source_dir}/ffmpeg" "${helpers_dir}/ffmpeg"
copy_path "${ffmpeg_source_dir}/ffprobe" "${helpers_dir}/ffprobe"
chmod +x "${helpers_dir}/ffmpeg" "${helpers_dir}/ffprobe"
remove_stale_resource_code

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
	collect_archive_dsyms_if_needed
	echo "[DemoFlow codesign] Embedded helper tools without signing because code signing is disabled."
	exit 0
fi

signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
	signing_identity="${CODE_SIGN_IDENTITY:-}"
fi
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
	echo "[DemoFlow codesign] No signing identity found for embedded helpers." >&2
	exit 1
fi

product_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-pjln.top.demoflow}"
codesign_common_flags=(
	--force
	--sign "$signing_identity"
	--options runtime
	--generate-entitlement-der
)

helpers=(ffmpeg ffprobe)
for helper in "${helpers[@]}"; do
	helper_path="${helpers_dir}/${helper}"
	identifier="${product_identifier}.${helper}"
	if [[ -f "$helper_path" ]]; then
		echo "[DemoFlow codesign] Signing ${helper_path#${app_bundle}/} as ${identifier}"
		/usr/bin/codesign "${codesign_common_flags[@]}" --identifier "$identifier" --entitlements "$entitlements_path" "$helper_path"
	else
		echo "[DemoFlow codesign] Warning: ${helper} not found at ${helper_path}" >&2
	fi
done

include_ytdlp="${INCLUDE_YT_DLP:-${DEMOFLOW_INCLUDE_YT_DLP:-YES}}"
if [[ "$include_ytdlp" == "YES" ]]; then
	ytdlp_source="${ytdlp_source_dir}/yt-dlp"
	ytdlp_dest="${helpers_dir}/yt-dlp"
	if [[ -f "$ytdlp_source" ]]; then
		copy_path "$ytdlp_source" "$ytdlp_dest"
		chmod +x "$ytdlp_dest"
		ytdlp_identifier="${product_identifier}.yt-dlp"
		echo "[DemoFlow codesign] Signing yt-dlp as ${ytdlp_identifier}"
		/usr/bin/codesign "${codesign_common_flags[@]}" --identifier "$ytdlp_identifier" --entitlements "$entitlements_path" "$ytdlp_dest"
		echo "[DemoFlow codesign] yt-dlp included in this build."
	else
		echo "[DemoFlow codesign] Warning: yt-dlp source not found at ${ytdlp_source}, skipping." >&2
	fi
else
	echo "[DemoFlow codesign] yt-dlp excluded from this build (AppStore)."
fi

collect_archive_dsyms_if_needed

echo "[DemoFlow codesign] Signed embedded helpers into Contents/Helpers."
