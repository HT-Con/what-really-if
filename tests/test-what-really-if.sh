#!/usr/bin/env bash
# Regression fixtures: ensure meaningful changes cannot disappear as noise.
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
count=0

# Run the identical fixtures through either platform entry point. PowerShell
# shares the jq engine; exercise its process arguments, encoding and publishing.
render() {
  if [[ "${WHAT_REALLY_IF_RUNNER:-bash}" == powershell ]]; then
    local ps_args=()
    while (($#)); do
      case "$1" in
        --input) ps_args+=(-InputFile "$2") ;;
        --output) ps_args+=(-OutputFile "$2") ;;
        --config) ps_args+=(-ConfigFile "$2") ;;
        --summary-file) ps_args+=(-SummaryFile "$2") ;;
        --title) ps_args+=(-Title "$2") ;;
        *) printf 'Unsupported test argument: %s\n' "$1" >&2; return 2 ;;
      esac
      shift 2
    done
    "${POWERSHELL_EXE:-pwsh}" -NoLogo -NoProfile -File "$repo/what-really-if.ps1" "${ps_args[@]}"
  else
    bash "$repo/what-really-if.sh" "$@"
  fi
}

jq '.rules = []' "$repo/what-really-if.json" > "$tmp/empty-config.json"
cp "$tmp/empty-config.json" "$tmp/config.json"
cat > "$tmp/base.json" <<'JSON'
{"status":"Succeeded","changes":[{"resourceId":"/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/applicationGateways/gw","changeType":"Modify","before":{"apiVersion":"2024-05-01"},"after":{"apiVersion":"2024-05-01"},"delta":[{"path":"properties.provisioningState","propertyChangeType":"Delete","before":"Succeeded"}]}]}
JSON

run() {
  local name=$1 expected=$2 predicate=$3 actual=0
  render --input "$tmp/input.json" --output "$tmp/report.md" \
    --config "$tmp/config.json" --summary-file "$tmp/summary.json" > "$tmp/stdout" 2> "$tmp/stderr" || actual=$?
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$name" "$expected" "$actual" >&2
    cat "$tmp/stderr" >&2
    exit 1
  fi
  if [[ "$expected" != 2 ]]; then
    jq -e "$predicate" "$tmp/summary.json" >/dev/null || { printf 'FAIL %s: %s\n' "$name" "$predicate" >&2; cat "$tmp/summary.json" >&2; exit 1; }
    [[ -s "$tmp/report.md" ]]
  fi
  count=$((count + 1))
}
fixture() { jq "$1" "$tmp/base.json" > "$tmp/input.json"; }
fixture '.'
run 'metadata stays visible without matching rule' 0 '.reviewProperties == 1 and .suppressedProperties == 0'
fixture '.changes[0].delta[0].propertyChangeType = "NoEffect"'
run 'explicit NoEffect suppressed' 0 '.suppressedProperties == 1 and .noiseOnlyResources == 1'
fixture '.changes = []'
run 'valid empty result' 0 '.hasUnknown == false and .hasReviewChanges == false'
fixture '{status, properties: {changes}}'
run 'REST wrapper' 0 '.reviewResources == 1'
fixture '.changes[0].delta[0] = {path:"tags.Owner", propertyChangeType:"Delete", before:"Alice"}'
run 'tag deletion' 0 '.reviewProperties == 1'
fixture '.changes[0].delta[0] = {path:"properties.listeners", propertyChangeType:"Delete", before:[{name:"listener"}]}'
run 'whole array deletion' 0 '.reviewProperties == 1'
fixture '.changes[0].delta[0] = {path:"properties.path", propertyChangeType:"Modify", before:"/Path", after:"/path"}'
run 'case-sensitive value' 0 '.reviewProperties == 1'
fixture '.changes[0].delta[0] = {path:"properties.backend", propertyChangeType:"Modify", before:"old", after:{id:"[reference(\u0027backend\u0027).id]"}}'
run 'nested unresolved expression' 3 '.unknownProperties == 1 and .suppressedProperties == 0'
fixture '.changes[0].delta = []'
run 'Modify missing delta' 3 '.unknownResources == 1'
fixture 'del(.status)'
run 'missing status' 3 '(.analysisIssues | length) == 1'
fixture '.diagnostics = [{level:"Warning", message:"module skipped"}]'
run 'warning diagnostics' 3 '.hasUnknown and (.analysisIssues | length) == 1'
fixture '.diagnostics = [{level:"Info", message:"informational"}]'
run 'informational diagnostics' 0 '.hasUnknown == false'
fixture '.changes[0].changeType = "Ignore" | del(.changes[0].delta)'
run 'Ignore is uncertain' 3 '.unknownResources == 1'
fixture '.changes[0].changeType = "Deploy" | del(.changes[0].delta)'
run 'Deploy is uncertain' 3 '.unknownResources == 1'
fixture '.potentialChanges = [{changeType:"Delete",resourceId:"possible"}]'
run 'potential changes surfaced' 3 '.analysisIssues[0] | contains("possible")'
fixture '.status = "Failed"'
run 'failed operation' 2 ''
printf '{}\n' > "$tmp/input.json"
run 'missing changes' 2 ''
printf 'not JSON\n' > "$tmp/input.json"
run 'invalid JSON' 2 ''
printf '{} {}\n' > "$tmp/input.json"
run 'multiple documents' 2 ''
fixture '.error = {message:"failed"}'
run 'error payload' 2 ''
fixture '.changes[0].changeType = "Create" | del(.changes[0].delta)'
run 'resource create always visible' 0 '.reviewResources == 1 and .hasReviewChanges'
fixture '.changes[0].changeType = "Delete" | del(.changes[0].delta)'
run 'resource delete always visible' 0 '.reviewResources == 1 and .hasReviewChanges'
fixture '.changes[0].changeType = "NoChange" | del(.changes[0].delta)'
run 'NoChange counted' 0 '.unchangedResources == 1 and .hasReviewChanges == false'

