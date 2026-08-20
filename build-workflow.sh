#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
workflow_dir="$project_dir/Workflow"
staging_dir="$project_dir/.tmp/alfred-workflow"
dist_dir="$project_dir/dist"
output_path="$dist_dir/BetterFind.alfredworkflow"
source_root="$staging_dir/Source/BetterFind"

cd "$project_dir"
swift build -c release --arch arm64
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"

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
# The source package uses a local Yams checkout, so rebuilding does not depend on
# the remote package declaration used by this development repository.
mkdir -p "$source_root/Vendor" "$source_root/LICENSES"
/usr/bin/sed 's#\.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")#.package(path: "Vendor/Yams")#' \
    "Package.swift" > "$source_root/Package.swift"
cp "Package.resolved" "build-workflow.sh" "README.md" "LICENSE" "LICENSE-MIT" \
    "COPYING.md" "SOURCE.md" "THIRD_PARTY_NOTICES.md" "$source_root/"
cp -R "Sources" "Assets" "Workflow" "$source_root/"
cp -R "Vendor/ClingCore" "$source_root/Vendor/"
cp "LICENSES/Yams-MIT.txt" "$source_root/LICENSES/"

if [[ -d "$project_dir/Vendor/Yams" ]]; then
    yams_source="$project_dir/Vendor/Yams"
elif [[ -d "$project_dir/.build/checkouts/Yams" ]]; then
    yams_source="$project_dir/.build/checkouts/Yams"
else
    print -u2 "Yams source checkout is unavailable after dependency resolution"
    exit 1
fi
cp -R "$yams_source" "$source_root/Vendor/Yams"
rm -rf "$source_root/Vendor/Yams/.git"
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
