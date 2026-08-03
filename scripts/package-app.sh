#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
output_dir="$project_root/outputs"
dmg_path="$output_dir/Passage.dmg"
legacy_app_path="$output_dir/Passage.app"
legacy_zip_path="$output_dir/Passage.zip"
build_dir="$project_root/.build/arm64-apple-macosx/release"
cache_dir="$project_root/work/packaging-cache"
visual_model_id="meta-pe-core-s-16-384"
visual_model_revision="3249a38eb1c432ec19231c6fe1774acb6a4e4efe"
visual_manifest_sha256="e8ab953b8ec53eeae643c96f35b164424f3a92977aa00b244ca74f41acee96ea"
visual_pack_source="$project_root/Support/VisualModelPacks/$visual_model_id/$visual_model_revision"

python3 "$project_root/scripts/verify-visual-model-pack.py" \
  "$visual_pack_source" \
  --manifest-sha256 "$visual_manifest_sha256" \
  --identifier "$visual_model_id" \
  --revision "$visual_model_revision"

# A stable signing requirement lets macOS carry Screen Recording and
# Accessibility grants across Passage updates. Prefer an existing Developer
# ID identity; callers can override it, or set `PASSAGE_CODESIGN_IDENTITY=-`
# for an intentionally ad-hoc development build.
signing_identity="${PASSAGE_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application:/{print $2; exit}')"
fi
if [[ -z "$signing_identity" ]]; then
  echo "error: no Developer ID Application identity found; set PASSAGE_CODESIGN_IDENTITY=- only for an explicit ad-hoc development build" >&2
  exit 1
fi
typeset -a codesign_options
codesign_options=(--force --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
  codesign_options+=(--options runtime --timestamp)
fi

mkdir -p "$output_dir" "$cache_dir/clang" "$cache_dir/swift"

CLANG_MODULE_CACHE_PATH="$cache_dir/clang" \
SWIFT_MODULECACHE_PATH="$cache_dir/swift" \
swift build --package-path "$project_root" -c release --product PassageDesktop
CLANG_MODULE_CACHE_PATH="$cache_dir/clang" \
SWIFT_MODULECACHE_PATH="$cache_dir/swift" \
swift build --package-path "$project_root" -c release --product passage
CLANG_MODULE_CACHE_PATH="$cache_dir/clang" \
SWIFT_MODULECACHE_PATH="$cache_dir/swift" \
swift build --package-path "$project_root" -c release --product passage-visual-smoke

# Passage records discrete stills. Linking the live SCStream class is a
# release-blocking regression because macOS then presents Passage as an
# ongoing screen-sharing session. SCStreamConfiguration is intentionally used
# to describe still-image output and does not trip this exact-symbol check.
if nm -u "$build_dir/PassageDesktop" | rg '_OBJC_CLASS_\$_SCStream$' >/dev/null; then
  echo "error: PassageDesktop links SCStream; periodic capture must use one-shot screenshots" >&2
  exit 1
fi
if ! nm -u "$build_dir/PassageDesktop" | rg '_OBJC_CLASS_\$_SCScreenshotManager$' >/dev/null; then
  echo "error: PassageDesktop does not link the expected SCScreenshotManager backend" >&2
  exit 1
fi

staging_root="$(mktemp -d "/private/tmp/passage-package.XXXXXX")"
staging_app="$staging_root/Passage.app"
staging_dmg="$staging_root/Passage.dmg"
dmg_root="$staging_root/dmg-root"
mkdir -p \
  "$staging_app/Contents/MacOS" \
  "$staging_app/Contents/Frameworks" \
  "$staging_app/Contents/Resources/bin" \
  "$staging_app/Contents/Resources/ThirdParty" \
  "$staging_app/Contents/Resources/VisualModelPacks/$visual_model_id" \
  "$dmg_root"
cp "$build_dir/PassageDesktop" "$staging_app/Contents/MacOS/Passage"
cp "$build_dir/passage" "$staging_app/Contents/Resources/bin/passage"
cp "$project_root/Support/Passage-Info.plist" "$staging_app/Contents/Info.plist"
cp "$project_root/Support/Passage.icns" "$staging_app/Contents/Resources/Passage.icns"
cp -R "$project_root/AgentSkill" "$staging_app/Contents/Resources/AgentSkill"
cp -R \
  "$visual_pack_source" \
  "$staging_app/Contents/Resources/VisualModelPacks/$visual_model_id/$visual_model_revision"
ditto "$build_dir/SQLCipher.framework" "$staging_app/Contents/Frameworks/SQLCipher.framework"
cp \
  "$project_root/.build/checkouts/sqlcipher.swift/LICENSE.md" \
  "$staging_app/Contents/Resources/ThirdParty/SQLCipher-LICENSE.md"
cp \
  "$project_root/Support/Meta-PE-ATTRIBUTION.md" \
  "$staging_app/Contents/Resources/ThirdParty/Meta-PE-ATTRIBUTION.md"
chmod -R a+rX "$staging_app/Contents/Resources/VisualModelPacks"
python3 "$project_root/scripts/verify-visual-model-pack.py" \
  "$staging_app/Contents/Resources/VisualModelPacks/$visual_model_id/$visual_model_revision" \
  --manifest-sha256 "$visual_manifest_sha256" \
  --identifier "$visual_model_id" \
  --revision "$visual_model_revision"

# Hash verification alone cannot catch a model/runtime interface regression.
# Exercise both Core ML towers from the exact staged resources before signing;
# the private compilation cache remains outside the app and is never bundled.
visual_smoke_cache="$staging_root/visual-model-smoke-cache"
mkdir -m 700 "$visual_smoke_cache"
"$build_dir/passage-visual-smoke" \
  "$staging_app/Contents/Resources" \
  "$visual_smoke_cache"

install_name_tool \
  -add_rpath "@executable_path/../Frameworks" \
  "$staging_app/Contents/MacOS/Passage"
chmod -R u+w "$staging_app"
xattr -cr "$staging_app"
codesign "${codesign_options[@]}" "$staging_app/Contents/Frameworks/SQLCipher.framework"
codesign "${codesign_options[@]}" "$staging_app/Contents/Resources/bin/passage"
codesign "${codesign_options[@]}" "$staging_app"
codesign --verify --deep --strict --verbose=2 "$staging_app"
echo "Signed Passage with: $signing_identity" >&2

# Keep the installable app inside a read-only disk image. Extracting an app next
# to an archive in an iCloud-backed directory can attach Finder/File Provider
# metadata and invalidate nested code before installation.
# Preserve the signed bundle byte-for-byte, including any code-signing metadata
# represented as extended attributes by the current macOS toolchain. Stripping
# them here can make every nested signature fail after extraction.
ditto "$staging_app" "$dmg_root/Passage.app"
python3 "$project_root/scripts/verify-visual-model-pack.py" \
  "$dmg_root/Passage.app/Contents/Resources/VisualModelPacks/$visual_model_id/$visual_model_revision" \
  --manifest-sha256 "$visual_manifest_sha256" \
  --identifier "$visual_model_id" \
  --revision "$visual_model_revision"
codesign --verify --deep --strict --verbose=2 "$dmg_root/Passage.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -quiet \
  -volname "Passage" \
  -srcfolder "$dmg_root" \
  -format UDZO \
  -ov \
  "$staging_dmg"
hdiutil verify -quiet "$staging_dmg"

# Verify the artifact users will actually install, not only the source bundle.
# A private mount point also keeps this gate independent from any Passage
# volume the user may already have open in Finder.
verification_mount="$(mktemp -d "/private/tmp/passage-verify.XXXXXX")"
verification_device=""
cleanup_verification_mount() {
  if [[ -n "$verification_device" ]]; then
    hdiutil detach -quiet "$verification_device" >/dev/null 2>&1 || true
  fi
  if [[ "$verification_mount" == /private/tmp/passage-verify.* ]]; then
    rmdir "$verification_mount" >/dev/null 2>&1 || true
  fi
}
trap cleanup_verification_mount EXIT
attach_output="$(hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$verification_mount" \
  "$staging_dmg")"
