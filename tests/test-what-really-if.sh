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
common_paths=$(jq '[.changes[].delta[] | select(.path | test("(^|\\.)(etag|provisioningState|resourceGuid)$"))] | length' "$tmp/defaults.json")
run 'common metadata matches unlisted versions' 0 ".suppressedProperties == $common_paths and .reviewProperties == ($expected_paths - $common_paths)"
jq '.changes[] |= (del(.before.apiVersion, .after.apiVersion))' "$tmp/defaults.json" > "$tmp/input.json"
run 'common metadata matches missing versions' 0 ".suppressedProperties == $common_paths and .reviewProperties == ($expected_paths - $common_paths)"
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

# Opt-in structural suppression still checks values and unresolved expressions.
jq '.rules = [{id:"children",enabled:true,resourceType:"Microsoft.Network/applicationGateways",pathRegex:"^properties.listeners$",changeTypes:["Delete"],reason:"Parent view of separately deployed children",allowStructural:true}]' "$tmp/empty-config.json" > "$tmp/config.json"
fixture '.changes[0].delta = [{path:"properties.listeners",propertyChangeType:"Delete",before:[{name:"child"}]}]'
run 'structural opt-in suppresses arrays' 0 '.suppressedProperties == 1'
[[ $(cat "$tmp/report.md") == *'Parent view of separately deployed children'* ]]
jq '.rules[0].allowStructural = false' "$tmp/config.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/config.json"
run 'structural opt-out preserves arrays' 0 '.suppressedProperties == 0 and .reviewProperties == 1'
jq '.rules[0].allowStructural = true | .rules[0].beforeEquals = {name:"child"}' "$tmp/config.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/config.json"
run 'structural value mismatch stays visible' 0 '.reviewProperties == 1'
fixture '.changes[0].delta = [{path:"properties.listeners",propertyChangeType:"Delete",before:{name:"child"}}]'
run 'structural objects can match exact value' 0 '.suppressedProperties == 1'
fixture '.changes[0].delta = [{path:"properties.listeners",propertyChangeType:"Delete",before:{id:"[reference(\u0027child\u0027)]"}}]'
run 'structural rules cannot suppress expressions' 3 '.unknownProperties == 1 and .suppressedProperties == 0'
jq '.rules[0].allowStructural = "yes"' "$tmp/config.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/config.json"
run 'invalid structural flag rejected' 2 ''

# beforeIn compares complete JSON values, preserving false/null and types.
jq '.rules = [{id:"defaults",enabled:true,resourceType:"Microsoft.Network/applicationGateways",pathRegex:"^properties.flag$",changeTypes:["Delete"],reason:"Known service default",beforeIn:[false,null,"Regional",0]}]' "$tmp/empty-config.json" > "$tmp/config.json"
for value in false null '"Regional"' 0; do
  jq --argjson value "$value" '.changes[0].delta = [{path:"properties.flag",propertyChangeType:"Delete",before:$value}]' "$tmp/base.json" > "$tmp/input.json"
  run "beforeIn matches $value" 0 '.suppressedProperties == 1'
done
fixture '.changes[0].delta = [{path:"properties.flag",propertyChangeType:"Delete",before:"false"}]'
run 'beforeIn type mismatch stays visible' 0 '.reviewProperties == 1'
for value in '[]' 'false' 'null'; do
  jq --argjson value "$value" '.rules[0].beforeIn = $value' "$tmp/config.json" > "$tmp/next.json"
  cp "$tmp/config.json" "$tmp/saved.json"
  mv "$tmp/next.json" "$tmp/config.json"
  run "invalid beforeIn $value" 2 ''
  mv "$tmp/saved.json" "$tmp/config.json"
done
jq '.rules[0].beforeEquals = false' "$tmp/config.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/config.json"
run 'ambiguous before constraints rejected' 2 ''