# Project override: exact resource type, anchored path, kind, API version, value.
jq '.rules = [.rules[0]] | .rules[0].enabled = true | .rules[0].apiVersions = ["2024-05-01"] | .rules[0].beforeEquals = "Succeeded"' \
  "$repo/what-really-if.json" > "$tmp/config.json"
fixture '.'
run 'verified project metadata' 0 '.suppressedProperties == 1'
fixture '.changes[0].after.apiVersion = "2099-01-01"'
run 'API version mismatch' 0 '.suppressedProperties == 0 and .reviewProperties == 1'
fixture '.changes[0].delta[0].before = "Failed"'
run 'value constraint mismatch' 0 '.suppressedProperties == 0'
fixture '.changes[0].resourceId |= sub("applicationGateways"; "otherResource")'
run 'resource type mismatch' 0 '.suppressedProperties == 0'
fixture '.changes[0].delta[0].path = "tags.provisioningState"'
run 'path mismatch' 0 '.suppressedProperties == 0'
fixture '.changes[0].delta[0] = {path:"properties.provisioningState", propertyChangeType:"Delete", before:{state:"Succeeded"}, children:[{path:"state",propertyChangeType:"NoEffect",before:"Succeeded"}]}'
run 'structural deletion preserved' 0 '.reviewProperties == 1 and .suppressedProperties == 0'

