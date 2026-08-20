#!/bin/zsh

workflow_dir="${0:A:h}"
limit="${result_limit:-100}"
system_folders="${system_folders_yaml-}"
excluded_paths="${excluded_paths_yaml-}"

if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
    limit=100
fi

if [[ -z "$system_folders" ]]; then
    system_folders=$'- System\n- private\n- usr\n- bin\n- sbin\n- cores\n- dev\n- etc'
fi
if [[ -z "$excluded_paths" ]]; then
    excluded_paths=$'- "~/Library/Caches"\n- "~/Library/Containers"\n- "~/Library/Group Containers"\n- "~/Library/Application Support"\n- "~/Library/Developer"\n- "~/Library/Metadata"'
fi

query="$*"
if (( $# == 0 )) || [[ -z "${query//[[:space:]]/}" ]]; then
    print -rn -- '{"items":[{"title":"Type a filename to search","subtitle":"Better Find searches the configured root","valid":false}]}'
    exit 0
fi

workflow_data="${alfred_workflow_data:-$HOME/Library/Caches/com.betterfind.workflow}"
args=(
    "$workflow_dir/better-find"
    --root "${search_root:-~}"
    --system-folders-yaml "$system_folders"
    --excluded-paths-yaml "$excluded_paths"
    --limit "$limit"
    --sort-by "${sort_by:-relevance}"
    --sort-order "${sort_order:-descending}"
    --index-path "$workflow_data/file-index.idx"
)

if [[ "${include_subfolders:-1}" == 1 ]]; then
    args+=(--include-subfolders)
else
    args+=(--no-subfolders)
fi

if [[ "${include_hidden_files:-0}" == 1 ]]; then
    args+=(--include-hidden)
else
    args+=(--exclude-hidden)
fi

if [[ "${case_sensitive:-0}" == 1 ]]; then
    args+=(--case-sensitive)
else
    args+=(--case-insensitive)
fi

if [[ "${exclude_system_folders:-1}" == 1 ]]; then
    args+=(--exclude-system)
else
    args+=(--include-system)
fi

output="$("${args[@]}" -- "$query" 2>/dev/null)"
exit_status=$?

if (( exit_status != 0 )); then
    print -rn -- '{"items":[{"title":"Better Find could not complete the search","subtitle":"Review the Better Find workflow configuration in Alfred","valid":false}]}'
    exit 0
fi

if [[ "$output" == '{"items":[]}' ]]; then
    print -rn -- '{"items":[{"title":"No matching files or folders","subtitle":"Try another search term or review the workflow settings","valid":false}]}'
    exit 0
fi

print -rn -- "$output"
