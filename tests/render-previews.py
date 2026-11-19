#!/usr/bin/env python3
"""Render actual reports from tested mocks and screenshot them using local Chrome.

Optional documentation tooling: Python-Markdown and Chrome/Chromium are needed.
No Azure access, external fonts, or image-generation service is used.
"""
import argparse
import html
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

try:
    import markdown
except ImportError:
    raise SystemExit('Install Python-Markdown first: python3 -m pip install Markdown')

REPO = Path(__file__).resolve().parent.parent
MOCKS = REPO / 'tests/mocks'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chrome', help='Chrome/Chromium executable')
    parser.add_argument('--output', type=Path, default=REPO / 'docs/images')
    args = parser.parse_args()
    chrome = args.chrome or next((shutil.which(name) for name in ['google-chrome', 'chromium', 'chromium-browser'] if shutil.which(name)), None)
    if not chrome:
        raise SystemExit('Chrome/Chromium is required; use --chrome PATH')
    args.output.mkdir(parents=True, exist_ok=True)
    css = (REPO / 'tests/preview.css').read_text(encoding='utf-8')
    cases = json.loads((MOCKS / 'manifest.json').read_text(encoding='utf-8'))['cases']
    subprocess.run([shutil.which('python3') or 'python3', str(REPO / 'tests/validate-mocks.py')], check=True)
    with tempfile.TemporaryDirectory(prefix='what-really-if-previews-') as temporary:
        work = Path(temporary)
        for case in cases:
            if not case.get('preview'):
                continue
            report = work / (case['id'] + '.md')
            summary_path = work / (case['id'] + '.summary.json')
            command = ['bash', str(REPO / 'what-really-if.sh'), '--input', str(MOCKS / case.get('input', case['id'] + '.json')), '--output', str(report), '--summary-file', str(summary_path), '--title', case['title']]
            if case.get('config'):
                command += ['--config', str(MOCKS / case['config'])]
            result = subprocess.run(command, cwd=REPO, capture_output=True, text=True)
            if result.returncode != case['exitCode']:
                raise RuntimeError(f'{case["id"]}: unexpected exit {result.returncode}: {result.stderr}')
            summary = json.loads(summary_path.read_text(encoding='utf-8'))
            for key, expected in case['summary'].items():
                if summary[key] != expected:
                    raise RuntimeError(f'{case["id"]}: {key} is {summary[key]}, expected {expected}')
            # GitHub parses Markdown inside details. Enable the same behavior for
            # Python-Markdown; open only the noise disclosure for its screenshot.
            source = report.read_text(encoding='utf-8')
            source = source.replace('<details>\n<summary>🔇', '<details open markdown="1">\n<summary>🔇')
            source = source.replace('<details>', '<details markdown="1">')
            body = markdown.markdown(source, extensions=['tables', 'md_in_html'])
            context = f'Synthetic fixture · {case["format"]} · {case["resultFormat"]}'
            document = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><style>{css}</style></head><body>
<main><div class="context"><strong>{html.escape(context)}</strong><span>Renderer exit {result.returncode}</span></div><article>{body}</article></main>
<script>document.fonts.ready.then(() => {{document.body.dataset.height = Math.ceil(document.documentElement.scrollHeight);}});</script>
</body></html>'''
            page = work / (case['id'] + '.html')
            page.write_text(document, encoding='utf-8')
            common = [chrome, '--headless', '--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--hide-scrollbars', '--no-first-run', '--no-default-browser-check', f'--user-data-dir={work / "chrome-profile"}', '--force-device-scale-factor=2', '--virtual-time-budget=1000']
            dom = subprocess.run(common + ['--window-size=1224,800', '--dump-dom', page.as_uri()], check=True, capture_output=True, text=True).stdout
            match = re.search(r'data-height="(\d+)"', dom)
            if not match:
                raise RuntimeError('Chrome did not measure the rendered report height')
            # A full document screenshot without clipping any report content.
            height = int(match.group(1)) + 80
            image = (args.output / (case['id'] + '.png')).resolve()
            subprocess.run(common + [f'--window-size=1224,{height}', f'--screenshot={image}', page.as_uri()], check=True, capture_output=True)
            print(f'{case["id"]}: wrote {image.relative_to(REPO) if image.is_relative_to(REPO) else image}')


if __name__ == '__main__':
    main()