jq '.rules = [{id:"object-default",enabled:true,resourceType:"Microsoft.Network/applicationGateways",pathRegex:"^properties.flag$",changeTypes:["Delete"],reason:"Exact default object",allowStructural:true,beforeIn:[{enabled:false},["default"]]}]' "$tmp/empty-config.json" > "$tmp/config.json"
fixture '.changes[0].delta = [{path:"properties.flag",propertyChangeType:"Delete",before:{enabled:false}}]'
run 'beforeIn matches whole object with structural opt-in' 0 '.suppressedProperties == 1'
fixture '.changes[0].delta = [{path:"properties.flag",propertyChangeType:"Delete",before:["default","extra"]}]'
run 'beforeIn rejects partial array match' 0 '.reviewProperties == 1'

# Parse only literal outer resourceId arguments, never nested reference IDs.
cp "$tmp/empty-config.json" "$tmp/config.json"
for expression in \
  "[resourceId('Microsoft.Authorization/roleAssignments', guid(reference('/providers/Microsoft.Compute/virtualMachines/vm').id))]" \
  "[resourceId('rg', 'Microsoft.Authorization/roleAssignments', 'name')]" \
  "[resourceId('sub', 'rg', 'Microsoft.Authorization/roleAssignments', 'name')]" \
  "[resourceId(subscription().subscriptionId, resourceGroup().name, 'Microsoft.Authorization/roleAssignments', guid('a,b', 'it''s'))]"; do
  jq --arg id "$expression" '.changes = [{resourceId:$id,changeType:"Unsupported",unsupportedReason:"Cannot evaluate reference"}]' "$tmp/base.json" > "$tmp/input.json"
  run 'outer expression type' 3 '.unknownResources == 1'
  [[ $(cat "$tmp/report.md") == *$'\nroleAssignments'* ]]
done
for expression in \
  "[resourceId(variables('type'), reference(resourceId('Microsoft.Compute/virtualMachines', 'vm')).id)]" \
  "[concat(resourceId('Microsoft.Compute/virtualMachines', 'vm'), '/providers/other')]" \
  "[resourceId('Microsoft.Authorization/roleAssignments', broken(]) ]"; do
  jq --arg id "$expression" '.changes = [{resourceId:$id,changeType:"Unsupported"}]' "$tmp/base.json" > "$tmp/input.json"
  run 'uncertain expression type stays unknown' 3 '.unknownResources == 1'
  [[ $(cat "$tmp/report.md") == *$'\nUnknown'* ]]
done

# Acknowledgements only cover the specified known failure. New gaps still fail.
jq '.compactReport = true | .acknowledgeUnsupported = [{id:"known",enabled:true,resourceIdRegex:"^/known$",unsupportedReasonRegex:"^Known limitation$",reason:"Reviewed upstream limitation"}]' "$tmp/empty-config.json" > "$tmp/config.json"
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"Known limitation"}]'
run 'known unsupported acknowledged' 0 '.acknowledgedResources == 1 and .unknownResources == 0 and (.hasUnknown | not)'
[[ $(cat "$tmp/report.md") == *'Known limitation'* ]]
[[ $(cat "$tmp/report.md") == *'Reviewed upstream limitation'* ]]
[[ $(cat "$tmp/report.md") == *'| Resource | Type | Resource group | Acknowledged because |'* ]]
[[ $(cat "$tmp/report.md") == *'| known | Unknown | — | Reviewed upstream limitation |'* ]]
[[ $(cat "$tmp/report.md") == *'known · acknowledgement details'* ]]
[[ $(cat "$tmp/report.md") == *'/known'* ]]
[[ $(cat "$tmp/report.md") != *'Everything reported by what-if was classified as noise'* ]]
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"Known limitation"}] | .diagnostics = [{level:"Warning",message:"Independent analysis gap"}]'
run 'acknowledgement preserves independent diagnostics' 3 '.acknowledgedResources == 1 and .hasUnknown'
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"Known limitation"},{resourceId:"/new",changeType:"Unsupported",unsupportedReason:"New gap"}]'
run 'new unsupported alongside acknowledged still fails' 3 '.acknowledgedResources == 1 and .unknownResources == 1'
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"New failure"}]'
run 'new unsupported reason requires review' 3 '.acknowledgedResources == 0 and .unknownResources == 1'
fixture '.changes = [{resourceId:"/new",changeType:"Unsupported",unsupportedReason:"Known limitation"}]'
run 'new unsupported resource requires review' 3 '.unknownResources == 1'
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"Known limitation",delta:[{path:"property",propertyChangeType:"Modify",before:"a"}]}]'
run 'acknowledgement cannot hide incomplete property details' 3 '.unknownProperties == 1 and .acknowledgedResources == 0'
jq '.acknowledgeUnsupported[0].enabled = false' "$tmp/config.json" > "$tmp/next.json"
mv "$tmp/next.json" "$tmp/config.json"
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"Known limitation"}]'
run 'disabled acknowledgement does not match' 3 '.unknownResources == 1'
for mutation in 'del(.acknowledgeUnsupported[0].reason)' '.acknowledgeUnsupported[0].unsupportedReasonRegex = "["' '.acknowledgeUnsupported[0].unsupportedReasonRegex = ""' '.acknowledgeUnsupported += .acknowledgeUnsupported' '.acknowledgeUnsupported = false'; do
  jq "$mutation" "$tmp/config.json" > "$tmp/next.json"
  cp "$tmp/config.json" "$tmp/saved.json"
  mv "$tmp/next.json" "$tmp/config.json"
  run "invalid acknowledgement: $mutation" 2 ''
  mv "$tmp/saved.json" "$tmp/config.json"