verification_device="$(printf '%s\n' "$attach_output" \
  | awk -v expected="$verification_mount" '$NF == expected {print $1; exit}')"
if [[ -z "$verification_device" ]]; then
  echo "error: unable to identify mounted Passage verification device" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$verification_mount/Passage.app"
python3 "$project_root/scripts/verify-visual-model-pack.py" \
  "$verification_mount/Passage.app/Contents/Resources/VisualModelPacks/$visual_model_id/$visual_model_revision" \
  --manifest-sha256 "$visual_manifest_sha256" \
  --identifier "$visual_model_id" \
  --revision "$visual_model_revision"
cleanup_verification_mount
verification_device=""
trap - EXIT

if [[ -e "$legacy_app_path" || -e "$legacy_zip_path" || -e "$dmg_path" ]]; then
  previous_root="$(mktemp -d "$project_root/work/passage-previous.XXXXXX")"
  if [[ -e "$legacy_app_path" ]]; then
    mv "$legacy_app_path" "$previous_root/Passage.app"
  fi
  if [[ -e "$legacy_zip_path" ]]; then
    mv "$legacy_zip_path" "$previous_root/Passage.zip"
  fi
  if [[ -e "$dmg_path" ]]; then
    mv "$dmg_path" "$previous_root/Passage.dmg"
  fi
fi
mv "$staging_dmg" "$dmg_path"
if [[ "$staging_root" != /private/tmp/passage-package.* ]]; then
  echo "error: refusing to clean unexpected staging directory: $staging_root" >&2
  exit 1
fi
rm -rf "$staging_root"

echo "$dmg_path"
