# what-really-if

Bicep What-If can turn a one-line change into the complete autobiography of your
Application Gateway. Add a few more resources and reading the preview becomes a
full-day job.

**what-really-if** turns that output into readable Markdown for deployment
approvals, filtering known metadata noise and flagging changes Azure couldn't
evaluate.

## Requirements

- [jq](https://jqlang.org/) 1.6+ on `PATH`.
- Bash or PowerShell 7.2+.
- Azure CLI to capture the preview; rendering works offline.

Clone or download this repository. Keep your chosen script, `what-really-if.jq`,
and `what-really-if.json` in the same directory. Both scripts use the same engine
and rules.

## Usage

### Bash

```bash
set -euo pipefail

az deployment group what-if \
  --resource-group my-rg \
  --template-file main.bicep \
  --parameters @parameters.json \
  --no-pretty-print \
  --result-format FullResourcePayloads > whatif.json

./what-really-if.sh \
  --input whatif.json \
  --output whatif.md \
  --summary-file whatif-summary.json
```

### PowerShell

```powershell
az deployment group what-if `
  --resource-group my-rg `
  --template-file main.bicep `
  --parameters '@parameters.json' `
  --no-pretty-print `
  --result-format FullResourcePayloads |
    Set-Content -LiteralPath whatif.json -Encoding utf8NoBOM

if ($LASTEXITCODE -ne 0) { throw 'Azure What-If failed.' }

./what-really-if.ps1 `
  -InputFile whatif.json `
  -OutputFile whatif.md `
  -SummaryFile whatif-summary.json
```

Use `sub`, `mg`, or `tenant` instead of `group` for other deployment scopes.
Existing Azure CLI or REST JSON results are also accepted.

| Option | Bash | PowerShell |
|---|---|---|
| Custom rules | `--config project-rules.json` | `-ConfigFile project-rules.json` |
| Report title | `--title 'My deployment'` | `-Title 'My deployment'` |
| Optional JSON summary | `--summary-file summary.json` | `-SummaryFile summary.json` |
| Help | `--help` | `-Help` |

## Filtering

- **Suppressed:** explicit `NoEffect` changes and scalar metadata deletions at
  verified paths on supported resource types and API versions.
- **Visible:** resource creates/deletes, configuration changes, structural
  object/array changes, and differences without a matching rule.
- **Flagged for review:** possible unresolved expressions, incomplete analysis,
  unsupported results, and missing expected details. `Ignore` and `Deploy`
  entries are handled conservatively.

The enabled defaults cover selected metadata on Azure networking resources
(including nested Application Gateway components), storage accounts, and
user-assigned managed identities. See the [rules](what-really-if.json) and
[path catalogue](tests/fixtures/safe-default-paths.json) for exact paths,
API versions, and pinned Microsoft specification sources. Missing or unlisted
API versions do not match the metadata rules.

Every suppressed difference remains in a collapsible section with its rule and
reason. Long values are truncated; keep the raw JSON for full details. What-If
remains a prediction, and filtering cannot resolve unknown deployment effects.

## Configuration

Edit `what-really-if.json`, or pass a project-specific copy. Each rule requires:

- A unique `id`, boolean `enabled`, and explanatory `reason`.
- An exact `resourceType`, anchored `pathRegex`, and `changeTypes` array.

Optional `apiVersions`, `beforeEquals`, and `afterEquals` narrow the match.
Resource types match case-insensitively; paths and string values are
case-sensitive. The first matching enabled rule wins. Array paths use numeric
indexes, such as `properties.httpListeners[0].properties.provisioningState`.

Set a rule's `enabled` to `false` to disable it. Set `rules` to `[]` to remove
metadata suppressions while retaining explicit `NoEffect` handling.

## Pipeline integration

| Exit code | Meaning |
|---|---|
| `0` | Report generated without unknown effects or reported analysis gaps. May contain changes requiring approval. |
| `2` | Invalid input/configuration, unsuccessful What-If operation, or rendering failure. |
| `3` | Report generated with unknown effects or analysis gaps requiring review. |

Publish the Markdown, raw JSON, and optional summary on codes `0` and `3`.
On code `2`, do not publish an older report left at the output path. With Bash
`set -e`, capture the renderer's status using `report_status=0` followed by
`./what-really-if.sh ... || report_status=$?`. In PowerShell, save `$LASTEXITCODE`
immediately after invoking the script.

The JSON summary provides counts, `hasReviewChanges`, `hasUnknown`, and global
`analysisIssues`. Exit code `0` is not deployment approval. Deploy the same
artifact, parameters, scope, and mode used for the preview.

## Tests

```bash
bash tests/test-what-really-if.sh
WHAT_REALLY_IF_RUNNER=powershell bash tests/test-what-really-if.sh
```

The test harness requires Bash and jq; the second command also requires `pwsh`.
Tests use captured JSON fixtures and do not perform live Azure deployments.
