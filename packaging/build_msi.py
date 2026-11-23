"""Build a per-user MSI from the matching, checksummed AMC portable ZIP (WiX 4)."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
import uuid
from xml.etree import ElementTree as ET
import zipfile

from build import sha256

WIX = "http://wixtoolset.org/schemas/v4/wxs"
UPGRADE_CODE = uuid.UUID("eb992c01-5aba-46ac-8e1e-66c2e5a7d721")


def identifier(prefix, path):
    return prefix + hashlib.sha256(path.casefold().encode("utf-8")).hexdigest()[:28]


def product_version(version):
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-beta\.([1-9]\d*))?", version)
    if not match:
        raise ValueError("Expected major.minor.patch or major.minor.patch-beta.N")
    major, minor, patch = map(int, match.groups()[:3])
    # MSI compares three numeric fields. Reserve the last slot of each patch for stable.
    slot = int(match[4]) - 1 if match[4] else 255
    if max(major, minor, patch) > 255 or (match[4] and slot >= 255):
        raise ValueError("Version exceeds the MSI numeric range")
    return f"{major}.{minor}.{patch * 256 + slot}"


def write_source(stage, files, version):
    root = ET.Element("Wix", xmlns=WIX)
    add = ET.SubElement
    product = add(root, "Package", Name=f"Agent Message Center (AMC) {version}",
                  Manufacturer="Agent Message Center", Language="2052", Codepage="936",
                  Scope="perUser", InstallerVersion="500", Compressed="yes",
                  ProductCode=str(uuid.uuid5(UPGRADE_CODE, version)), UpgradeCode=str(UPGRADE_CODE),
                  Version=product_version(version))
    add(product, "SummaryInformation", Manufacturer="Agent Message Center", Description="AMC Windows x64 installer")
    add(product, "MajorUpgrade", DowngradeErrorMessage="A newer version of AMC is already installed.")
    add(product, "MediaTemplate", EmbedCab="yes", CompressionLevel="medium")
    for key, value in {"ARPNOMODIFY": "1", "LIMITUI": "1", "ARPPRODUCTICON": "AmcIcon",
                       "ARPURLINFOABOUT": "https://github.com/Yujze/agent-message-center"}.items():
        add(product, "Property", Id=key, Value=value)
    add(product, "Icon", Id="AmcIcon", SourceFile="payload/app/assets/amc-message-grip.ico")
    appdata = add(product, "StandardDirectory", Id="LocalAppDataFolder")
    programs = add(appdata, "Directory", Id="UserPrograms", Name="Programs")
    install = add(programs, "Directory", Id="INSTALLFOLDER", Name="Agent Message Center")
    # Registry key paths identify per-user components, so remember their directory for maintenance.
    folder_property = add(product, "Property", Id="INSTALLFOLDER", Secure="yes")
    add(folder_property, "RegistrySearch", Id="InstalledFolder", Root="HKCU",
        Key=r"Software\AgentMessageCenter\Installer", Name="InstallFolder", Type="raw")
    feature = add(product, "Feature", Id="AMC", Title="Agent Message Center", Level="1")
    dirs = {PurePosixPath("."): install}
    for path in sorted(files):
        for parent in reversed(path.parents):
            if parent not in dirs:
                dirs[parent] = add(dirs[parent.parent], "Directory",
                                   Id=identifier("d", str(parent)), Name=parent.name)
        name = path.as_posix()
        key = identifier("c", name)
        component = add(dirs[path.parent], "Component", Id=key, Guid=str(uuid.uuid5(UPGRADE_CODE, name.casefold())))
        add(component, "File", Id=identifier("f", name), Source="payload/" + name, Name=path.name)
        add(component, "RegistryValue", Root="HKCU", Key=r"Software\AgentMessageCenter\Installer\Files",
            Name=key, Type="integer", Value="1", KeyPath="yes")
        add(feature, "ComponentRef", Id=key)
    menu = add(product, "StandardDirectory", Id="ProgramMenuFolder")
    shortcut = add(menu, "Component", Id="StartMenuShortcut", Guid=str(uuid.uuid5(UPGRADE_CODE, "start-menu-shortcut")))
    add(shortcut, "Shortcut", Id="AmcShortcut", Name="智能体消息中心 (AMC)", Icon="AmcIcon",
        Target="[INSTALLFOLDER]AMC.exe", WorkingDirectory="INSTALLFOLDER")
    add(shortcut, "RegistryValue", Root="HKCU", Key=r"Software\AgentMessageCenter\Installer",
        Name="StartMenuShortcut", Type="integer", Value="1", KeyPath="yes")
    add(shortcut, "RegistryValue", Root="HKCU", Key=r"Software\AgentMessageCenter\Installer",
        Name="InstallFolder", Type="string", Value="[INSTALLFOLDER]")
    for node in dirs.values():
        add(shortcut, "RemoveFolder", Id="clean_" + node.get("Id"), Directory=node.get("Id"), On="uninstall")
    add(feature, "ComponentRef", Id="StartMenuShortcut")
    ET.ElementTree(root).write(stage / "AMC.wxs", encoding="utf-8", xml_declaration=True)


def build_msi(portable, wix, output):
    expected_hash, expected_name = Path(str(portable) + ".sha256").read_text(encoding="ascii").split()
    if portable.name != expected_name or sha256(portable) != expected_hash:
        raise ValueError("Portable ZIP checksum does not match")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as temp:
        stage = Path(temp)
        with zipfile.ZipFile(portable) as source:
            version = source.read("VERSION").decode("ascii").strip()
            product_version(version)
            if portable.name != f"AMC-v{version}-windows-x64-portable.zip":
                raise ValueError("Portable ZIP version does not match its filename")
            files = []
            seen = set()
            for entry in source.infolist():
                path = PurePosixPath(entry.filename)
                if (path.is_absolute() or ".." in path.parts or "\\" in entry.filename
                        or ":" in entry.filename or path.as_posix().casefold() in seen):
                    raise ValueError("Unexpected or duplicate path in portable ZIP")
                seen.add(path.as_posix().casefold())
                if not entry.is_dir():
                    files.append(path)
            source.extractall(stage / "payload")
        write_source(stage, files, version)
        name = f"AMC-v{version}-windows-x64.msi"
        subprocess.run([str(wix), "build", "-arch", "x64", "-pdbtype", "none", "-intermediatefolder",
                        "obj", "-out", name, "AMC.wxs"], cwd=stage, check=True)
        digest = sha256(stage / name)
        checksum = stage / (name + ".sha256")
        checksum.write_text(f"{digest}  {name}\n", encoding="ascii")
        (stage / name).replace(output / name)
        checksum.replace(output / checksum.name)
    print(name, digest)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("portable", type=Path)
    parser.add_argument("--wix", type=Path, required=True, help="Path to WiX 4 wix.exe")
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    build_msi(args.portable.resolve(), args.wix.resolve(), (args.output_dir or args.portable.parent).resolve())
