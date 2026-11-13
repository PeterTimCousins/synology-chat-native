#!/usr/bin/env python3
"""Copy the native module bundle and main-bundle catalogs before app signing."""
import argparse
import json
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from native_localization_formats import validate_scalar_catalog

BUNDLE_NAME = "SynologyChatNative_SynologyChatNative.bundle"


def read_plist(path):
    data = path.read_bytes()
    try:
        return plistlib.loads(data)
    except plistlib.InvalidFileException:
        result = subprocess.run(["plutil", "-convert", "json", "-o", "-", "--", str(path)],
                                check=True, capture_output=True)
        return json.loads(result.stdout)


def catalog(folder):
    path = folder / "Localizable.strings"
    values = read_plist(path)
    if not isinstance(values, dict) or not values or not all(isinstance(k, str) and k and isinstance(v, str) and v for k, v in values.items()):
        raise ValueError(f"Invalid or empty string catalog: {path}")
    variants = {}
    plural = folder / "Localizable.stringsdict"
    if plural.exists():
        variants = read_plist(plural)
        if not isinstance(variants, dict) or not all(isinstance(k, str) and isinstance(v, dict) and isinstance(v.get("NSStringLocalizedFormatKey"), str) for k, v in variants.items()):
            raise ValueError(f"Invalid plural catalog: {plural}")
    return values, variants


def validate_plurals(english, translated):
    """The current native plural contract is one signed 64-bit count per key.

    Reject unsupported structures rather than copying an unverified formatter.
    Additional language categories are allowed; each must preserve the count.
    Linguistic correctness and language-specific category coverage need review.
    """
    if set(english) != set(translated):
        raise ValueError("Plural catalog keys must match the English plural catalog")
    categories = {"zero", "one", "two", "few", "many", "other"}
    for key, entry in translated.items():
        if (not isinstance(entry, dict) or set(entry) != {"NSStringLocalizedFormatKey", "count"}
                or entry["NSStringLocalizedFormatKey"] != "%#@count@"):
            raise ValueError(f"Unsupported plural structure for {key!r}")
        rule = entry["count"]
        if (not isinstance(rule, dict)
                or rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType"
                or rule.get("NSStringFormatValueTypeKey") != "lld"):
            raise ValueError(f"Invalid signed 64-bit plural count for {key!r}")
        branches = set(rule) - {"NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey"}
        if "other" not in branches or not branches.issubset(categories):
            raise ValueError(f"Missing other or unsupported plural category for {key!r}")
        for branch in branches:
            validate_scalar_catalog({key: "%lld"}, {key: rule[branch]})


def copy_resources(build_directory, resources, info_plist):
    source = build_directory / BUNDLE_NAME
    if not source.is_dir():
        raise ValueError(f"Missing native resource bundle: {source}")
    if any(p.is_symlink() for p in source.resolve().rglob("*")):
        raise ValueError("Native resource bundle contains a development symlink")
    catalog_root = source / "Contents" / "Resources"
    if not catalog_root.is_dir():
        catalog_root = source
    locales = sorted(p for p in catalog_root.iterdir() if p.is_dir() and p.suffix == ".lproj")
    if not any(p.name == "en.lproj" for p in locales):
        raise ValueError("Native resource bundle has no English fallback catalog")
    english_strings, english_plurals = catalog(catalog_root / "en.lproj")
    english = set(english_strings) | set(english_plurals)
    validate_scalar_catalog(english_strings, english_strings)
    validate_plurals(english_plurals, english_plurals)
    for folder in locales:
        if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]+)*", folder.stem):
            raise ValueError(f"Invalid localization folder: {folder.name}")
        strings, plurals = catalog(folder)
        if not english.issubset(set(strings) | set(plurals)):
            raise ValueError(f"Incomplete catalog must not be advertised: {folder.name}")
        if set(strings) != set(english_strings):
            raise ValueError(f"Scalar catalog keys must match English: {folder.name}")
        validate_scalar_catalog(english_strings, strings)
        validate_plurals(english_plurals, plurals)
    info = plistlib.loads(info_plist.read_bytes())
    if not isinstance(info, dict):
        raise ValueError("Invalid app Info.plist")
    destinations = [resources / BUNDLE_NAME] + [resources / p.name for p in locales]
    if any(p.exists() for p in destinations):
        raise ValueError("Localization destination already exists; use a fresh package staging directory")
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, resources / BUNDLE_NAME, symlinks=False)
    for folder in locales:
        shutil.copytree(folder, resources / folder.name, symlinks=False)
    info["CFBundleDevelopmentRegion"] = "en"
    # .lproj catalogs are discovered automatically. Declaring the same IDs in
    # CFBundleLocalizations makes Foundation report duplicate language entries.
    info.pop("CFBundleLocalizations", None)
    with info_plist.open("wb") as stream:
        plistlib.dump(info, stream)
    return [p.stem for p in locales]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-directory", required=True, type=Path)
    parser.add_argument("--resources", required=True, type=Path)
    parser.add_argument("--info-plist", required=True, type=Path)
    args = parser.parse_args()
    locales = copy_resources(args.build_directory, args.resources, args.info_plist)
    print("Packaged native localization catalogs: " + ", ".join(locales))


if __name__ == "__main__":
    main()
