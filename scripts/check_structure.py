#!/usr/bin/env python3
"""Check module imports and Xcode/SwiftPM source ownership."""

import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/SnowlitKit"
DEPENDENCIES = {
    "SnowlitCore": set(),
    "SnowlitStorage": {"SnowlitCore", "GRDB"},
    "YingxueKit": {"SnowlitCore", "SwiftSoup"},
    "SnowlitReader": {"SnowlitCore"},
}
IMPORTS = {
    "SnowlitCore": {"Foundation"},
    "SnowlitStorage": {"Foundation", "SnowlitCore", "GRDB", "Security"},
    "YingxueKit": {"Foundation", "CoreFoundation", "SnowlitCore", "WebKit", "SwiftSoup"},
    "SnowlitReader": {"Foundation", "SnowlitCore", "UIKit"},
}
GRDB_URL = "https://github.com/groue/GRDB.swift.git"
GRDB_VERSION = "7.12.0"
GRDB_REVISION = "92a554cd0d5e8d67cb18993c6054e73fe42c066c"
EXTERNAL_PACKAGES = {
    "grdb.swift": (GRDB_URL, GRDB_VERSION, GRDB_REVISION),
    "swiftsoup": ("https://github.com/scinfu/SwiftSoup.git", "2.14.3", "e7f85f4d3dd91ca9a1e94d3328aa1ed5120a8c0f"),
}
EXTERNAL_PRODUCTS = {
    "SnowlitStorage": ["GRDB", "GRDB.swift", None, None],
    "YingxueKit": ["SwiftSoup", "SwiftSoup", None, None],
}


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def command_json(*args):
    return json.loads(subprocess.check_output(args, cwd=ROOT, text=True))


def check_imports():
    for module, allowed in IMPORTS.items():
        for path in (PACKAGE / "Sources" / module).rglob("*.swift"):
            imports = set(re.findall(
                r"^\s*(?:@\w+\s+)?import\s+([A-Za-z_]\w*)",
                path.read_text(encoding="utf-8"), re.MULTILINE,
            ))
            require(imports <= allowed, f"{path.relative_to(ROOT)}: forbidden imports {imports - allowed}")
    print("Package import boundaries: passed")


def check_manifest():
    manifest = command_json("swift", "package", "--package-path", str(PACKAGE), "dump-package")
    external = manifest["dependencies"]
    require(len(external) == len(EXTERNAL_PACKAGES), "Only reviewed dependencies are allowed")
    identities = set()
    for dependency in external:
        require(set(dependency) == {"sourceControl"}, "Dependencies must be locked source-control packages")
        source = dependency["sourceControl"]
        require(len(source) == 1 and source[0]["identity"] in EXTERNAL_PACKAGES, "Unreviewed dependency")
        identity = source[0]["identity"]
        require(identity not in identities, "Duplicate dependency")
        identities.add(identity)
        url, version, _ = EXTERNAL_PACKAGES[identity]
        require(source[0]["location"] == {"remote": [{"urlString": url}]}
                and source[0]["requirement"] == {"exact": [version]}, "Dependency URL/version differs from review")
    for path in (PACKAGE / "Package.resolved",
                 ROOT / "Snowlit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"):
        locked = json.loads(path.read_text(encoding="utf-8"))
        require(locked.get("version") in (2, 3), f"Unexpected lock format: {path}")
        expected_pins = [{"identity": identity, "kind": "remoteSourceControl", "location": url,
                          "state": {"revision": revision, "version": version}}
                         for identity, (url, version, revision) in EXTERNAL_PACKAGES.items()]
        require(sorted(locked["pins"], key=lambda pin: pin["identity"]) == sorted(expected_pins, key=lambda pin: pin["identity"]),
                f"Unreviewed or unlocked dependency in {path}")
    require((ROOT / "Licenses/GRDB.txt").is_file(), "GRDB license attribution is required")
    require((ROOT / "Licenses/SwiftSoup.txt").is_file(), "SwiftSoup license attribution is required")
    require(manifest["swiftLanguageVersions"] == ["6"], "Swift 6 language mode is required")
    require(any(p["platformName"] == "ios" and p["version"] == "26.0"
                for p in manifest["platforms"]), "Package minimum iOS must be 26.0")
    libraries = {t["name"]: t for t in manifest["targets"] if t["type"] == "regular"}
    require(libraries.keys() == DEPENDENCIES.keys(), "Unexpected library target graph")
    for name, target in libraries.items():
        expected_resources = [{"path": "Resources/SourceInspection", "rule": {"copy": {}}}] if name == "YingxueKit" else []
        resources = [{**item, "path": item["path"].replace("\\", "/")} for item in target.get("resources", [])]
        require(resources == expected_resources, f"Unexpected bundled resources in {name}")
        dependencies = set()
        for entry in target["dependencies"]:
            require(len(entry) == 1, f"Unexpected dependency kind in {name}")
            if "product" in entry:
                require(entry["product"] == EXTERNAL_PRODUCTS.get(name),
                        f"Unexpected external product in {name}")
                dependencies.add(entry["product"][0])
            else:
                require("byName" in entry or "target" in entry, f"Unexpected dependency kind in {name}")
                dependencies.add(next(iter(entry.values()))[0])
        require(dependencies == DEPENDENCIES[name], f"Incorrect dependencies for {name}")
    products = {p["name"]: p["targets"] for p in manifest["products"]}
    require(products == {name: [name] for name in DEPENDENCIES}, "Unexpected package products")
    print("SwiftPM dependency graph and deployment: passed")


