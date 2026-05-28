#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
workspace_root="${project_dir:h}"
project_path="${project_dir}/DemoFlow.xcodeproj"
collect_dsyms_script="${script_dir}/collect_archive_dsyms.sh"

scheme="${SCHEME:-DemoFlow}"
configuration="${CONFIGURATION:-AppStore}"
team_id="${TEAM_ID:-WZZACQ5JCC}"
build_root="${BUILD_ROOT:-${workspace_root}/Build}"
archive_path="${ARCHIVE_PATH:-${build_root}/Archives/AppStore/DemoFlow.xcarchive}"
export_path="${EXPORT_PATH:-${build_root}/Exports/AppStore}"
export_options_plist="${EXPORT_OPTIONS_PLIST:-${script_dir}/ExportOptions.AppStore.plist}"
derived_data_path="${DERIVED_DATA_PATH:-${build_root}/DerivedData}"
build_products_dir="${BUILD_PRODUCTS_DIR:-${build_root}/Products/${configuration}}"

rm -rf "$archive_path" "$export_path"
mkdir -p "${archive_path:h}" "$export_path" "$derived_data_path"

echo "[DemoFlow appstore] Archiving ${scheme} (${configuration})"
/usr/bin/xcodebuild archive \
	-project "$project_path" \
	-scheme "$scheme" \
	-configuration "$configuration" \
	-destination "generic/platform=macOS" \
	-archivePath "$archive_path" \
	-derivedDataPath "$derived_data_path" \
	-allowProvisioningUpdates \
	DEVELOPMENT_TEAM="$team_id" \
		CODE_SIGN_STYLE=Automatic \
		INCLUDE_YT_DLP=NO

echo "[DemoFlow appstore] Collecting archive dSYMs"
/bin/zsh "$collect_dsyms_script" "$archive_path" "$build_products_dir"

echo "[DemoFlow appstore] Exporting archive"
/usr/bin/xcodebuild -exportArchive \
	-archivePath "$archive_path" \
	-exportPath "$export_path" \
	-exportOptionsPlist "$export_options_plist" \
	-allowProvisioningUpdates

echo "[DemoFlow appstore] Export completed:"
/bin/ls -la "$export_path"
