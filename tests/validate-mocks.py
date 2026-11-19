#!/usr/bin/env python3
"""Check the documented ARM result contract and consistency of synthetic fixtures.

Uses only the standard library. This is intentionally a fixture validator, not a
replacement for Azure template validation or a complete provider JSON schema.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent / 'mocks'
MISSING = object()
RESOURCE_TYPES = {
    'Microsoft.ManagedIdentity/userAssignedIdentities': '2024-11-30',
    'Microsoft.Storage/storageAccounts': '2025-01-01',
    'Microsoft.Network/virtualNetworks': '2025-01-01',
}
RESOURCE_CHANGES = {'Create', 'Delete', 'Modify', 'NoChange', 'Ignore', 'Deploy', 'Unsupported'}
PROPERTY_CHANGES = {'Create', 'Delete', 'Modify', 'Array', 'NoEffect'}


def check(condition, message):
    if not condition:
        raise ValueError(message)


def load(name):
    return json.loads((ROOT / name).read_text(encoding='utf-8'))


def segments(path):
    return [int(index) if index else name for name, index in re.findall(r'([^\.\[\]]+)|\[(\d+)\]', path)]


def lookup(snapshot, path):
    value = snapshot
    for segment in segments(path):
        if isinstance(value, dict) and segment in value:
            value = value[segment]
        elif isinstance(value, list) and isinstance(segment, int) and segment < len(value):
            value = value[segment]
        else:
            return MISSING
    return value


def equal(left, right):
    # Python otherwise considers False == 0; JSON value types must remain distinct.
    return type(left) is type(right) and left == right


def differences(before, after, prefix=''):
    if isinstance(before, dict) and isinstance(after, dict):
        for key in before.keys() | after.keys():
            path = f'{prefix}.{key}' if prefix else key
            yield from differences(before.get(key, MISSING), after.get(key, MISSING), path)
    elif isinstance(before, list) and isinstance(after, list) and len(before) == len(after):
        for index, (old, new) in enumerate(zip(before, after)):
            yield from differences(old, new, f'{prefix}[{index}]')
    elif not equal(before, after):
        yield prefix


def validate_delta(node, before, after, parent=''):
    check(isinstance(node, dict), 'Delta must be an object')
    check(set(node) <= {'path', 'propertyChangeType', 'before', 'after', 'children'}, 'Unknown delta field')
    check(isinstance(node.get('path'), str) and node['path'], 'Delta needs a path')
    kind = node.get('propertyChangeType')
    check(kind in PROPERTY_CHANGES, 'Invalid property change type')
    path = (f'{parent}[{node["path"]}]' if node['path'].isdigit() else f'{parent}.{node["path"]}') if parent else node['path']
    old, new = lookup(before, path), lookup(after, path)
    for key, value in [('before', old), ('after', new)]:
        if key in node:
            check(equal(node[key], value), f'{path}: delta {key} differs from snapshot')
    if kind == 'Create':
        check(old is MISSING and 'after' in node and new is not MISSING, f'{path}: invalid Create')
    elif kind == 'Delete':
        check(new is MISSING and 'before' in node and old is not MISSING, f'{path}: invalid Delete')
    elif kind == 'Modify':
        check('before' in node and 'after' in node and not equal(old, new), f'{path}: invalid Modify')
    elif kind == 'Array':
        check(isinstance(old, list) and isinstance(new, list) and node.get('children'), f'{path}: invalid Array')
    children = node.get('children', [])
    check(isinstance(children, list), 'children must be an array')
    if children:
        return [leaf for child in children for leaf in validate_delta(child, before, after, path)]
    return [path]


def validate_snapshot(snapshot, resource_id):
    check(isinstance(snapshot, dict), 'Snapshot must be an object')
    kind = snapshot.get('type')
    check(kind in RESOURCE_TYPES, 'Unresearched mock resource type')
    check(snapshot.get('apiVersion') == RESOURCE_TYPES[kind], 'Unexpected mock API version')
    check(snapshot.get('id') == resource_id, 'Snapshot/resource ID mismatch')
    check(resource_id.endswith('/providers/' + kind + '/' + snapshot['name']), 'Snapshot type/name mismatch')
    check(snapshot.get('location') == 'westeurope', 'Unexpected mock location')
    check(all(isinstance(value, str) for value in snapshot.get('tags', {}).values()), 'Tags must be strings')
    if kind == 'Microsoft.Storage/storageAccounts':
        check(re.fullmatch('[a-z0-9]{3,24}', snapshot['name']), 'Invalid storage account name')
        check(snapshot['kind'] == 'StorageV2' and snapshot['sku']['name'] == 'Standard_LRS', 'Invalid mock storage kind/SKU')
        check(type(snapshot['properties']['allowBlobPublicAccess']) is bool, 'Public access must be boolean')
        check(snapshot['properties']['minimumTlsVersion'] == 'TLS1_2', 'Unexpected TLS version')
    elif kind == 'Microsoft.Network/virtualNetworks':
        import ipaddress
        for prefix in snapshot['properties']['addressSpace']['addressPrefixes']:
            ipaddress.ip_network(prefix, strict=True)


def validate_case(case):
    raw = load(case.get('input', case['id'] + '.json'))
    check(raw.get('status') == 'Succeeded', 'Fixture is not a successful What-If operation')
    check(set(raw) <= {'status', 'properties', 'changes'}, 'Unknown result field')
    check(('properties' in raw) == (case['format'] == 'REST'), 'Wrong result envelope')
    root = raw['properties'] if case['format'] == 'REST' else raw
    check(isinstance(root.get('changes'), list), 'changes must be an array')
    check(case['resultFormat'] in {'FullResourcePayloads', 'ResourceIdOnly'}, 'Invalid result format')
    ids = []
    for change in root['changes']:
        check(set(change) <= {'resourceId', 'changeType', 'unsupportedReason', 'before', 'after', 'delta'}, 'Unknown resource change field')
        kind = change.get('changeType')
        check(kind in RESOURCE_CHANGES, 'Invalid resource change type')
        resource_id = change.get('resourceId')
        check(isinstance(resource_id, str) and resource_id, 'Missing resource ID')
        ids.append(resource_id)
        if not resource_id.startswith('['):
            check(re.fullmatch(r'/subscriptions/[0-9a-f-]{36}/resourceGroups/rg-preview/providers/[^/]+/[^/]+/[^/]+', resource_id), 'Invalid mock ARM ID')
        for key in ('before', 'after'):
            if key in change:
                validate_snapshot(change[key], resource_id)
        if kind == 'Deploy':
            check(case['resultFormat'] == 'ResourceIdOnly', 'Deploy requires ResourceIdOnly in these mocks')
            check(not any(key in change for key in ('before', 'after', 'delta')), 'ResourceIdOnly contains payloads')
        elif kind == 'Delete':
            check(case['mode'] == 'Complete' and 'before' in change and 'after' not in change, 'Resource Delete requires Complete mode')
        elif kind == 'Create':
            check('after' in change and 'before' not in change, 'Create snapshot mismatch')
        elif kind == 'Unsupported':
            check(isinstance(change.get('unsupportedReason'), str) and change['unsupportedReason'], 'Unsupported requires explanation')
        elif kind == 'Modify':
            check('before' in change and 'after' in change and change.get('delta'), 'Modify requires snapshots/delta')
            covered = [path for node in change['delta'] for path in validate_delta(node, change['before'], change['after'])]
            for path in differences(change['before'], change['after']):
                check(any(path == parent or path.startswith(parent + '.') or path.startswith(parent + '[') for parent in covered), f'Unreported snapshot change: {path}')
    check(len(ids) == len(set(ids)), 'Duplicate resource ID')


if __name__ == '__main__':
    cases = load('manifest.json')['cases']
    for case in cases:
        validate_case(case)
    print(f'Validated {len(cases)} mock scenarios: result contract, IDs, snapshots, deltas, modes and formats.')
