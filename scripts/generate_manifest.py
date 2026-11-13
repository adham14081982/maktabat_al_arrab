#!/usr/bin/env python3
"""
Generate a manifest file listing all book JSON files for Flutter asset bundling.

Flutter requires all asset files to be listed in pubspec.yaml or referenced
via a manifest. This script scans the assets directory for *.json files
(book JSONs) and creates a manifest that the app can use to discover them.

Usage:
  python generate_manifest.py --assets-dir ./assets
"""

import argparse
import json
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets-dir", default="./assets", help="Assets directory")
    args = parser.parse_args()

    assets_dir = Path(args.assets_dir)
    if not assets_dir.exists():
        print(f"ERROR: Directory not found: {assets_dir}")
        return

    # Find all book JSON files (exclude library.json)
    json_files = sorted([
        f.name for f in assets_dir.iterdir()
        if f.suffix == '.json' and f.name != 'library.json'
    ])

    manifest = {
        "version": "1.0.0",
        "book_count": len(json_files),
        "json_files": json_files,
    }

    manifest_path = assets_dir / "book_jsons_manifest.json"
    with open(manifest_path, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    print(f"Generated manifest: {manifest_path}")
    print(f"Book JSON files: {len(json_files)}")


if __name__ == "__main__":
    main()
