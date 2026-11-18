# jq 1.6 compatible. Classify first; render from the classified records.
def require($condition; $message):
  if $condition then . else error($message) end;
def nonempty_string: type == "string" and length > 0;
def scalar: type != "object" and type != "array";
def validate_config:
  require(type == "object"; "Config must be an object")
  | require((keys - ["$comment", "version", "suppressNoEffect", "maxValueLength", "rules"] | length) == 0; "Unknown config field")
  | require(.version == 1; "Config version must be 1")
  | require((.suppressNoEffect | type) == "boolean"; "suppressNoEffect must be boolean")
  | require((.maxValueLength | type) == "number"; "maxValueLength must be numeric")
  | require(.maxValueLength >= 40 and .maxValueLength <= 10000 and (.maxValueLength | floor) == .maxValueLength; "maxValueLength must be an integer from 40 to 10000")
  | require((.rules | type) == "array"; "rules must be an array")
  | .rules |= map(
      require(type == "object"; "Each rule must be an object")
      | require((keys - ["id", "enabled", "resourceType", "pathRegex", "changeTypes", "reason", "apiVersions", "beforeEquals", "afterEquals"] | length) == 0; "Unknown rule field")
      | require((.id | nonempty_string) and (.reason | nonempty_string); "Rules need id and reason")
      | require((.enabled | type) == "boolean"; "Rules need boolean enabled")
      | require((.resourceType | nonempty_string); "Rules need resourceType")
      | require((.resourceType | contains("*")) == false; "resourceType must be exact, without wildcards")
      | require((.pathRegex | nonempty_string); "Rules need pathRegex")
      | require((.pathRegex | startswith("^") and endswith("$")); "pathRegex must be anchored with ^ and $")
      | .pathRegex as $regex | ("" | test($regex)) as $compiled
      | require((.changeTypes | type) == "array"; "changeTypes must be an array")
      | require((.changeTypes | length) > 0 and all(.changeTypes[]; . == "Create" or . == "Modify" or . == "Delete"); "Invalid changeTypes")
      | require((has("apiVersions") | not) or ((.apiVersions | type) == "array" and (.apiVersions | length) > 0 and all(.apiVersions[]; nonempty_string)); "apiVersions must be a nonempty string array")
    )
  | require(([.rules[].id] | length) == ([.rules[].id] | unique | length); "Rule ids must be unique");

