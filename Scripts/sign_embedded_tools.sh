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
ffmpeg_source_dir="${DEMOFLOW_FFMPEG_SOURCE_DIR:-${srcroot}/DemoFlow/ThirdParty/ffmpeg/arm64}"
ytdlp_source_dir="${DEMOFLOW_YT_DLP_SOURCE_DIR:-${srcroot}/DemoFlow/ThirdParty/yt-dlp/arm64}"
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

copy_path "${ffmpeg_source_dir}/ffmpeg" "${helpers_dir}/ffmpeg"
copy_path "${ffmpeg_source_dir}/ffprobe" "${helpers_dir}/ffprobe"
chmod +x "${helpers_dir}/ffmpeg" "${helpers_dir}/ffprobe"
remove_stale_resource_code

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then
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

echo "[DemoFlow codesign] Signed embedded helpers into Contents/Helpers."
