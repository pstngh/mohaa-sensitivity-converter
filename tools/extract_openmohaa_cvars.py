#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path

CVAR_PATTERNS = [
    re.compile(r'Cvar_Get\s*\(\s*"([^"]+)"\s*,\s*"([^"]*)"\s*,\s*([^\)]*)\)'),
    re.compile(r'\bcvar_t\s*\*\s*([a-zA-Z0-9_]+)\s*;'),
]

BROKEN_HINTS = re.compile(r'\b(broken|not implemented|todo|fixme|wip|experimental|stub)\b', re.IGNORECASE)
SH_HINTS = re.compile(r'\bsh\b|spearhead', re.IGNORECASE)
BT_HINTS = re.compile(r'\bbt\b|breakthrough', re.IGNORECASE)


def detect_mode(text: str):
    sh = bool(SH_HINTS.search(text))
    bt = bool(BT_HINTS.search(text))
    if sh and bt:
        return "both"
    if sh:
        return "sh"
    if bt:
        return "bt"
    return "unknown"


def detect_status(text: str):
    lower = text.lower()
    if any(k in lower for k in ["broken", "not implemented", "stub"]):
        return "broken"
    if any(k in lower for k in ["experimental", "todo", "fixme", "wip"]):
        return "experimental"
    return "stable"


def iter_source_files(root: Path):
    for ext in ("*.c", "*.cc", "*.cpp", "*.h", "*.hpp", "*.inl"):
        yield from root.rglob(ext)


def extract_cvars(source_root: Path):
    found = {}
    for file_path in iter_source_files(source_root):
        try:
            text = file_path.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        lines = text.splitlines()

        for match in CVAR_PATTERNS[0].finditer(text):
            name = match.group(1).strip()
            default_value = match.group(2)
            flags_raw = match.group(3).strip()
            start = match.start()
            line_no = text.count("\n", 0, start) + 1

            context_start = max(0, line_no - 4)
            context_end = min(len(lines), line_no + 3)
            context = "\n".join(lines[context_start:context_end])

            mode = detect_mode(str(file_path) + "\n" + context)
            status = detect_status(context)
            description = ""

            if name not in found:
                found[name] = {
                    "name": name,
                    "description": description,
                    "defaultValue": default_value,
                    "flags": [f.strip() for f in flags_raw.replace("|", ",").split(",") if f.strip()],
                    "mode": mode,
                    "status": status,
                    "source": {
                        "file": str(file_path.relative_to(source_root)),
                        "line": line_no,
                    },
                }
            else:
                existing = found[name]
                if existing["mode"] == "unknown" and mode != "unknown":
                    existing["mode"] = mode
                if existing["status"] == "stable" and status in ("experimental", "broken"):
                    existing["status"] = status
                for flag in [f.strip() for f in flags_raw.replace("|", ",").split(",") if f.strip()]:
                    if flag not in existing["flags"]:
                        existing["flags"].append(flag)

    return sorted(found.values(), key=lambda x: x["name"].lower())


def main():
    parser = argparse.ArgumentParser(description="Extract OpenMoHAA cvars from source files.")
    parser.add_argument("--source", required=True, help="Path to openmohaa source root")
    parser.add_argument("--out", default="data/openmohaa-cvars.json", help="Output JSON path")
    args = parser.parse_args()

    source_root = Path(args.source).resolve()
    out_path = Path(args.out).resolve()

    if not source_root.exists():
        raise SystemExit(f"Source path does not exist: {source_root}")

    cvars = extract_cvars(source_root)
    output = {
        "generatedAt": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        "sourceRoot": str(source_root),
        "cvars": cvars,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, indent=2), encoding="utf-8")
    print(f"Extracted {len(cvars)} cvars -> {out_path}")


if __name__ == "__main__":
    main()
