"""Package the unsigned device build and verify the exact archive being uploaded."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tempfile
import zipfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_archive(ipa, revision):
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        if len(names) != len(set(names)) or archive.testzip() is not None:
            raise ValueError("The IPA contains duplicate or corrupt entries")
        for name in names:
            path = PurePosixPath(name)
            if (path.is_absolute() or ".." in path.parts or "\\" in name
                    or not (name == "Payload/" or name.startswith("Payload/Snowlit.app/"))):
                raise ValueError("The IPA contains content outside the application bundle")
            if any(part in {".local", ".git", "GOALS.md", "PLANS.md", "PROGRESS.md", "rewrite"}
                   or part.lower() == "logo.png" for part in path.parts):
                raise ValueError("Local-only content must not be packaged")
            if "_CodeSignature" in path.parts or path.name == "embedded.mobileprovision":
                raise ValueError("Expected an unsigned bundle without a provisioning profile")
        prefix = "Payload/Snowlit.app/"
        info = plistlib.loads(archive.read(prefix + "Info.plist"))
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"] or 1 not in info.get("UIDeviceFamily", []):
            raise ValueError("Expected an iPhone device build, not a simulator bundle")
        executable = info.get("CFBundleExecutable", "")
        if not executable or PurePosixPath(executable).name != executable:
            raise ValueError("Invalid application executable")
        binary = archive.getinfo(prefix + executable)
        if not stat.S_ISREG(binary.external_attr >> 16) or not (binary.external_attr >> 16) & stat.S_IXUSR:
            raise ValueError("The archived executable has lost its executable permission")
        provenance = json.loads(archive.read(prefix + "SnowlitBuild.json"))
        if provenance.get("sourceRevision") != revision or provenance.get("signing") != "unsigned":
            raise ValueError("The packaged provenance does not match this build")
        required = ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion"]
        if any(not info.get(key) for key in required):
            raise ValueError("The device bundle is missing required version metadata")
        return dict(formatVersion=1, sourceRevision=revision, signing="unsigned",
                    ipa=ipa.name, ipaSHA256=sha256(ipa.read_bytes()), bytes=ipa.stat().st_size,
                    bundle={key: info[key] for key in required},
                    executableSHA256=sha256(archive.read(prefix + executable)),
                    entries=len(entries), provenance=provenance,
                    scope="Device build and package only; installation and product acceptance remain separate")


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def package(app, destination):
    root = Path(__file__).resolve().parent.parent
    revision = output("git", "-C", str(root), "rev-parse", "HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected a full source revision")
    if output("git", "-C", str(root), "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Build an unchanged source checkout so the IPA identifies its actual source")
    if app.name != "Snowlit.app" or not app.is_dir():
        raise ValueError("Expected the built Snowlit.app")
    provenance = dict(formatVersion=1, sourceRevision=revision, configuration="Release", signing="unsigned",
                      xcode=output("xcodebuild", "-version"), swift=output("xcrun", "swift", "--version"),
                      sdk=output("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
                      architecture=output("lipo", "-archs", str(app / "Snowlit")))
    if provenance["architecture"] != "arm64":
        raise ValueError("Expected the arm64 iPhone build")
    locks = ["Packages/SnowlitKit/Package.resolved",
             "Snowlit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"]
    provenance["dependencyLocks"] = {name: sha256((root / name).read_bytes()) for name in locks}
    destination.mkdir(parents=True, exist_ok=True)
    name = "Snowlit-" + revision[:12] + "-unsigned"
    ipa = destination / (name + ".ipa")
    if ipa.exists():
        raise FileExistsError("Keep existing artifacts; use an empty output directory")
    # ditto preserves bundle permissions and links. Only the built App is copied;
    # the workspace, local planning and signing credentials are never archive inputs.
    with tempfile.TemporaryDirectory(prefix="snowlit-ipa-") as temporary:
        staging = Path(temporary)
        staged_app = staging / "Payload/Snowlit.app"
        subprocess.run(["ditto", "--norsrc", str(app), str(staged_app)], check=True)
        (staged_app / "SnowlitBuild.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
        pending = staging / "candidate.ipa"
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", str(staging / "Payload"), str(pending)], check=True)
        report = verify_archive(pending, revision)
        report["ipa"] = ipa.name
        # Publish into the upload directory only after verifying the complete ZIP.
        with ipa.open("xb") as target:
            target.write(pending.read_bytes())
    (destination / (name + ".json")).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (destination / (name + ".sha256")).write_text(report["ipaSHA256"] + "  " + ipa.name + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    package(arguments.app.resolve(), arguments.destination.resolve())
