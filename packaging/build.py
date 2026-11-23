"""Build the Windows x64 portable distribution from the pinned upstream ZIPs."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def get_runtime(cache, entry):
    path = cache / entry["name"]
    if path.is_file() and sha256(path) == entry["sha256"]:
        return path
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as out:
        temporary = Path(out.name)
    try:
        request = urllib.request.Request(entry["url"], headers={"User-Agent": "AMC-packaging"})
        with urllib.request.urlopen(request, timeout=90) as source, temporary.open("wb") as out:
            shutil.copyfileobj(source, out)
        if sha256(temporary) != entry["sha256"]:
            raise ValueError("SHA-256 mismatch for " + entry["name"])
        temporary.replace(path)
        return path
    finally:
        temporary.unlink(missing_ok=True)


def pack_runtime(archive, runtime, prefix):
    with zipfile.ZipFile(runtime) as vendor:
        for member in vendor.infolist():
            name = PurePosixPath(member.filename)
            if name.is_absolute() or ".." in name.parts or ":" in member.filename or "\\" in member.filename:
                raise ValueError("Unexpected path in vendor ZIP: " + member.filename)
            if member.is_dir():
                continue
            with vendor.open(member) as source, archive.open(prefix + "/" + name.as_posix(), "w") as out:
                shutil.copyfileobj(source, out)


def build(cache, output):
    version = (ROOT / "VERSION").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Invalid VERSION")
    cache.mkdir(parents=True, exist_ok=True)
    output.mkdir(parents=True, exist_ok=True)
    lock = json.loads((ROOT / "packaging/runtimes.json").read_text(encoding="utf-8"))
    runtimes = {key: get_runtime(cache, entry) for key, entry in lock.items()}
    app = ROOT / "app"
    assets = [app / "assets/amc-message-grip.ico"]
    assets.extend(app / "assets/agent-icons" / name for name in
                  ("codex.png", "dsh.png", "qoder-dark.png", "qoder-light.png"))
    sources = [app / "Start-Reminder.ps1", app / "codex_local_sessions.py"]
    sources.extend(path for path in sorted(app.glob("Reminder.*"))
                   if path.suffix in (".cs", ".ps1"))
    name = f"AMC-v{version}-windows-x64-portable.zip"
    with tempfile.TemporaryDirectory(dir=output) as work:
        stage = Path(work).resolve()
        csc = Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        exe = stage / "AMC.exe"
        subprocess.run([str(csc), "/nologo", "/target:winexe", "/platform:x64", "/optimize+",
                        "/utf8output", "/codepage:65001", "/r:System.Windows.Forms.dll",
                        "/win32icon:" + str(assets[0]), "/out:" + str(exe),
                        str(ROOT / "packaging/Launcher.cs")], check=True)
        target = stage / name
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            archive.write(exe, "AMC.exe")
            for path in sources + assets:
                archive.write(path, path.relative_to(ROOT).as_posix())
            for path in [ROOT / "README.md", ROOT / "VERSION", ROOT / "THIRD-PARTY-NOTICES.md",
                         ROOT / "packaging/runtimes.json", *sorted((ROOT / "notices").glob("*.txt"))]:
                archive.write(path, path.relative_to(ROOT).as_posix())
            for key, runtime in runtimes.items():
                pack_runtime(archive, runtime, "runtime/" + key)
        digest = sha256(target)
        checksum = stage / (name + ".sha256")
        checksum.write_text(f"{digest}  {name}\n", encoding="ascii")
        target.replace(output / name)
        checksum.replace(output / checksum.name)
    print(name, digest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache-dir", type=Path, default=ROOT / ".cache")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    build(args.cache_dir.resolve(), args.output_dir.resolve())
