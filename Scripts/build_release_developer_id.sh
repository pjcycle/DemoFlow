#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
workspace_root="${project_dir:h}"
project_path="${project_dir}/DemoFlow.xcodeproj"

scheme="${SCHEME:-DemoFlow}"
configuration="${CONFIGURATION:-Release}"
team_id="${TEAM_ID:-WZZACQ5JCC}"
signing_identity="${SIGNING_IDENTITY:-Developer ID Application: PJ Lee (WZZACQ5JCC)}"
archive_signing_style="${ARCHIVE_SIGNING_STYLE:-manual}"
build_root="${BUILD_ROOT:-${workspace_root}/Build}"
archive_path="${ARCHIVE_PATH:-${build_root}/Archives/ReleaseDeveloperID/DemoFlow.xcarchive}"
export_path="${EXPORT_PATH:-${build_root}/Exports/ReleaseDeveloperID}"
export_options_plist="${EXPORT_OPTIONS_PLIST:-${script_dir}/ExportOptions.ReleaseDeveloperID.plist}"
derived_data_path="${DERIVED_DATA_PATH:-${build_root}/DerivedData}"

rm -rf "$archive_path" "$export_path"
mkdir -p "${archive_path:h}" "$export_path" "$derived_data_path"

echo "[DemoFlow release] Archiving ${scheme} (${configuration}) with ${signing_identity}"
if [[ "${archive_signing_style:l}" == "manual" ]]; then
	archive_signing_args=(
		DEVELOPMENT_TEAM="$team_id"
		CODE_SIGN_STYLE=Manual
		CODE_SIGN_IDENTITY="$signing_identity"
	)
else
	archive_signing_args=(
		DEVELOPMENT_TEAM="$team_id"
		CODE_SIGN_STYLE=Automatic
	)
fi

/usr/bin/xcodebuild archive \
	-project "$project_path" \
	-scheme "$scheme" \
	-configuration "$configuration" \
	-destination "generic/platform=macOS" \
	-archivePath "$archive_path" \
	-derivedDataPath "$derived_data_path" \
	"${archive_signing_args[@]}" \
	INCLUDE_YT_DLP=YES

echo "[DemoFlow release] Exporting archive"
/usr/bin/xcodebuild -exportArchive \
	-archivePath "$archive_path" \
	-exportPath "$export_path" \
	-exportOptionsPlist "$export_options_plist"

echo "[DemoFlow release] Export completed:"
/bin/ls -la "$export_path"
