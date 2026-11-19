# jq 1.6 compatible. Classify first; render from the classified records.
def require($condition; $message):
  if $condition then . else error($message) end;
def nonempty_string: type == "string" and length > 0;
def scalar: type != "object" and type != "array";
def validate_config:
  require(type == "object"; "Config must be an object")
  | require((keys - ["$comment", "version", "suppressNoEffect", "maxValueLength", "rules", "acknowledgeUnsupported"] | length) == 0; "Unknown config field")
  | if has("acknowledgeUnsupported") then . else .acknowledgeUnsupported = [] end
  | require((.acknowledgeUnsupported | type) == "array"; "acknowledgeUnsupported must be an array")
  | .acknowledgeUnsupported |= map(
      require(type == "object"; "Each acknowledgeUnsupported entry must be an object")
      | require((keys - ["id", "enabled", "resourceIdRegex", "unsupportedReasonRegex", "reason"] | length) == 0; "Unknown acknowledgeUnsupported field")
      | require((.id | nonempty_string) and (.reason | nonempty_string); "acknowledgeUnsupported entries need id and reason")
      | require((.enabled | type) == "boolean"; "acknowledgeUnsupported entries need boolean enabled")
      | require((.resourceIdRegex | nonempty_string); "acknowledgeUnsupported entries need resourceIdRegex")
      | .resourceIdRegex as $regex | ("" | test($regex)) as $compiled
      | require((has("unsupportedReasonRegex") | not) or (.unsupportedReasonRegex | nonempty_string); "unsupportedReasonRegex must be a nonempty string")
      | if has("unsupportedReasonRegex") then .unsupportedReasonRegex as $regex | ("" | test($regex)) as $compiled | . else . end
    )
  | require(([.acknowledgeUnsupported[].id] | length) == ([.acknowledgeUnsupported[].id] | unique | length); "acknowledgeUnsupported ids must be unique")
  | require(.version == 1; "Config version must be 1")
  | require((.suppressNoEffect | type) == "boolean"; "suppressNoEffect must be boolean")
  | require((.maxValueLength | type) == "number"; "maxValueLength must be numeric")
  | require(.maxValueLength >= 40 and .maxValueLength <= 10000 and (.maxValueLength | floor) == .maxValueLength; "maxValueLength must be an integer from 40 to 10000")
  | require((.rules | type) == "array"; "rules must be an array")
  | .rules |= map(
      require(type == "object"; "Each rule must be an object")
      | require((keys - ["id", "enabled", "resourceType", "pathRegex", "changeTypes", "reason", "apiVersions", "beforeEquals", "afterEquals", "beforeIn", "allowStructural"] | length) == 0; "Unknown rule field")
      | require((has("allowStructural") | not) or ((.allowStructural | type) == "boolean"); "allowStructural must be boolean")
      | require((has("beforeIn") | not) or ((.beforeIn | type) == "array" and (.beforeIn | length) > 0); "beforeIn must be a nonempty array")
      | require(((has("beforeIn") and has("beforeEquals")) | not); "Use beforeIn or beforeEquals, not both")
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

# Project rules precede inherited rules; a project id replaces the inherited id,
# including when disabled. Validate each list before merging so duplicates fail.
def resolve_config($defaults):
  require(type == "object"; "Config must be an object")
  | if has("extends") then
      require(.extends == "default"; "extends must be default")
      | require(($defaults | length) == 1; "Defaults must contain exactly one JSON document")
      | . as $project
      | ($defaults[0] | validate_config) as $base
      | ($base + ($project | del(.extends)) | validate_config) as $checked
      | $checked + {
          rules: ($checked.rules + [$base.rules[] | .id as $id | select(any($checked.rules[]; .id == $id) | not)]),
          acknowledgeUnsupported: ($checked.acknowledgeUnsupported + [$base.acknowledgeUnsupported[] | .id as $id | select(any($checked.acknowledgeUnsupported[]; .id == $id) | not)])
        }
      # Omitted lists already contain the base list; avoid duplicating them.
      | validate_config
    else validate_config end;

# Split only the outer resourceId arguments. Quoted strings (including doubled
# apostrophes) are atomic; nested calls/arrays never contribute type candidates.
def arm_arguments:
  . as $body
  | [scan("'(?:[^']|'')*'|[^']")]
  | (join("") == $body) as $complete
  | reduce .[] as $token ({args: [], current: "", stack: [], valid: $complete};
      if ($token | startswith("'")) then .current += $token
      elif $token == "(" or $token == "[" then .stack += [$token] | .current += $token
      elif $token == ")" or $token == "]" then
        .valid = (.valid and (.stack[-1] == (if $token == ")" then "(" else "[" end)))
        | .stack = .stack[:-1] | .current += $token
      elif $token == "," and (.stack | length) == 0 then .args += [.current] | .current = ""
      else .current += $token end)
  | if .valid and (.stack | length) == 0 then .args + [.current] | map(gsub("^\\s+|\\s+$"; "")) else [] end;
def arm_literal:
  if test("^'(?:[^']|'')*'$"; "s") then .[1:-1] | gsub("''"; "'") else null end;
def expression_info:
  ([capture("^\\[\\s*resourceId\\s*\\((?<body>.*)\\)\\s*\\]$"; "is")][0].body // "")
  | arm_arguments as $args
  | ([$args | to_entries[] | select(.key <= 2) | (.value | arm_literal) as $literal
      | select($literal != null) | select($literal | test("^[A-Za-z0-9]+\\.[A-Za-z0-9.]+/[A-Za-z0-9/]+$"))][0]) as $type
  | {type: (if $type then $type.value | arm_literal else null end),
     rg: (if $type and $type.key > 0 then $args[$type.key - 1] | arm_literal else null end)};

def resource_info:
  . as $r
  | if ($r.resourceId | startswith("[")) then
      ($r.resourceId | expression_info) as $m
      | ([($r.unsupportedReason // "") | match("resources\\.([A-Za-z0-9_]+)\\.properties\\.template\\.resources\\["; "g") | .captures[0].string] | last) as $symbol
      | {
          resourceId: $r.resourceId,
          resourceType: ($m.type // $r.after.type // $r.before.type // "Unknown"),
          name: ($symbol // "(name not known until deployment)"),
          resourceGroup: ($m.rg // null),
          apiVersion: ($r.after.apiVersion // $r.before.apiVersion // null)
        }
    else
      ($r.resourceId | split("/")) as $parts
      | ([$parts | to_entries[] | select(.value | ascii_downcase == "providers") | .key] | last) as $provider
      | (if $provider != null then $parts[($provider + 1):] else [] end) as $tail
      | ([$parts | to_entries[] | select(.value | ascii_downcase == "resourcegroups") | .key] | first) as $rgIndex
      | {
          resourceId: $r.resourceId,
          resourceType: (if ($tail | length) >= 3 then
            ([$tail[0]] + [range(1; $tail | length; 2) as $i | $tail[$i]]) | join("/")
            elif $provider == null and $rgIndex != null then "Microsoft.Resources/resourceGroups"
            else ($r.after.type // $r.before.type // "Unknown") end),
          name: (if ($tail | length) >= 3 then [range(2; $tail | length; 2) as $i | $tail[$i]] | join("/")
                 else ($parts | last) end),
          resourceGroup: (if $rgIndex != null then $parts[$rgIndex + 1] else null end),
          apiVersion: ($r.after.apiVersion // $r.before.apiVersion // null)
        }
    end;

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
    | select((has("beforeIn") | not) or any(.beforeIn[]; . == $p.before))
    | select((has("afterEquals") | not) or .afterEquals == $p.after)
    | select(.allowStructural == true or (($p.before | scalar) and ($p.after | scalar)))
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
  | (if $r.changeType == "Unsupported" then
      [$cfg.acknowledgeUnsupported[] | select(.enabled) | select(.resourceIdRegex as $regex | $r.resourceId | test($regex))
       | select((has("unsupportedReasonRegex") | not) or (.unsupportedReasonRegex as $regex | ($r.unsupportedReason // "") | test($regex))) ] | .[0]
     else null end) as $ack
  | .acknowledged = $ack
  | .classification = (if $ack != null and (any(.properties[]; .classification == "unknown" or .classification == "review") | not) then "acknowledged"
      elif (.issues | length) > 0 or any(.properties[]; .classification == "unknown") then "unknown"
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

# Strings without JSON quotes; everything else as compact JSON.
def vcell($max):
  (if type == "string" then . else tojson end)
  | if length > $max then .[0:$max] + " … [truncated; see raw JSON]" else . end | escape;
def vcell_of($key; $max): if has($key) then .[$key] | vcell($max) else "—" end;

def change_icon: {"Create": "➕", "Delete": "➖", "Modify": "✏️", "Deploy": "🔁", "Unsupported": "❔", "Ignore": "⏭️", "NoChange": "·"}[.] // "•";
def short_type: split("/") | if length > 1 then .[1:] | join("/") else join("/") end;
def res_meta: (.resourceType | short_type | escape)
  + (if .resourceGroup then " · RG " + (.resourceGroup | escape) else "" end)
  + (if .apiVersion then " · API " + (.apiVersion | escape) else "" end);

# Resource payload as property rows; properties.* expanded one level, ARM identity fields dropped.
def payload_rows($max):
  (if type == "object" then . else {} end)
  | del(.apiVersion, .id, .name, .type, .resourceGroup, .subscriptionId, .scope)
  | to_entries[]
  | if .key == "properties" and (.value | type) == "object"
    then .value | to_entries[] | {k: ("properties." + .key), v: .value}
    else {k: .key, v: .value} end
  | "| " + (.k | escape) + " | " + (.v | vcell($max)) + " |";

def render_resource($cfg):
  "#### " + (.changeType | change_icon) + " " + (.changeType | escape) + " · " + (.name | escape), "",
  res_meta, "",
  "<details>", "<summary>Full resource ID</summary>", "", (.resourceId | escape), "", "</details>", "",
  (if (.issues | length) > 0 and .classification != "review" then (.issues[] | "- " + (. | escape)), "" else empty end),
  (if .changeType == "Create" or .changeType == "Delete" then
     (if .changeType == "Create" then .after else .before end) as $payload
     | ([$payload | payload_rows($cfg.maxValueLength)]) as $rows
     | if ($rows | length) > 0 then "| Property | " + (if .changeType == "Create" then "Value" else "Current value" end) + " |", "|---|---|", $rows[], "" else empty end
   else empty end),
  (if any(.properties[]; .classification != "noise") then
     "| Change | Property | Before | After | Reason |", "|---|---|---|---|---|",
     (.properties[] | select(.classification != "noise") |
       "| " + (.propertyChangeType | change_icon) + (if .classification == "unknown" then " ❔" else "" end)
       + " | " + (.path | escape)
       + " | " + vcell_of("before"; $cfg.maxValueLength) + " | " + vcell_of("after"; $cfg.maxValueLength) + " | " + (.reason | escape) + " |"),
     "" else empty end);

def render($cfg; $title; $summary; $resources; $diagnostics):
  [$resources[] | select(.classification == "review")] as $review
  | [$resources[] | select(.classification == "unknown")] as $unknown
  | [$resources[] | select(.classification == "acknowledged")] as $acknowledged
  | [$resources[] | select(any(.properties[]; .classification == "noise"))] as $noisy
  | ["# " + ($title | escape), "",
     (if $summary.hasUnknown then "⚠️ **Review required:** unknown effects or analysis gaps are present (see below)."
      elif ($review | length) == 0 then "✅ **No unacknowledged changes to review.** See acknowledged resources and suppressed differences below, when present."
      else "📝 **" + ($review | length | tostring) + " resource(s) with changes to review.**" end), "",
     "| ➕ Create | ✏️ Modify | ➖ Delete | ❔ Unknown | ☑️ Acknowledged | 🔇 Noise only |",
     "|:-:|:-:|:-:|:-:|:-:|:-:|",
     "| " + ([
        ([$review[] | select(.changeType == "Create")] | length),
        ([$review[] | select(.changeType == "Modify" or .changeType == "Deploy")] | length),
        ([$review[] | select(.changeType == "Delete")] | length),
        ($unknown | length), ($acknowledged | length), $summary.noiseOnlyResources
       ] | map(tostring) | join(" | ")) + " |", "",
     (if ($review | length) > 0 then
        "---", "", "## 📝 Changes to review", "", ($review[] | render_resource($cfg)) else empty end),
     (if ($unknown | length) > 0 then
        "---", "", "## ❔ Unknown effects", "",
        "What-if could not fully evaluate these. Check them manually, or acknowledge known cases in the rules file.", "",
        ($unknown[] | render_resource($cfg)) else empty end),
     (if ($summary.analysisIssues | length) > 0 or ($diagnostics | length) > 0 then
        "---", "", "## ⚠️ Analysis issues", "",
        ($summary.analysisIssues[] | "- " + (. | escape)),
        ($diagnostics[] | "- " + (tojson | escape)), "" else empty end),
     "---", "",
     (if ($acknowledged | length) > 0 then
        "<details>", "<summary>☑️ Acknowledged, not evaluated by what-if (" + ($acknowledged | length | tostring) + ")</summary>", "",
        "| Resource ID | Type | Resource group | Original issue | Rule | Acknowledged because |", "|---|---|---|---|---|---|",
        ($acknowledged[] | "| " + (.resourceId | escape) + " | " + (.resourceType | short_type | escape) + " | "
          + ((.resourceGroup // "—") | escape) + " | " + (.issues | join("; ") | escape) + " | " + (.acknowledged.id | escape) + " | " + (.acknowledged.reason | escape) + " |"),
        "", "</details>", "" else empty end),
     (if $summary.suppressedProperties > 0 then
        "<details>", "<summary>🔇 Suppressed noise (" + ($summary.suppressedProperties | tostring) + " properties on "
          + ($noisy | length | tostring) + " resources)</summary>", "",
        "| Resource ID | Property | Change | Before | After | Rule | Reason |", "|---|---|---|---|---|---|---|",
        ($noisy[] | .resourceId as $name | .properties[] | select(.classification == "noise") |
          "| " + ($name | escape) + " | " + (.path | escape) + " | " + (.propertyChangeType | escape)
          + " | " + vcell_of("before"; $cfg.maxValueLength) + " | " + vcell_of("after"; $cfg.maxValueLength)
          + " | " + (.ruleId | escape) + " | " + (.reason | escape) + " |"), "", "</details>", "" else empty end),
     "_Filtered what-if prediction, not a guarantee of deployment effects. Keep the original JSON alongside this report._"
    ] | join("\n");

require(length == 1; "Input must contain exactly one JSON document") | .[0]
| require(type == "object"; "Input must be a JSON object")
| require(($config | length) == 1; "Config must contain exactly one JSON document")
| ($config[0] | resolve_config($defaults)) as $cfg
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
    acknowledgedResources: ([$resources[] | select(.classification == "acknowledged")] | length),
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
