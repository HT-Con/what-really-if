# Reusable What-If mocks

These are **synthetic examples**, researched against Microsoft's published
contracts on 2026-11-19. They are not recordings of live Azure deployments.
Names, subscription IDs, GUIDs and timestamps are fictional. They contain no
credentials. The three README PNGs are screenshots of the actual renderer's
Markdown for the cases marked `preview` in [manifest.json](manifest.json).

The goal is contract-correct, internally consistent test data. Schema-valid
JSON cannot guarantee that Azure will produce an identical prediction for a
particular deployment: provider behavior, service defaults and analysis coverage
can vary. The unsupported reason is deliberately authored fixture text, not an
exact service diagnostic. No deployment or live provider validation was run.

## Cases

| Input | Shape / format | Scenario | Expected renderer exit |
|---|---|---|---:|
| [planned-changes.json](planned-changes.json) | CLI / FullResourcePayloads | Create a user-assigned identity; change storage public blob access and an owner tag | 0 |
| [metadata-noise.json](metadata-noise.json) | REST / FullResourcePayloads | Exact VNet metadata Delete deltas, suppressed by bundled defaults | 0 |
| [unknown-effects.json](unknown-effects.json) | CLI / FullResourcePayloads | A storage tag contains the unresolved `[utcNow()]` expression | 3 |
| [complete-mode-delete.json](complete-mode-delete.json) | REST / FullResourcePayloads | Existing user-assigned identity omitted from a complete-mode deployment | 0 |
| [resource-id-only.json](resource-id-only.json) | CLI / ResourceIdOnly | Deploy with no property payload or delta; effects remain unknown | 3 |
| [nested-array.json](nested-array.json) | CLI / FullResourcePayloads | Indexed modification of a VNet address prefix | 0 |
| [unsupported.json](unsupported.json) | CLI / FullResourcePayloads | Role assignment ID depends on an unresolved identity reference | 3 |
| Same input + [acknowledged.config.json](acknowledged.config.json) | CLI / FullResourcePayloads | Explicitly acknowledge that specific resource expression and reason | 0 |

Exit `0` can include changes requiring approval. The mode and result format are
scenario metadata in the manifest, not invented fields in the response JSON.
The complete-mode fixture documents ARM behavior; it is not a recommendation to
use complete mode for Bicep deployments.

## Research and modeling decisions

- **Wire contract:** ARM deployments API `2025-04-01` defines the two change-type
  enums, recursive property deltas, optional snapshots, and REST
  `properties.changes`. Its flattening annotation explains the CLI `changes`
  shape. The fixture validator checks the subset used here, not the complete
  extensible-resource or error schema.
  [REST specification](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/resources/resource-manager/Microsoft.Resources/deployments/stable/2025-04-01/deployments.json)
- **Create and Modify payloads:** Microsoft's resource-group What-If example
  includes identity creation and a tag delta with snapshots. Our identity has
  fictional values and uses a researched current identity API version.
  [Official response example](https://github.com/Azure/azure-rest-api-specs/blob/main/specification/resources/resource-manager/Microsoft.Resources/deployments/stable/2025-04-01/examples/PostDeploymentWhatIfOnResourceGroup.json),
  [identity 2024-11-30 resource reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.managedidentity/2024-11-30/userassignedidentities)
- **Resource kinds and property types:** Storage uses `StorageV2`, `Standard_LRS`,
  boolean `allowBlobPublicAccess`, string-valued tags, and explicitly configured
  `TLS1_2`. The preview changes public blob access, not network reachability or
  existing container ACLs.
  [Storage 2025-01-01 resource reference](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2025-01-01/storageaccounts)
- **Metadata noise:** VNet `etag`, `properties.provisioningState` and
  `properties.resourceGuid` are response metadata. The snapshots differ exactly
  at those three paths. Their reported Delete deltas describe What-If's comparison
  with the desired payload, not an assertion that Azure deletes the metadata.
  The existing schema catalogue pins the independently researched network paths.
  [Pinned network schema](https://github.com/Azure/azure-rest-api-specs/blob/11e80d03105672056f0c2af1f1d67d71606672d7/specification/network/resource-manager/Microsoft.Network/Network/stable/2025-01-01/virtualNetwork.json),
  [local catalogue](../fixtures/safe-default-paths.json)
- **Unknown effects and formats:** Microsoft documents unresolved `utcNow()` tag
  values, complete-mode resource Delete, and Deploy with `ResourceIdOnly`.
  Therefore the unknown preview uses a full-payload Modify, and Deploy lives in
  its own ID-only fixture. `NoEffect` is a property change kind, not a resource
  change kind in the REST enum. Unsupported entries use the REST-defined kind
  and explanation field; their actual diagnostic wording is service dependent.
  [What-If behavior, formats and unevaluated expressions](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if)

## Validate and reuse

From the repository root:

```bash
# Standard library only: check the researched fixture contract and consistency.
python3 tests/validate-mocks.py

# Render every mock through the selected wrapper and verify expected outcomes.
bash tests/test-what-really-if.sh
WHAT_REALLY_IF_RUNNER=powershell bash tests/test-what-really-if.sh

# Render one mock. A successful operation can still produce renderer exit 3.
./what-really-if.sh \
  --input tests/mocks/planned-changes.json \
  --output /tmp/whatif-preview.md \
  --summary-file /tmp/whatif-preview-summary.json
```

The fixture validator checks allowed field names/enums, envelopes, IDs,
resource names/types/API versions, CIDR alignment, mode/format compatibility,
and the correspondence between snapshots and every delta value. It also checks
that Modify snapshots have no unexplained differences. It is intentionally
stricter than the Azure schema for these authored examples and is not a general
validator for arbitrary Azure output.

During creation, all seven unique inputs also passed an offline deserialize /
serialize round-trip through the official Azure Python SDK's
`WhatIfOperationResult` model (resources API `2022-09-01`; the fields used here
also exist in the researched deployments API `2025-04-01`). This verifies the
wire mapping without claiming live provider validation.

The shell regression harness checks the expected exit codes and independent
summary counts recorded in the manifest. Both wrappers share those expectations.
When adding a mock, add a manifest entry and run both validation commands.

## Regenerate the PNGs

Optional documentation dependencies: Python 3.9+, the `Markdown` package
(`python3 -m pip install Markdown` in your development environment), Bash, jq,
and Chrome or Chromium. Normal renderer tests do not require these screenshot
dependencies. You can use a virtual environment for Python packages.

```bash
python3 tests/render-previews.py
# Or choose a browser explicitly:
python3 tests/render-previews.py --chrome /path/to/chromium
```

The script validates fixtures, invokes the real Bash renderer, verifies the
expected exit/summary, converts that Markdown to HTML with local styling in
[preview.css](../preview.css), and screenshots the complete reports at 2×
resolution. Only the metadata preview's suppression disclosure is expanded;
full-ID disclosures remain closed. The context strip labels the synthetic
fixture, envelope, format, and actual exit code. Fonts and browser versions may
change rasterization. These are locally styled Markdown previews, not screenshots
of Azure DevOps or GitHub's hosting UI. No remote assets are fetched.