done

# Extend defaults without copying them. Project ids replace inherited ids.
printf '%s\n' '{"extends":"default"}' > "$tmp/config.json"
fixture '.'
run 'minimal project inherits defaults' 0 '.suppressedProperties == 1'
printf '%s\n' '{"extends":"default","rules":[]}' > "$tmp/config.json"
run 'empty project list retains inherited rules' 0 '.suppressedProperties == 1'
jq '{extends:"default",rules:[.rules[0] | .enabled = false]}' "$repo/what-really-if.json" > "$tmp/config.json"
run 'project can disable inherited rule by id' 0 '.reviewProperties == 1 and .suppressedProperties == 0'
jq '{extends:"default",rules:[.rules[0] | .id = "project-first" | .reason = "Project takes precedence"]}' "$repo/what-really-if.json" > "$tmp/config.json"
run 'project rules precede defaults' 0 '.suppressedProperties == 1'
[[ $(cat "$tmp/report.md") == *'Project takes precedence'* ]]
for config_json in '{"extends":"other"}' '{"extends":"default","rules":null}' '{"extends":"default","unexpected":true}'; do
  printf '%s\n' "$config_json" > "$tmp/config.json"
  run "invalid inheritance: $config_json" 2 ''
done
jq '{extends:"default",rules:[.rules[0],.rules[0]]}' "$repo/what-really-if.json" > "$tmp/config.json"
run 'duplicate project ids rejected before merge' 2 ''

# Report details preserve identity and the cause of uncertainty.
cp "$tmp/empty-config.json" "$tmp/config.json"
fixture '.changes[0].delta = [{path:"properties.flag",propertyChangeType:"Modify",before:false}]'
run 'unknown property explanation rendered' 3 '.unknownProperties == 1'
[[ $(cat "$tmp/report.md") == *'Missing expected before/after value'* ]]
[[ $(cat "$tmp/report.md") == *'/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/applicationGateways/gw'* ]]
fixture '.changes[0].changeType = "Create" | .changes[0].after = {name:"gw",type:"Microsoft.Network/applicationGateways",location:"westeurope",properties:{flag:false}} | del(.changes[0].delta)'
run 'create payload is property rows' 0 '.reviewResources == 1'
[[ $(cat "$tmp/report.md") == *'| properties.flag | false |'* ]]
[[ $(cat "$tmp/report.md") != *'Full raw output is in the pipeline artifact'* ]]

# Compact tables keep audit context available in disclosures.
jq '.compactReport = true' "$tmp/empty-config.json" > "$tmp/config.json"
fixture '.changes[0].delta = [{path:"tags.Owner",propertyChangeType:"Modify",before:"Alice",after:"Bob"},{path:"properties.flag",propertyChangeType:"Modify",before:false}]'
run 'compact property table retains unknown explanation' 3 '.reviewProperties == 1 and .unknownProperties == 1'
[[ $(cat "$tmp/report.md") == *'| | Property | Before | After |'* ]]
[[ $(cat "$tmp/report.md") == *'<summary>Property explanations</summary>'* ]]
[[ $(cat "$tmp/report.md") == *'Missing expected before/after value'* ]]

