#!/usr/bin/env python3
"""Include dependency licenses in the app and downloadable build artifact."""
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["go", "mod", "download"], cwd=root / "core", check=True)
raw = subprocess.check_output(["go", "list", "-m", "-json", "all"], cwd=root / "core", text=True)
decoder = json.JSONDecoder()
modules = []
while raw.strip():
    module, end = decoder.raw_decode(raw.lstrip())
    modules.append(module)
    raw = raw.lstrip()[end:]
parts = ["NodeScope 1.2.1 — GPL-3.0\nSource: https://github.com/yiyiyiyayayu/speed-text\n"]
for module in modules:
    if module.get("Main"):
        continue
    directory = pathlib.Path(module.get("Dir", ""))
    parts.append(f"\n{'=' * 72}\n{module['Path']} {module.get('Version', '')}\n")
    licenses = sorted(p for p in directory.iterdir() if p.is_file() and p.name.lower().startswith(("license", "copying", "notice"))) if directory.is_dir() else []
    for path in licenses:
        parts.append(f"\n{path.name}\n{path.read_text(errors='replace')}\n")
    if not licenses:
        parts.append("License: see module source listed in core/go.mod and core/go.sum.\n")
parts.append("\nNodeScope project license\n" + (root / "LICENSE").read_text())
output = root / "ios/NodeScope/THIRD_PARTY_NOTICES.txt"
output.write_text("".join(parts))
(root / "dist").mkdir(exist_ok=True)
(root / "dist/THIRD_PARTY_NOTICES.txt").write_text("".join(parts))
