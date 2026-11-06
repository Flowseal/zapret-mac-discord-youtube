#!/usr/bin/env python3
"""Build the control add-on from source, without an installed app or user data."""
import gzip
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
BUILD = Path("build/control")
DIST = Path("dist")
LABEL = "io.github.flowseal.zapretmac.control"
IDENTITY = os.environ.get("ZAPRET_SIGNING_IDENTITY", "-")
ARCHES = ["arm64", "x86_64"]

def run(*args):
    subprocess.run([str(a) for a in args], check=True)

def output(*args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()

if BUILD.exists():
    shutil.rmtree(BUILD)
BUILD.mkdir(parents=True)
DIST.mkdir(exist_ok=True)
sdk = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
swift = output("xcrun", "-f", "swiftc")
clang = output("xcrun", "-f", "clang")
run("make", "-C", "nfq", "clean", "mac", f"CC={clang}", f"SDKROOT={sdk}",
    f"OPTIMIZE=-Os -ffile-prefix-map={ROOT}=.")
shared = ["macos/Control/Protocol.swift", "macos/Control/TrustedInstallation.swift"]

def compile_binary(name, sources, defines=()):
    slices = []
    for arch in ARCHES:
        target = BUILD / f"{name}-{arch}"
        run(swift, "-swift-version", "5", "-O", "-parse-as-library", "-sdk", sdk,
            "-target", f"{arch}-apple-macos14.0", "-file-prefix-map", f"{ROOT}=.",
            "-debug-prefix-map", f"{ROOT}=.", "-file-compilation-dir", "/ZapretMac",
            *defines, *sources, "-o", target)
        slices.append(target)
    result = BUILD / name
    run("lipo", "-create", *slices, "-output", result)
    return result

def sign(path, identifier=None):
    args = ["codesign", "--force", "--sign", IDENTITY, "--options", "runtime"]
    if IDENTITY != "-": args += ["--timestamp"]
    if identifier: args += ["--identifier", identifier]
    run(*args, path)
    run("codesign", "--verify", "--strict", path)

application = compile_binary("ZapretMac", shared + ["macos/Control/Client.swift", "macos/App/ZapretMacApp.swift"], ["-D", "ZAPRET_CONTROL"])
original = compile_binary("ZapretMac-original", ["macos/App/ZapretMacApp.swift"])
helper = compile_binary("control-helper", shared + ["macos/Control/Helper.swift"])
probe = compile_binary("control-probe", shared + ["macos/Control/Client.swift", "macos/Control/Probe.swift"])
setup = compile_binary("setup-check", shared + ["macos/Control/SetupCheck.swift"])

payload = BUILD / "package-root"
rollback = BUILD / "rollback-root"
scripts = BUILD / "package-scripts"
rollback_scripts = BUILD / "rollback-scripts"
for directory in [payload, rollback, scripts, rollback_scripts]: directory.mkdir()

def make_app(base, executable):
    app = base / "Applications/ZapretMac.app"
    contents = app / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    shutil.copy2(executable, contents / "MacOS/ZapretMac")
    shutil.copy2("macos/Info.plist", contents / "Info.plist")
    shutil.copytree("macos/Payload", contents / "Resources/Payload")
    engine = contents / "Resources/Payload/bin/utunws"
    shutil.copy2("nfq/utunws", engine)
    for script in (contents / "Resources/Payload").glob("*.sh"): script.chmod(0o755)
    shutil.copy2("LICENSE", contents / "Resources/LICENSE")
    sign(engine, "io.github.flowseal.zapretmac.utunws")
    sign(app)
    run("codesign", "--verify", "--deep", "--strict", app)
    return app

app = make_app(payload, application)
make_app(rollback, original)
control_dir = payload / "Library/Application Support/ZapretMacControl"
control_dir.mkdir(parents=True)
shutil.copy2("macos/Control/control.sh", control_dir / "control.sh")
(control_dir / "control.sh").chmod(0o755)
shutil.copy2("LICENSE", control_dir / "LICENSE")
shutil.copy2(probe, control_dir / "probe")
sign(control_dir / "probe", LABEL + ".probe")
helper_path = payload / "Library/PrivilegedHelperTools" / LABEL
helper_path.parent.mkdir(parents=True)
shutil.copy2(helper, helper_path)
sign(helper_path, LABEL)

def requirement(paths):
    # Pin both architectures of the explicitly approved build, also for ad-hoc signatures.
    hashes = set()
    for path in paths:
        for arch in ARCHES:
            result = subprocess.run(["codesign", "-d", "--arch", arch, "--verbose=4", str(path)],
                                    capture_output=True, text=True, check=True)
            match = re.search(r"^CDHash=([0-9a-f]{40})$", result.stderr, re.M)
            if not match: raise RuntimeError("Missing code-directory hash")
            hashes.add(match.group(1))
    text = "(" + " or ".join(f'cdhash H"{value}"' for value in sorted(hashes)) + ")"
    for path in paths: run("codesign", "--verify", "--strict", "-R", "=" + text, path)
    return text

requirements = {
    "ClientRequirement": requirement([app, control_dir / "probe"]),
    "ServiceRequirement": requirement([helper_path]),
}
(control_dir / "requirements.plist").write_bytes(plistlib.dumps(requirements))
plist = payload / "Library/LaunchDaemons" / f"{LABEL}.plist"
plist.parent.mkdir(parents=True)
plist.write_bytes(plistlib.dumps({
    "Label": LABEL,
    "ProgramArguments": [f"/Library/PrivilegedHelperTools/{LABEL}"],
    "MachServices": {LABEL: True},
    "RunAtLoad": True,
    "UserName": "root",
    "GroupName": "wheel",
    "StandardOutPath": "/var/log/zapretmac-control.log",
    "StandardErrorPath": "/var/log/zapretmac-control.log",
}))
for target in [scripts, rollback_scripts]:
    shutil.copy2(setup, target / "setup-check")
    sign(target / "setup-check", LABEL + ".setup")
for name in ["preinstall", "postinstall"]:
    for target, prefix in [(scripts, ""), (rollback_scripts, "rollback-")]:
        shutil.copy2(f"macos/Packaging/{prefix}{name}", target / name)
        (target / name).chmod(0o755)
        run("/bin/sh", "-n", target / name)

# Different signed identity, excluded from the root-owned allowlist. Installer tests rejection.
shutil.copy2(probe, scripts / "untrusted-probe")
sign(scripts / "untrusted-probe", LABEL + ".untrusted-test")
negative = subprocess.run(["codesign", "--verify", "-R", "=" + requirements["ClientRequirement"],
                           str(scripts / "untrusted-probe")], capture_output=True)
if negative.returncode == 0: raise RuntimeError("Untrusted signature unexpectedly accepted")

components = BUILD / "components.plist"
components.write_bytes(plistlib.dumps([{
    "RootRelativeBundlePath": "Applications/ZapretMac.app", "BundleIsRelocatable": False,
    "BundleIsVersionChecked": False, "BundleHasStrictIdentifier": True, "BundleOverwriteAction": "upgrade",
}]))
for root, script_dir, identifier, filename in [
    (payload, scripts, LABEL + ".package", "ZapretMac-Control.pkg"),
    (rollback, rollback_scripts, LABEL + ".rollback", "Restore-ZapretMac.pkg"),
]:
    run("pkgbuild", "--root", root, "--scripts", script_dir, "--component-plist", components,
        "--identifier", identifier, "--version", "2.0", "--install-location", "/",
        "--ownership", "recommended", DIST / filename)
for path in [app / "Contents/MacOS/ZapretMac", helper_path, control_dir / "probe"]:
    if set(output("lipo", "-archs", path).split()) != set(ARCHES):
        raise RuntimeError("Missing architecture in " + str(path))
shutil.copy2("LICENSE", DIST / "LICENSE")
# Export only source, with neutral archive ownership and no macOS extended attributes.
with (DIST / "ZapretMac-Control-source.tar.gz").open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for path in sorted(ROOT.rglob("*")):
                relative = path.relative_to(ROOT)
                if any(part in {".git", "build", "dist", "__pycache__", ".DS_Store"} for part in relative.parts):
                    continue
                if relative.as_posix() in {"nfq/utunws", "nfq/utunwsa", "nfq/utunwsx"}: continue
                if not path.is_file() or path.is_symlink(): continue
                info = archive.gettarinfo(str(path), "zapret-mac-control/" + relative.as_posix())
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 0
                info.pax_headers = {}
                with path.open("rb") as source: archive.addfile(info, source)
with (DIST / "SHA256SUMS").open("w") as stream:
    for path in sorted(DIST.iterdir()):
        if path.name == "SHA256SUMS" or not path.is_file(): continue
        stream.write(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
print("Build complete. Packages require an existing configured ZapretMac 1.1.2 installation.")
