#!/usr/bin/env bash
# Requires Bash and jq >= 1.6. No Azure connection is used by this renderer.
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
input=''
output=''
config="$script_dir/what-really-if.json"
summary=''
title='what-really-if — Bicep deployment preview'

usage() {
  cat <<'HELP'
Usage: what-really-if.sh --input whatif.json --output whatif.md [options]

  --config FILE        Project rules (default: what-really-if.json beside script)
  --summary-file FILE  Also write machine-readable counts and analysis issues
  --title TEXT         Markdown report title
  -h, --help           Show this help

Capture Azure CLI output separately, checking its exit status:
  az deployment group what-if --resource-group RG --template-file main.bicep \
    --no-pretty-print --result-format FullResourcePayloads > whatif.json
  ./what-really-if.sh --input whatif.json --output whatif.md

Exit codes:
  0  Report generated; no unacknowledged unknown effects or analysis gaps.
     This includes reports WITH changes to review. It is not approval to deploy.
  2  Invalid input/configuration, unsuccessful operation, or renderer failure.
  3  Report generated, but unknown effects or analysis gaps require review.

Defaults suppress explicit property-level NoEffect changes and verified scalar
metadata deletions for listed resource types. Common metadata paths match any
API version; other defaults remain version constrained. Other changes
remain visible. No property name, deletion, casing difference, or expression is
globally ignored. Ignore resources are conservatively treated as analysis gaps.
NoChange resources are counted, but omitted from the detailed resource list.

Project rules require an exact resourceType, anchored pathRegex, changeTypes,
and a reason. Optional apiVersions, beforeEquals, beforeIn, and afterEquals narrow
matches. allowStructural permits matching object/array differences. Resource
creates/deletes remain visible. Use "extends": "default" to inherit bundled rules.
acknowledgeUnsupported can mark reviewed Unsupported entries; see README.md.
Paths use dot notation and numeric brackets, e.g. properties.listeners[0].name.
The default config includes enabled, researched metadata rules; see README.md.

Keep the raw JSON as a pipeline artifact. Publish reports even on exit code 3.
Deploy the same template, parameters, scope, and mode used for the preview.
HELP
}

die() { printf 'what-really-if: %s\n' "$*" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --input|--output|--config|--summary-file|--title)
      (($# >= 2)) || die "Missing value for $1"
      case "$1" in
        --input) input=$2 ;; --output) output=$2 ;; --config) config=$2 ;;
        --summary-file) summary=$2 ;; --title) title=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
done
[[ -n "$input" && -n "$output" ]] || die '--input and --output are required'
command -v jq >/dev/null 2>&1 || die 'jq >= 1.6 is required'
[[ -f "$input" ]] || die "Input does not exist: $input"
[[ -f "$config" ]] || die "Configuration does not exist: $config"
[[ "$input" != "$output" && "$config" != "$output" ]] || die 'Output must differ from input and config'
[[ ! "$input" -ef "$output" && ! "$config" -ef "$output" ]] || die 'Output must not alias input or config'
if [[ -n "$summary" ]]; then
  [[ "$summary" != "$input" && "$summary" != "$config" && "$summary" != "$output" ]] || die 'Summary path must differ from other paths'
  [[ ! "$summary" -ef "$input" && ! "$summary" -ef "$config" && ! "$summary" -ef "$output" ]] || die 'Summary must not alias other paths'
fi

# Resolve existing symlinks and normalize even not-yet-created output paths,
# matching PowerShell's treatment of relative paths and destination aliases.
canonical_path() {
  local path=$1 depth=${2:-0} parent leaf target
  ((depth < 100)) || return 1
  [[ "$path" == /* ]] || path="$PWD/$path"
  if [[ "$path" == / ]]; then printf '/\n'; return; fi
  path=${path%/}
  parent=$(canonical_path "$(dirname -- "$path")" "$((depth + 1))") || return 1
  leaf=$(basename -- "$path")
  case "$leaf" in
    .) path=$parent ;;
    ..) path=$(dirname -- "$parent") ;;
    *) path="${parent%/}/$leaf" ;;
  esac
  if [[ -L "$path" ]]; then
    target=$(readlink -- "$path") || return 1
    [[ "$target" == /* ]] || target="$(dirname -- "$path")/$target"
    canonical_path "$target" "$((depth + 1))"
  else printf '%s\n' "$path"; fi
}
input=$(canonical_path "$input") || die 'Cannot resolve input path'
config=$(canonical_path "$config") || die 'Cannot resolve config path'
output=$(canonical_path "$output") || die 'Cannot resolve output path'
defaults=$(canonical_path "$script_dir/what-really-if.json") || die 'Cannot resolve defaults path'
engine=$(canonical_path "$script_dir/what-really-if.jq") || die 'Cannot resolve engine path'
if [[ -n "$summary" ]]; then
  summary=$(canonical_path "$summary") || die 'Cannot resolve summary path'
  [[ "$summary" != "$output" ]] || die 'Summary must differ from Markdown output'
fi
for source_path in "$input" "$config" "$defaults" "$engine"; do
  [[ "$source_path" != "$output" && ! "$source_path" -ef "$output" ]] || die 'Output must differ from input, config, and bundled engine/defaults'
  if [[ -n "$summary" ]]; then
    [[ "$source_path" != "$summary" && ! "$source_path" -ef "$summary" ]] || die 'Summary must differ from input, config, and bundled engine/defaults'
  fi
done

work_dir=$(mktemp -d) || die 'Cannot create temporary directory'
trap 'rm -rf -- "$work_dir"' EXIT
if ! jq -s --slurpfile config "$config" --slurpfile defaults "$defaults" --arg title "$title" \
    -f "$script_dir/what-really-if.jq" -- "$input" > "$work_dir/result.json"; then
  die 'Report not generated; inspect the error above'
fi

# Stage in the destination directory so each final rename is atomic.
publish() {
  local destination=$1 filter=$2 staged
  mkdir -p -- "$(dirname -- "$destination")"
  staged=$(mktemp "$(dirname -- "$destination")/.what-really-if.XXXXXX")
  if jq -r "$filter" "$work_dir/result.json" > "$staged" && mv -f -- "$staged" "$destination"; then
    return 0
  fi
  rm -f -- "$staged"
  return 1
}
publish "$output" '.markdown' || die 'Cannot write Markdown report'
if [[ -n "$summary" ]]; then
  publish "$summary" '.summary' || die 'Cannot write summary'
fi
exit "$(jq -r '.exitCode' "$work_dir/result.json")"
