#!/usr/bin/env python3
"""Inventory Swift compiler stringsdata; optionally merge English source keys.

This is a compiler-extraction lower bound, not complete interface coverage.
Runtime String expressions, AppKit labels and generated errors need a separate
call-site audit. Message content and account/channel names remain verbatim.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import tempfile
import uuid


def source_hashes(source_root, project_root):
    return {str(p.relative_to(project_root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(source_root.rglob("*.swift"))}


def snapshot(directory, source_root, project_root):
    if directory.exists() and any(directory.iterdir()):
        raise ValueError("Extraction snapshot requires a fresh empty directory")
    directory.mkdir(parents=True, exist_ok=True)
    values = source_hashes(source_root.resolve(), project_root.resolve())
    if not values:
        raise ValueError("No native Swift sources to snapshot")
    context = {name: hashlib.sha256((project_root / name).read_bytes()).hexdigest()
               for name in ["Package.swift", "Package.resolved"] if (project_root / name).is_file()}
    (directory / ".source-snapshot.json").write_text(json.dumps({"version": 1, "id": str(uuid.uuid4()), "source_files": values, "context_files": context}, indent=2) + "\n")


def collect(build_root, directory, source_root):
    digest = hashlib.sha256((directory / ".source-snapshot.json").read_bytes()).hexdigest()
    if (build_root / ".native-localization-snapshot").read_text().strip() != digest:
        raise ValueError("Compiler build does not match the pre-build source snapshot")
    count = 0
    for path in build_root.rglob("*.stringsdata"):
        data = path.read_bytes()
        payload = json.loads(data)
        source = payload.get("source")
        if not isinstance(source, str):
            raise ValueError(f"Invalid compiler source in {path}")
        if not Path(source).resolve().is_relative_to(source_root.resolve()):
            continue
        # Keep differing outputs separate so inventory can reject conflicts.
        name = hashlib.sha256(source.encode()).hexdigest()[:24] + "-" + hashlib.sha256(data).hexdigest()[:16] + ".stringsdata"
        (directory / name).write_bytes(data)
        count += 1
    if not count:
        raise ValueError("Isolated compiler build emitted no native localization data")


def inventory(input_directory, source_root, project_root):
    grouped = {}
    inputs = {}
    source_root = source_root.resolve()
    project_root = project_root.resolve()
    snapshot_path = input_directory / ".source-snapshot.json"
    source_snapshot = json.loads(snapshot_path.read_bytes())
    if source_snapshot.get("version") != 1 or source_snapshot.get("source_files") != source_hashes(source_root, project_root):
        raise ValueError("Native source changed after the pre-build snapshot")
    context = {name: hashlib.sha256((project_root / name).read_bytes()).hexdigest()
               for name in ["Package.swift", "Package.resolved"] if (project_root / name).is_file()}
    if source_snapshot.get("context_files", {}) != context:
        raise ValueError("Package context changed after the pre-build snapshot")
    outputs = {}
    for path in sorted(input_directory.rglob("*.stringsdata")):
        data = path.read_bytes()
        payload = json.loads(data)
        if payload.get("version") != 1 or not isinstance(payload.get("source"), str) or not isinstance(payload.get("tables"), dict):
            raise ValueError(f"Unsupported compiler localization data: {path}")
        source = Path(payload["source"]).resolve()
        if not source.is_relative_to(source_root):
            continue
        relative = str(source.relative_to(project_root))
        digest = hashlib.sha256(data).hexdigest()
        if relative in outputs:
            if outputs[relative] != digest:
                raise ValueError(f"Conflicting compiler outputs for one source: {relative}")
            continue
        outputs[relative] = digest
        inputs[relative] = {"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                            "stringsdata_sha256": digest}
        for table, entries in payload["tables"].items():
            if not isinstance(table, str) or not isinstance(entries, list):
                raise ValueError(f"Invalid compiler localization table: {path}")
            for entry in entries:
                key = entry.get("key")
                location = entry.get("location", {})
                if not isinstance(key, str) or not isinstance(location, dict):
                    raise ValueError(f"Invalid compiler localization entry: {path}")
                if not key:
                    continue
                occurrence = {"source": relative, "line": location.get("startingLine"),
                              "column": location.get("startingColumn"), "comment": entry.get("comment", "")}
                if not isinstance(occurrence["line"], int) or not isinstance(occurrence["column"], int):
                    raise ValueError(f"Missing compiler source location: {path}")
                places = grouped.setdefault((table, key), [])
                if occurrence not in places:
                    places.append(occurrence)
    if not grouped:
        raise ValueError("No native localization keys were emitted")
    keys = [{"table": table, "key": key, "occurrences": sorted(places, key=lambda p: (p["source"], p["line"], p["column"]))}
            for (table, key), places in sorted(grouped.items())]
    return {"version": 1, "scope": "Compiler-extracted source keys only; not full localization coverage",
            "prebuild_source_snapshot_sha256": hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
            "source_snapshot_files": len(source_snapshot["source_files"]),
            "source_files": inputs, "unique_table_keys": len(keys),
            "occurrences": sum(len(item["occurrences"]) for item in keys), "keys": keys,
            "remaining_audit": ["Runtime String expressions and helper labels", "AppKit menus, alerts and accessibility strings",
                                "Model/transport error presentation", "Plural and formatted-string contracts",
                                "Complete translated catalogs and layout/switch/restart verification for all21 target locales"]}


def merge_english(path, result):
    existing = {}
    if path.exists():
        raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", "--", str(path)], check=True, capture_output=True)
        existing = json.loads(raw.stdout)
        if not isinstance(existing, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in existing.items()):
            raise ValueError("Invalid existing English source catalog")
    for item in result["keys"]:
        if item["table"] == "Localizable":
            existing.setdefault(item["key"], item["key"])
    lines = ["/* English source keys. Compiler inventory is a lower bound; dynamic labels still require audit. */"]
    for key, value in sorted(existing.items()):
        if any(ord(c) < 32 and c not in "\n\r\t" for c in key + value):
            raise ValueError("Control character in source catalog")
        lines.append(json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    subprocess.run(["plutil", "-lint", "--", str(path)], check=True, capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--input-dir", type=Path)
    mode.add_argument("--snapshot-dir", type=Path)
    mode.add_argument("--build", action="store_true", help="Use a fresh isolated optimized build, then collect its declared compiler outputs")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--project-root", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--english-catalog", type=Path)
    args = parser.parse_args()
    if args.snapshot_dir:
        snapshot(args.snapshot_dir, args.source_root, args.project_root)
        print("Captured native source hashes before compiler extraction")
        return
    if not args.output:
        parser.error("--output is required with --input-dir")
    if args.build:
        with tempfile.TemporaryDirectory(prefix="native-localization-build-", dir="/private/tmp") as temporary:
            root = Path(temporary)
            emission, build = root / "emission", root / "build"
            snapshot(emission, args.source_root, args.project_root)
            build.mkdir()
            digest = hashlib.sha256((emission / ".source-snapshot.json").read_bytes()).hexdigest()
            (build / ".native-localization-snapshot").write_text(digest + "\n")
            command = ["swift", "build", "--package-path", str(args.project_root), "--scratch-path", str(build),
                       "-c", "release", "--disable-sandbox", "--disable-automatic-resolution", "--jobs", "4",
                       "--cache-path", "/private/tmp/synology-spm-cache", "-Xswiftc", "-emit-localized-strings",
                       "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(emission)]
            subprocess.run(command, check=True)
            collect(build, emission, args.source_root)
            result = inventory(emission, args.source_root, args.project_root)
            result["compiler_scope"] = "Fresh isolated optimized build; no prior project intermediates consumed"
            if args.english_catalog:
                merge_english(args.english_catalog, result)
            args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
            shutil.copyfile(emission / ".source-snapshot.json", args.output.with_suffix(".sources.json"))
            print(f"Inventoried {result['unique_table_keys']} keys / {result['occurrences']} compiler-marked occurrences; dynamic strings remain unaudited")
        return
    result = inventory(args.input_dir, args.source_root, args.project_root)
    if args.english_catalog:
        merge_english(args.english_catalog, result)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(f"Inventoried {result['unique_table_keys']} keys / {result['occurrences']} compiler-marked occurrences; dynamic strings remain unaudited")


if __name__ == "__main__":
    main()