cp "$tmp/empty-config.json" "$tmp/config.json"
fixture '.changes[0].delta = [{path:"properties.listeners",propertyChangeType:"Array",children:[{path:"0",propertyChangeType:"Modify",children:[{path:"properties.provisioningState",propertyChangeType:"NoEffect",before:"Succeeded"},{path:"properties.port",propertyChangeType:"Modify",before:80,after:443}]}]}]'
run 'nested array leaf filtering' 0 '.reviewProperties == 1 and .suppressedProperties == 1'
[[ $(cat "$tmp/report.md") == *'properties.listeners&#91;0&#93;.properties.port'* ]]
fixture '.changes[0].delta[0].before = "<script>|[link](bad)\n`value`"'
run 'Markdown escaped' 0 '.reviewProperties == 1'
[[ $(cat "$tmp/report.md") != *'<script>'* ]]
fixture '.changes[0].delta[0] = {path:"properties.flag",propertyChangeType:"Modify",before:false,after:null}'
run 'false and explicit null preserved' 0 '.reviewProperties == 1'
[[ $(cat "$tmp/report.md") == *'false | null'* ]]
fixture '.changes[0].delta[0] = {path:"properties.flag",propertyChangeType:"Modify",before:false}'
run 'missing value uncertain' 3 '.unknownProperties == 1'
fixture '.changes[0].delta[0].propertyChangeType = "FutureType"'
run 'future property kind uncertain' 3 '.unknownProperties == 1'
jq '.unexpectedOption = true' "$repo/what-really-if.json" > "$tmp/config.json"
run 'config typos rejected' 2 ''
jq '.rules[0].pathRegex = "["' "$repo/what-really-if.json" > "$tmp/config.json"
run 'invalid rule regex' 2 ''
jq '.rules[0].pathRegex = "^[$"' "$repo/what-really-if.json" > "$tmp/config.json"
run 'anchored invalid regex rejected' 2 ''
cp "$tmp/empty-config.json" "$tmp/config.json"
fixture '.changes[0].changeType = "Create" | del(.changes[0].delta, .changes[0].after)'
run 'resource create missing payload' 3 '.unknownResources == 1 and .hasReviewChanges'
fixture '.changes[0].delta[0] = {path:"properties.listeners",propertyChangeType:"Array",children:[]}'
run 'array without nested details uncertain' 3 '.unknownProperties == 1'
fixture '.changes[0].unsupportedReason = "Provider cannot evaluate"'
run 'unsupported reason retained' 3 '.unknownResources == 1'
fixture '.changes[0].delta[0].propertyChangeType = "NoEffect"'
jq '.suppressNoEffect = false' "$repo/what-really-if.json" > "$tmp/config.json"
run 'explicit opt-out of NoEffect suppression' 0 '.reviewProperties == 1 and .suppressedProperties == 0'
cp "$tmp/empty-config.json" "$tmp/config.json"
fixture '.'
# Protect the captured evidence from accidental output aliases.
alias_status=0
render --input "$tmp/input.json" --output "$tmp/./input.json" \
  2> "$tmp/stderr" || alias_status=$?
[[ "$alias_status" == 2 ]]
jq -e '.status == "Succeeded"' "$tmp/input.json" >/dev/null
count=$((count + 1))

# The catalogue records independently researched read-only schema paths. Exercise
# every supported version, including child resource IDs and indexed components.
cp "$repo/what-really-if.json" "$tmp/config.json"
jq '{status:"Succeeded",changes:[.rules[] | . as $rule | .apiVersions[] |
    . as $version | ($rule.resourceType | split("/")) as $type |
    {resourceId:("/subscriptions/s/resourceGroups/rg/providers/" + $type[0] + "/" +
      ([range(1; $type | length) as $i | $type[$i] + "/fixture"] | join("/"))),
     changeType:"Modify",before:{apiVersion:$version},after:{apiVersion:$version},
     delta:[$rule.paths[] | {path:gsub("\\[\\]"; "[3]"),propertyChangeType:"Delete",before:"service-generated"}]}]}' \
  "$repo/tests/fixtures/safe-default-paths.json" > "$tmp/defaults.json"
expected_paths=$(jq '[.changes[].delta | length] | add' "$tmp/defaults.json")
cp "$tmp/defaults.json" "$tmp/input.json"
run 'all researched default paths and versions' 0 \
  ".suppressedProperties == $expected_paths and .reviewProperties == 0 and .hasUnknown == false"
jq '.changes[].delta[] |= (.propertyChangeType = "Modify" | .after = "different")' \
  "$tmp/defaults.json" > "$tmp/input.json"
run 'metadata modifications remain visible' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[].after.apiVersion = "2099-01-01"' "$tmp/defaults.json" > "$tmp/input.json"
run 'unresearched versions remain visible' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[] |= (del(.before.apiVersion, .after.apiVersion))' "$tmp/defaults.json" > "$tmp/input.json"
run 'missing versions remain visible' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[].delta[].before = {provisioningState:"Succeeded"}' "$tmp/defaults.json" > "$tmp/input.json"
run 'objects cannot match default metadata rules' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[].delta[].before = ["generated"]' "$tmp/defaults.json" > "$tmp/input.json"
run 'arrays cannot match default metadata rules' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[].delta[].path |= ("tags." + .)' "$tmp/defaults.json" > "$tmp/input.json"
run 'metadata names in other locations remain visible' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[].delta[] |= (.propertyChangeType = "Create" | .after = .before | del(.before))' \
  "$tmp/defaults.json" > "$tmp/input.json"
