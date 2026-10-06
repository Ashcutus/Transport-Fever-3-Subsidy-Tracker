"""Check the actual ZIP, versioned metadata, legal notice and reproducibility."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
version = (ROOT / "VERSION").read_text().strip()
assert version == "1.1.0"
with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
    archive = builder.build(Path(first))
    again = builder.build(Path(second))
    assert archive.read_bytes() == again.read_bytes(), "Package builds must be reproducible"
    assert archive.name == "subsidy-manager-v1.1.0.zip"
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    assert archive.with_suffix(".zip.sha256").read_text().split()[0] == digest
    with zipfile.ZipFile(archive) as package:
        assert package.testzip() is None
        names = package.namelist()
        prefix = "tf3_subsidy_manager_1/"
        assert all(name.startswith(prefix) and ".." not in name for name in names)
        assert len(names) == len(set(names))
        assert not any(re.search(r"tests/|AGENTS|README|tlconfig|all_def|\.svg$|__pycache__|\.git", name) for name in names)
        manifest = json.loads(package.read(prefix + "mod.json"))
        assert manifest["modId"] == "tf3_subsidy_manager"
        assert type(manifest["revision"]) is int and manifest["revision"] == 13, "v1.1.0 increments revision 12 once"
        assert manifest == json.loads((builder.MOD / "mod.json").read_text())
        assert "version" not in manifest and "platforms" not in manifest
        info = json.loads(package.read(prefix + "_metadata/modinfo.json"))
        assert info["name"] == "Subsidy Manager" and len(info["name"]) <= 32
        assert len(info["summary"]) <= 100 and "\n" not in info["summary"]
        assert info == json.loads((builder.MOD / "_metadata/modinfo.json").read_text())
        assert info["authors"] == [{"name": "Ashcutus", "role": "CREATOR"}]
        assert info["summary"] == "Compare subsidy offers, follow your progress and find your next opportunity in one place."
        assert info["description"].startswith("A useful subsidy offer can be easy to lose in a busy game.")
        assert info["url"] == "https://github.com/Ashcutus/Transport-Fever-3-Subsidy-Tracker"
        assert "version" not in info and "platforms" not in info
        assert set(info["tags"]) == {"Misc", "Script Mod"}
        illustration = package.read(prefix + "content/plugins/subsidy_manager/icons/empty_contract_64@2x.tga")
        import struct
        assert struct.unpack_from("<HH", illustration, 12) == (128, 128)
        assert illustration[16] == 32, "Empty-state illustration must retain alpha"
        notice = package.read(prefix + "license.txt")
        assert notice == (ROOT / "LICENSE").read_bytes()
        assert b"MIT License" in notice and b"without restriction" in notice
        assert b'THE SOFTWARE IS PROVIDED "AS IS"' in notice
        strings = json.loads(package.read(prefix + "strings.json"))["en"]
        script = package.read(prefix + "content/plugins/subsidy_manager/main.script.tl").decode()
        for key in re.findall(r'_\("(tf3_subsidy_manager_[a-z_]+)"\)', script):
            assert key in strings, key
        for suffix in ("active", "offered", "history"):
            assert "tf3_subsidy_manager_" + suffix in strings
        for suffix in ("type", "resource", "destination", "requirement", "reward", "time", "progress", "deadline", "status", "result", "reward_consequence"):
            assert "tf3_subsidy_manager_column_" + suffix in strings
        for name in names:
            if name.endswith((".json", ".lua", ".tl", ".txt")):
                text = package.read(name).decode("utf-8")
                assert not text.startswith("\ufeff")
                assert not re.search(r"/home/|/tmp/|\b(?:copilot|codex|openai|gpt|proof of concept)\b", text, re.I), name
        expected = {prefix + path for path in builder.RUNTIME_FILES}
        assert set(names) >= expected
        assert all(name in expected or re.fullmatch(re.escape(prefix) + r"_metadata/\d+\.png", name) for name in names)
print("PASS: runtime archive hygiene, public/internal version distinction, metadata, translations, MIT notice and reproducible ZIP/checksum")