def check_project():
    project = command_json("plutil", "-convert", "json", "-o", "-",
                           str(ROOT / "Snowlit.xcodeproj/project.pbxproj"))
    objects = project["objects"]
    root = objects[project["rootObject"]]
    files = {}

    def visit(reference, parent):
        item = objects[reference]
        if item["isa"] == "PBXGroup":
            base = parent / item.get("path", "")
            for child in item.get("children", []):
                visit(child, base)
        elif item["isa"] == "PBXFileReference" and item.get("sourceTree") == "<group>":
            files[reference] = (parent / item["path"]).resolve()

    visit(root["mainGroup"], ROOT)
    owners = {}
    expected_roots = {
        "Snowlit": ROOT / "App",
        "SnowlitAppTests": ROOT / "Tests/SnowlitAppTests",
        "SnowlitUITests": ROOT / "Tests/SnowlitUITests",
    }
    targets = {objects[t]["name"]: objects[t] for t in root["targets"]}
    require(targets.keys() == expected_roots.keys(), "Unexpected Xcode targets")
    for name, target in targets.items():
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            for build_file in phase["files"]:
                source = files[objects[build_file]["fileRef"]]
                require(source.is_file(), f"Missing source {source}")
                require(source.is_relative_to(expected_roots[name]), f"Incorrect owner of {source}")
                require(source not in owners, f"Source registered twice: {source}")
                owners[source] = name
    expected = {p.resolve() for folder in expected_roots.values() for p in folder.rglob("*.swift")}
    require(owners.keys() == expected, "Xcode source list and source files differ")
    require(not any(p.is_relative_to(PACKAGE / "Sources") for p in files.values()),
            "Package source must not be registered in Xcode")
    app_products = {objects[p]["productName"] for p in targets["Snowlit"]["packageProductDependencies"]}
    require(app_products == set(DEPENDENCIES), "App must link the four package products")
    probe_products = {objects[p]["productName"]
                      for p in targets["SnowlitAppTests"]["packageProductDependencies"]}
    require(probe_products == {"SnowlitCore", "SnowlitStorage", "YingxueKit", "SnowlitReader"},
            "Hosted probes must use the package products")
    references = [objects[p] for p in root["packageReferences"]]
    require(len(references) == 1
            and references[0]["isa"] == "XCLocalSwiftPackageReference"
            and references[0]["relativePath"] == "Packages/SnowlitKit",
            "App must use the local package")
    project_configs = {
        objects[c]["name"]: objects[c]["buildSettings"]
        for c in objects[root["buildConfigurationList"]]["buildConfigurations"]
    }
    for target in targets.values():
        for config_id in objects[target["buildConfigurationList"]]["buildConfigurations"]:
            config = objects[config_id]
            settings = project_configs[config["name"]] | config["buildSettings"]
            require(str(settings["IPHONEOS_DEPLOYMENT_TARGET"]) == "26.0", "Incorrect iOS minimum")
            require(str(settings["SWIFT_VERSION"]) == "6.0", "Swift 6 is required")
            require(settings["SWIFT_STRICT_CONCURRENCY"] == "complete", "Strict concurrency is required")
            if target["name"] == "SnowlitAppTests":
                require(settings.get("BUNDLE_LOADER") == "$(TEST_HOST)"
                        and settings.get("TEST_HOST") == "$(BUILT_PRODUCTS_DIR)/Snowlit.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Snowlit",
                        "Platform probes must run inside the application host")
    print("Xcode source ownership, linkage and build settings: passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--sources-only", action="store_true",
                        help="Inspect Swift imports only; does not validate Apple build configuration")
    options = parser.parse_args()
    check_imports()
    if not options.sources_only:
        check_manifest()
        check_project()