run 'metadata creation remains visible' 0 ".suppressedProperties == 0 and .reviewProperties == $expected_paths"
jq '.changes[].delta[] |= (.propertyChangeType = "Modify" | .after = "[reference(\u0027resource\u0027)]")' \
  "$tmp/defaults.json" > "$tmp/input.json"
run 'expressions cannot be hidden by default rules' 3 ".suppressedProperties == 0 and .unknownProperties == $expected_paths"
jq '.changes[] |= (.changeType = "Delete" | del(.delta))' "$tmp/defaults.json" > "$tmp/input.json"
run 'resource deletions cannot be hidden by default rules' 0 '.hasReviewChanges and .suppressedProperties == 0'
fixture '.changes[0].delta = [{path:"properties.httpListeners",propertyChangeType:"Array",children:[{path:"0",propertyChangeType:"Modify",children:[{path:"properties.provisioningState",propertyChangeType:"Delete",before:"Succeeded"},{path:"properties.frontendPort.id",propertyChangeType:"Modify",before:"/ports/80",after:"/ports/443"}]}]}]'
run 'App Gateway nested metadata leaves real port change visible' 0 '.suppressedProperties == 1 and .reviewProperties == 1 and .hasReviewChanges'
fixture '.changes[0].delta = [{path:"properties.httpListeners",propertyChangeType:"Array",children:[{path:"0",propertyChangeType:"Delete",before:{name:"listener",properties:{provisioningState:"Succeeded"}},children:[{path:"properties.provisioningState",propertyChangeType:"Delete",before:"Succeeded"}]}]}]'
run 'listener removal remains visible with default rules' 0 '.suppressedProperties == 0 and .reviewProperties == 1'
fixture '.changes[0].delta[0] = {path:"properties.backendAddressPool.id",propertyChangeType:"Delete",before:"/pools/important"}'
run 'resource references remain visible' 0 '.suppressedProperties == 0 and .reviewProperties == 1'
fixture '.changes[0].resourceId |= sub("Microsoft.Network/applicationGateways"; "Microsoft.Storage/storageAccounts") | .changes[0].after.apiVersion = "2024-01-01" | .changes[0].delta[0] = {path:"properties.accessTier",propertyChangeType:"Delete",before:"Cool"}'
run 'writable storage access tier remains visible' 0 '.suppressedProperties == 0 and .reviewProperties == 1'
fixture '.changes[0].resourceId |= sub("Microsoft.Network/applicationGateways"; "Microsoft.Storage/storageAccounts") | .changes[0].after.apiVersion = "2024-01-01" | .changes[0].delta[0] = {path:"properties.networkAcls.defaultAction",propertyChangeType:"Delete",before:"Deny"}'
run 'writable storage network rules remain visible' 0 '.suppressedProperties == 0 and .reviewProperties == 1'

# Platform entry points must preserve argument boundaries and UTF-8 text.
fixture '.changes[0].delta[0] = {path:"tags.Owner",propertyChangeType:"Delete",before:"Müller"}'
mkdir -p "$tmp/path with spaces ü"
cp "$tmp/input.json" "$tmp/path with spaces ü/input [preview].json"
cp "$tmp/config.json" "$tmp/path with spaces ü/project config.json"
render --input "$tmp/path with spaces ü/input [preview].json" \
  --output "$tmp/path with spaces ü/report [preview].md" \
  --config "$tmp/path with spaces ü/project config.json" \
  --summary-file "$tmp/path with spaces ü/summary [preview].json" \
  --title 'Déploiement "quoted" $literal <script>'
jq -e '.reviewProperties == 1 and .hasUnknown == false' "$tmp/path with spaces ü/summary [preview].json" >/dev/null
[[ $(cat "$tmp/path with spaces ü/report [preview].md") == *'Déploiement "quoted" $literal &lt;script&gt;'* ]]
[[ $(cat "$tmp/path with spaces ü/report [preview].md") == *'Müller'* ]]
count=$((count + 1))
printf 'Passed %s regression fixtures.\n' "$count"