fixture '.changes[0].delta = [{path:"tags.Owner",propertyChangeType:"Modify",before:"Alice",after:"Bob"},{path:"properties.flag",propertyChangeType:"NoEffect",before:false,after:false}]'
run 'suppressed NoEffect does not create empty property explanation' 0 '.reviewProperties == 1 and .suppressedProperties == 1'
[[ $(cat "$tmp/report.md") != *'<summary>Property explanations</summary>'* ]]

fixture '.changes[0].delta = [{path:"properties.note",propertyChangeType:"NoEffect",before:("x" * 150),after:("x" * 150)}]'
run 'compact noise table truncates values and retains full identity' 0 '.suppressedProperties == 1'
[[ $(cat "$tmp/report.md") == *'| gw | rg | properties.note | NoEffect |'* ]]
[[ $(cat "$tmp/report.md") == *'&#91;truncated; see raw JSON&#93;'* ]]
[[ $(cat "$tmp/report.md") != *$(printf 'x%.0s' {1..121})* ]]
[[ $(cat "$tmp/report.md") == *'<summary>Suppression details</summary>'* ]]
[[ $(cat "$tmp/report.md") == *'/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/applicationGateways/gw'* ]]
[[ $(cat "$tmp/report.md") == *'Azure reports NoEffect'* ]]

# Resource groups distinguish identical short names in the noise table.
fixture '.changes[0].delta[0].propertyChangeType = "NoEffect" | .changes += [.changes[0] | .resourceId |= sub("/resourceGroups/rg/"; "/resourceGroups/rg-other/")]'
run 'noise table distinguishes names across resource groups' 0 '.noiseOnlyResources == 2 and .suppressedProperties == 2'
[[ $(cat "$tmp/report.md") == *'| Resource | Resource group | Property | Change | Before | After | Rule |'* ]]
[[ $(cat "$tmp/report.md") == *'| gw | rg | properties.provisioningState | NoEffect |'* ]]
[[ $(cat "$tmp/report.md") == *'| gw | rg-other | properties.provisioningState | NoEffect |'* ]]

fixture '.changes[0].resourceId = "/providers/Microsoft.Network/applicationGateways/gw" | .changes[0].delta[0].propertyChangeType = "NoEffect"'
run 'noise table handles resources without a resource group' 0 '.noiseOnlyResources == 1'
[[ $(cat "$tmp/report.md") == *'| gw | — | properties.provisioningState | NoEffect |'* ]]

fixture '.changes[0].resourceId |= sub("/resourceGroups/rg/"; "/resourceGroups/rg<test>|/") | .changes[0].delta[0].propertyChangeType = "NoEffect"'
run 'noise table escapes resource group text' 0 '.noiseOnlyResources == 1'
[[ $(cat "$tmp/report.md") == *'| rg&lt;test&gt;&#124; |'* ]]

# Compact layout is opt-in; omitted and explicit false use full IDs and reasons.
fixture '.changes[0].delta[0].propertyChangeType = "NoEffect"'
for layout_config in 'del(.compactReport)' '.compactReport = false'; do
  jq "$layout_config" "$tmp/empty-config.json" > "$tmp/config.json"
  run "full report layout: $layout_config" 0 '.noiseOnlyResources == 1'
  [[ $(cat "$tmp/report.md") == *'| Resource ID | Property | Change | Before | After | Rule | Reason |'* ]]
  [[ $(cat "$tmp/report.md") == *'| /subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/applicationGateways/gw |'* ]]
