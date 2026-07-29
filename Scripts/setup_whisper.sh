#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
# Keep the full whisper.cpp checkout outside the Xcode synchronized source
# group. Only the built helper and model belong in the app's ThirdParty tree.
source_root="${project_root}/../whisper-src"
source_root="${source_root:A}"
resource_root="${project_root}/DemoFlow/ThirdParty/whisper"

if ! command -v cmake >/dev/null 2>&1; then
	echo "CMake is required. Install it with: brew install cmake" >&2
	exit 2
fi

if [[ ! -f "${source_root}/CMakeLists.txt" ]]; then
	echo "whisper.cpp source not found: ${source_root}" >&2
	exit 1
fi

echo "[DemoFlow Whisper] Configuring Metal build..."
cmake -S "$source_root" -B "${source_root}/build" \
	-DGGML_METAL=ON \
	-DBUILD_SHARED_LIBS=OFF \
	-DWHISPER_BUILD_EXAMPLES=ON \
	-DWHISPER_BUILD_TESTS=OFF

echo "[DemoFlow Whisper] Building whisper-cli..."
cmake --build "${source_root}/build" --config Release --parallel

cli="${source_root}/build/bin/whisper-cli"
build_bin="${source_root}/build/bin"
if [[ ! -x "$cli" ]]; then
	echo "whisper-cli was not generated: ${cli}" >&2
	exit 1
fi

# Keep the helper available even when the separate model download is blocked.
# This makes the build state explicit and lets a later model-only retry finish
# without compiling whisper.cpp again.
mkdir -p "${resource_root}/arm64"
cp "$cli" "${resource_root}/arm64/whisper-cli"
chmod +x "${resource_root}/arm64/whisper-cli"


model="${source_root}/models/ggml-base.bin"
if [[ ! -f "$model" ]]; then
	echo "[DemoFlow Whisper] Downloading multilingual base model..."
	(
		cd "$source_root"
		bash ./models/download-ggml-model.sh base
	)
fi

if [[ ! -f "$model" ]]; then
	echo "ggml-base.bin was not generated: ${model}" >&2
	exit 1
fi

mkdir -p "${resource_root}/models"
cp "$model" "${resource_root}/models/ggml-base.bin"

echo "[DemoFlow Whisper] Ready:"
echo "  ${resource_root}/arm64/whisper-cli"
echo "  ${resource_root}/models/ggml-base.bin"