def resource_info:
  . as $r | ($r.resourceId | split("/")) as $parts
  | ([$parts | to_entries[] | select(.value | ascii_downcase == "providers") | .key] | last) as $provider
  | (if $provider != null then $parts[($provider + 1):] else [] end) as $tail
  | {
      resourceId: $r.resourceId,
      resourceType: (if ($tail | length) >= 3 then
        ([$tail[0]] + [range(1; $tail | length; 2) as $i | $tail[$i]]) | join("/")
        else ($r.after.type // $r.before.type // "Unknown") end),
      apiVersion: ($r.after.apiVersion // $r.before.apiVersion // null)
    };

def join_path($parent; $segment):
  ($segment | tostring) as $s
  | if $parent == "" then $s
    elif $s | test("^[0-9]+$") then $parent + "[" + $s + "]"
    elif $s | startswith("[") then $parent + $s
    elif $s == $parent or ($s | startswith($parent + ".")) or ($s | startswith($parent + "[")) then $s
    else $parent + "." + $s end;

# Never discard structural Create/Delete nodes by replacing them with children.
def flatten($prefix):
  .[] | . as $d
  | if type != "object" then error("Delta entry must be an object") else . end
  | require((.path | type) == "string" and (.path | length) > 0; "Delta entry needs a nonempty path")
  | require(.children == null or (.children | type) == "array"; "Delta children must be an array")
  | join_path($prefix; .path) as $path
  | if (.propertyChangeType == "Array" or .propertyChangeType == "Modify") and ((.children // []) | length) > 0
    then .children | flatten($path)
    else $d + {path: $path} end;

def expression_present: any(.. | strings; test("^\\[.*\\]$"; "s"));
def noise_rule($cfg; $info):
  . as $p | first($cfg.rules[]
    | select(.enabled)
    | select((.resourceType | ascii_downcase) == ($info.resourceType | ascii_downcase))
    | select(.changeTypes | index($p.propertyChangeType))
    | select(.pathRegex as $regex | $p.path | test($regex))
    | select((has("apiVersions") | not) or (.apiVersions | index($info.apiVersion)))
    | select((has("beforeEquals") | not) or .beforeEquals == $p.before)
    | select((has("afterEquals") | not) or .afterEquals == $p.after)
    | select(($p.before | scalar) and ($p.after | scalar))
  ) // null;

def classify_property($cfg; $info):
  . as $p
  | if .propertyChangeType == "NoEffect" and $cfg.suppressNoEffect then
      . + {classification: "noise", reason: "Azure reports NoEffect", ruleId: "builtin-no-effect"}
    elif .propertyChangeType == "NoEffect" then
      . + {classification: "review", reason: "Azure reports NoEffect; suppression disabled"}
    elif (["Create", "Delete", "Modify"] | index($p.propertyChangeType)) == null then
      . + {classification: "unknown", reason: "Missing, unsupported, or incomplete property change type"}
    elif ((.propertyChangeType == "Create" and (has("after") | not))
        or (.propertyChangeType == "Delete" and (has("before") | not))
        or (.propertyChangeType == "Modify" and ((has("before") and has("after")) | not))) then
      . + {classification: "unknown", reason: "Missing expected before/after value"}
    elif ([.before, .after] | expression_present) then
      . + {classification: "unknown", reason: "Possible unresolved expression; deployment effect cannot be established"}
    else noise_rule($cfg; $info) as $rule
      | if $rule != null then . + {classification: "noise", reason: $rule.reason, ruleId: $rule.id}
        else . + {classification: "review", reason: "Predicted change"} end
    end;

def classify_resource($cfg):
  . as $r | resource_info as $info
  | (if .delta == null then [] else .delta end) as $delta
  | require(($delta | type) == "array"; "Resource delta must be an array")
  | ([ $delta | flatten("") | classify_property($cfg; $info) ]) as $properties
  | $info + {changeType: $r.changeType, properties: $properties,
      before: $r.before, after: $r.after,
      issues: [
        if ($r.unsupportedReason // "") != "" then $r.unsupportedReason else empty end,
        if $r.changeType == "Ignore" then "Ignore: outside-template resource or analysis limit; coverage cannot be established from this entry alone" else empty end,
        if $r.changeType == "Deploy" then "Deploy: resource will be redeployed but property effects are unknown" else empty end,
        if $r.changeType == "Create" and ($r.after | type) != "object" then "Create without an after resource payload" else empty end,
        if $r.changeType == "Delete" and ($r.before | type) != "object" then "Delete without a before resource payload" else empty end,
        if $r.changeType == "Modify" and ($properties | length) == 0 then "Modify without property details" else empty end,
        if (["Create", "Delete", "Modify", "NoChange", "Ignore", "Deploy"] | index($r.changeType)) == null then "Unsupported resource change type" else empty end,
        if ($r.changeType == "Create" or $r.changeType == "Delete") and
           ([$r.before, $r.after] | expression_present) then "Resource payload contains possible unresolved expressions" else empty end
      ]}
  | .classification = (if (.issues | length) > 0 or any(.properties[]; .classification == "unknown") then "unknown"
      elif .changeType == "Create" or .changeType == "Delete" or any(.properties[]; .classification == "review") then "review"
      elif .changeType == "NoChange" then "unchanged" else "noise" end);

# HTML-encode user-controlled text inside Markdown; never emit raw HTML from input.
def escape: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
  | gsub("\r\n|\r|\n"; " ") | gsub("\\|"; "&#124;")
  | gsub("`"; "&#96;") | gsub("\\*"; "&#42;") | gsub("_"; "&#95;")
  | gsub("\\["; "&#91;") | gsub("\\]"; "&#93;") | gsub("\\\\"; "&#92;");
def cell($max):
  tojson | if length > $max then .[0:$max] + " … [truncated; see raw JSON]" else . end | escape;
def value_cell($key; $max): if has($key) then .[$key] | cell($max) else "—" end;

def render($cfg; $title; $summary; $resources; $diagnostics):
  ["# " + ($title | escape), "",
   "**" + ($summary.reviewResources | tostring) + " resources to review · "
     + ($summary.unknownResources | tostring) + " resources with unknown effects · "
     + ($summary.suppressedProperties | tostring) + " suppressed property differences**", "",
   (if $summary.hasUnknown then "**Review required: unknown effects or reported analysis gaps are present.**"
    elif $summary.reviewResources == 0 then "No unsuppressed changes reported. No analysis gaps reported."
    else "Predicted changes are listed below for approval review." end), "",
   "This is a filtered prediction, not a guarantee of deployment effects. Keep the original JSON alongside this report.", "",
   "| Create | Delete | Modify | Deploy | Ignore | NoChange |",
   "|---:|---:|---:|---:|---:|---:|",
   "| " + (["Create", "Delete", "Modify", "Deploy", "Ignore", "NoChange"] | map(. as $kind | [$resources[] | select(.changeType == $kind)] | length | tostring) | join(" | ")) + " |", "",
   (if ($summary.analysisIssues | length) > 0 then
     "## Analysis issues", "", ($summary.analysisIssues[] | "- " + (. | escape)), "" else empty end),
   ($resources[] | select(.classification == "review" or .classification == "unknown") |
     "## " + (.changeType | escape) + " — " + (.resourceId | escape), "",
     "Classification: **" + .classification + "** · Type: " + (.resourceType | escape)
       + " · API: " + ((.apiVersion // "not provided") | escape), "",
     (.issues[] | "- " + (. | escape)),
     (if .changeType == "Create" or .changeType == "Delete" then
       "", "| Payload | Value |", "|---|---|",
       "| " + (if .changeType == "Create" then "After" else "Before" end) + " | "
         + (if .changeType == "Create" then .after else .before end | cell($cfg.maxValueLength)) + " |", ""
       else empty end),
     (if any(.properties[]; .classification != "noise") then
       "", "| Class | Change | Property | Before | After | Reason |", "|---|---|---|---|---|---|",
       (.properties[] | select(.classification != "noise") |
         "| " + .classification + " | " + (.propertyChangeType | escape) + " | " + (.path | escape)
         + " | " + value_cell("before"; $cfg.maxValueLength) + " | " + value_cell("after"; $cfg.maxValueLength)
         + " | " + (.reason | escape) + " |"), "" else empty end), ""),
   (if ($diagnostics | length) > 0 then
     "## Azure diagnostics", "", ($diagnostics[] | "- " + (tojson | escape)), "" else empty end),
   (if $summary.suppressedProperties > 0 then
     "<details>", "<summary>Suppressed differences — all matched paths and rules</summary>", "",
     "| Resource | Property | Change | Before | After | Rule | Reason |", "|---|---|---|---|---|---|---|",
     ($resources[] | .resourceId as $id | .properties[] | select(.classification == "noise") |
       "| " + ($id | escape) + " | " + (.path | escape) + " | " + (.propertyChangeType | escape)
       + " | " + value_cell("before"; $cfg.maxValueLength) + " | " + value_cell("after"; $cfg.maxValueLength)
       + " | " + (.ruleId | escape) + " | " + (.reason | escape) + " |"), "", "</details>", "" else empty end)
  ] | join("\n");

require(length == 1; "Input must contain exactly one JSON document") | .[0]
| require(type == "object"; "Input must be a JSON object")
| require(($config | length) == 1; "Config must contain exactly one JSON document")
| ($config[0] | validate_config) as $cfg
| . as $raw
| (if has("changes") then . else .properties end) as $root
| require($raw.error == null and $root.error == null; "What-if returned an error")
| ($raw.status // $root.status // null) as $status
| require($status == null or $status == "Succeeded"; "What-if operation did not succeed")
| require(($root | type) == "object" and ($root.changes | type) == "array"; "Input needs a changes array (flat or under properties)")
| require($root.diagnostics == null or ($root.diagnostics | type) == "array"; "diagnostics must be an array")
| require($root.potentialChanges == null or ($root.potentialChanges | type) == "array"; "potentialChanges must be an array")
| ($root.diagnostics // []) as $diagnostics
| [$root.changes[]
    | require(type == "object"; "Resource change must be an object")
    | require((.resourceId | nonempty_string); "Resource change needs resourceId")
    | classify_resource($cfg)] | sort_by(.resourceId) as $resources
| [if $status == null then "Operation status missing; successful analysis cannot be verified" else empty end,
   if ($root.potentialChanges // [] | length) > 0 then
     "Potential changes were reported: " + ($root.potentialChanges | tojson) else empty end,
   ($diagnostics[] | select((.level // "" | ascii_downcase) != "info") | "Diagnostic requiring review: " + tojson)
  ] as $issues
| {
    version: 1, operationStatus: $status,
    reviewResources: ([$resources[] | select(.classification == "review")] | length),
    unknownResources: ([$resources[] | select(.classification == "unknown")] | length),
    noiseOnlyResources: ([$resources[] | select(.classification == "noise")] | length),
    unchangedResources: ([$resources[] | select(.classification == "unchanged")] | length),
    reviewProperties: ([$resources[].properties[] | select(.classification == "review")] | length),
    unknownProperties: ([$resources[].properties[] | select(.classification == "unknown")] | length),
    suppressedProperties: ([$resources[].properties[] | select(.classification == "noise")] | length),
    analysisIssues: $issues,
    hasUnknown: (($issues | length) > 0 or any($resources[]; .classification == "unknown")),
    hasReviewChanges: any($resources[]; .classification == "review" or .changeType == "Create" or .changeType == "Delete" or any(.properties[]; .classification == "review"))
  } as $summary
| {summary: $summary,
   markdown: render($cfg; $title; $summary; $resources; $diagnostics),
   exitCode: (if $summary.hasUnknown then 3 else 0 end)}
