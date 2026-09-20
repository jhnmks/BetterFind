#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
workflow_dir="$project_dir/Workflow"
staging_dir="$project_dir/.tmp/alfred-workflow"
dist_dir="$project_dir/dist"
output_path="$dist_dir/BetterFind.alfredworkflow"
source_root="$staging_dir/Source/BetterFind"

cd "$project_dir"
# Swift 6.4's default swiftbuild engine currently fails during initialization on
# some macOS installations with "Unknown error parsing property list". The
# native SwiftPM engine remains compatible with this package.
build_args=(--build-system native -c release --arch arm64)
swift build "${build_args[@]}" --product better-find
swift build "${build_args[@]}" --product better-find-backend
binary_dir="$(swift build "${build_args[@]}" --show-bin-path)"

for executable in better-find better-find-backend; do
    architectures="$(/usr/bin/lipo -archs "$binary_dir/$executable")"
    if [[ "$architectures" != "arm64" ]]; then
        print -u2 "Expected an arm64-only $executable binary, got: $architectures"
        exit 1
    fi
done

rm -rf "$staging_dir"
mkdir -p "$staging_dir" "$dist_dir"
cp "$workflow_dir/info.plist" "$workflow_dir/icon.png" "$workflow_dir/search.zsh" "$workflow_dir/open-terminal.zsh" "$staging_dir/"
cp "$binary_dir/better-find" "$staging_dir/better-find"
cp "$binary_dir/better-find-backend" "$staging_dir/better-find-backend"
/usr/bin/strip -S "$staging_dir/better-find" "$staging_dir/better-find-backend"
cp "README.md" "LICENSE" "LICENSE-MIT" "COPYING.md" "SOURCE.md" "THIRD_PARTY_NOTICES.md" "$staging_dir/"
mkdir -p "$staging_dir/LICENSES" "$staging_dir/Vendor/ClingCore"
cp "LICENSES/Yams-MIT.txt" "$staging_dir/LICENSES/"
cp "Vendor/ClingCore/LICENSE" "Vendor/ClingCore/UPSTREAM.md" "$staging_dir/Vendor/ClingCore/"

# Bundle complete, rebuildable corresponding source with every distributed copy.
# Yams is vendored in the development repository, so the packaged source uses
# the same local dependency graph and does not require network access.
mkdir -p "$source_root/Vendor" "$source_root/LICENSES"
cp "Package.swift" "build-workflow.sh" "README.md" "LICENSE" "LICENSE-MIT" \
    "COPYING.md" "SOURCE.md" "THIRD_PARTY_NOTICES.md" "$source_root/"
cp -R "Sources" "Assets" "Workflow" "$source_root/"
cp -R "Vendor/ClingCore" "Vendor/Yams" "$source_root/Vendor/"
cp "LICENSES/Yams-MIT.txt" "$source_root/LICENSES/"
/usr/bin/find "$source_root/Vendor/Yams" -type d \
    \( -name .git -o -name .build -o -name .swiftpm -o -name .agent-build -o -name .agent-build-native \) \
    -prune -exec rm -rf {} +
/usr/bin/find "$staging_dir" -name .DS_Store -delete

chmod 755 "$staging_dir/better-find" "$staging_dir/better-find-backend" \
    "$staging_dir/search.zsh" "$staging_dir/open-terminal.zsh" \
    "$source_root/build-workflow.sh" "$source_root/Workflow/search.zsh" \
    "$source_root/Workflow/open-terminal.zsh"

readme_contents="$(<"$project_dir/README.md")"
plutil -replace readme -string "$readme_contents" "$staging_dir/info.plist"
plutil -lint "$staging_dir/info.plist"
rm -f "$output_path"
(
    cd "$staging_dir"
    /usr/bin/zip -q -r "$output_path" .
)
rm -rf "$staging_dir"

print "Built: $output_path"
print "Install with: open '$output_path'"