done
fixture '.'
run 'default property table includes reasons' 0 '.reviewProperties == 1'
[[ $(cat "$tmp/report.md") == *'| Change | Property | Before | After | Reason |'* ]]
fixture '.changes = [{resourceId:"/known",changeType:"Unsupported",unsupportedReason:"Known limitation"}]'
jq '.acknowledgeUnsupported = [{id:"known",enabled:true,resourceIdRegex:"^/known$",reason:"Reviewed separately"}]' "$tmp/empty-config.json" > "$tmp/config.json"
run 'default acknowledged table includes full identity and reason' 0 '.acknowledgedResources == 1'
[[ $(cat "$tmp/report.md") == *'| Resource ID | Type | Resource group | Original issue | Rule | Acknowledged because |'* ]]
[[ $(cat "$tmp/report.md") == *'| /known | Unknown | — | Known limitation;'* ]]
for invalid_layout in null '"true"' 1 '[]' '{}'; do
  jq --argjson layout "$invalid_layout" '.compactReport = $layout' "$tmp/empty-config.json" > "$tmp/config.json"
  run "invalid compactReport: $invalid_layout" 2 ''
done
printf '%s\n' '{"extends":"default","compactReport":true}' > "$tmp/config.json"
fixture '.'
run 'inherited defaults allow compact layout opt-in' 0 '.suppressedProperties == 1'
[[ $(cat "$tmp/report.md") == *'| Resource | Resource group | Property | Change | Before | After | Rule |'* ]]
cp "$tmp/empty-config.json" "$tmp/config.json"

# Different spellings of future output paths must not publish over each other.
fixture '.'
alias_status=0
render --input "$tmp/input.json" --output "$tmp/new/report.md" \
  --summary-file "$tmp/new/./report.md" 2> "$tmp/stderr" || alias_status=$?
[[ "$alias_status" == 2 ]]
count=$((count + 1))
if [[ "${OSTYPE:-}" != msys* && "${OSTYPE:-}" != cygwin* ]]; then
  ln -s "$tmp/input.json" "$tmp/input-link.json"
  alias_status=0
  render --input "$tmp/input.json" --output "$tmp/input-link.json" 2> "$tmp/stderr" || alias_status=$?
  [[ "$alias_status" == 2 ]]
  count=$((count + 1))
fi

# Platform entry points must preserve argument boundaries and UTF-8 text.
fixture '.changes[0].delta[0] = {path:"tags.Owner",propertyChangeType:"Delete",before:"Müller"}'
# Native Windows jq under Git Bash may misdecode Unicode command-line paths.
# Keep spaces/brackets there and still verify Unicode report text everywhere.
path_label='path with spaces ü'
case "${OSTYPE:-}" in msys*|cygwin*) path_label='path with spaces' ;; esac
mkdir -p "$tmp/$path_label"
cp "$tmp/input.json" "$tmp/$path_label/input [preview].json"
cp "$tmp/config.json" "$tmp/$path_label/project config.json"
render --input "$tmp/$path_label/input [preview].json" \
  --output "$tmp/$path_label/report [preview].md" \
  --config "$tmp/$path_label/project config.json" \
  --summary-file "$tmp/$path_label/summary [preview].json" \
  --title 'Déploiement "quoted" $literal <script>'
jq -e '.reviewProperties == 1 and .hasUnknown == false' "$tmp/$path_label/summary [preview].json" >/dev/null
[[ $(cat "$tmp/$path_label/report [preview].md") == *'Déploiement "quoted" $literal &lt;script&gt;'* ]]
[[ $(cat "$tmp/$path_label/report [preview].md") == *'Müller'* ]]
count=$((count + 1))
# Reusable, researched documentation mocks use the same platform entry point.
while IFS= read -r mock_case; do
  mock_id=$(jq -r '.id' <<< "$mock_case")
  mock_input=$(jq -r '.input // (.id + ".json")' <<< "$mock_case")
  cp "$repo/tests/mocks/$mock_input" "$tmp/input.json"
  mock_config=$(jq -r '.config // empty' <<< "$mock_case")
  if [[ -n "$mock_config" ]]; then
    cp "$repo/tests/mocks/$mock_config" "$tmp/config.json"
  else
    cp "$repo/what-really-if.json" "$tmp/config.json"
  fi
  mock_expected=$(jq -c '.summary' <<< "$mock_case")
  run "documentation mock: $mock_id" "$(jq -r '.exitCode' <<< "$mock_case")" \
    ". as \$actual | $mock_expected | to_entries | all(.[]; \$actual[.key] == .value)"
done < <(jq -c '.cases[]' "$repo/tests/mocks/manifest.json")

printf 'Passed %s regression fixtures.\n' "$count"
