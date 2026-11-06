#!/usr/bin/env python3
"""Повторный подсчёт для АП-01 без изменения файлов репозитория."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

SNAPSHOT = "b610b81fbf4470ce6fc1693d8fb11f8f5fb82d33"
EXPECTED = {
    "docs/maintenance/business-requirements.md": "6259669b48797d283934cd0de9eb29a991b6b725",
    "docs/requirements/maintenance-system.md": "025d66a3c4177105b527dda109bf40464b4755e5",
}


def analyze(data: bytes, expected: str) -> dict[str, object]:
    """Проверить содержимое и посчитать определения, а не упоминания номеров."""
    actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    if actual != expected:
        raise ValueError(f"Идентификатор содержимого не совпал: {actual}; ожидался {expected}")
    text = data.decode("utf-8")
    tables: list[list[list[str]]] = []
    block: list[list[str]] = []
    for line in text.splitlines() + [""]:
        if line.startswith("|"):
            block.append([cell.strip() for cell in line.strip().strip("|").split("|")])
        elif block:
            tables.append(block)
            block = []
    requirements: list[dict[str, str]] = []
    for tab in tables:
        if tab[0][0] == "Номер":
            header = tab[0]
            for row in tab[2:]:
                if re.fullmatch(r"(?:БТ|СТ)-РР-\d{2}", row[0]):
                    if len(row) != len(header):
                        raise ValueError(f"Неверное число столбцов: {row[0]}")
                    requirements.append(dict(zip(header, row)))
    ids = [row["Номер"] for row in requirements]
    return {
        "blob": actual,
        "bytes": len(data),
        "characters": len(text),
        "lines": len(text.splitlines()),
        "requirements": len(requirements),
        "unique_ids": len(set(ids)),
        "tables": len(tables),
        "malformed_tables": sum(any(len(row) != len(tab[0]) for row in tab) for tab in tables),
        "source_fields": sum(bool(row.get("Источник")) for row in requirements),
        "verification_fields": sum(bool(row.get("Условие проверки и ожидаемый результат")) for row in requirements),
        "h1": sum(bool(re.match(r"^# ", line)) for line in text.splitlines()),
        "h2": sum(bool(re.match(r"^## ", line)) for line in text.splitlines()),
        "ids": ids,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3],
                        help="Локальная копия репозитория с проверяемой фиксацией")
    parser.add_argument("--snapshot-dir", type=Path,
                        help="Вместо Git прочитать полученные отдельно файлы; идентификаторы всё равно проверяются")
    args = parser.parse_args()
    documents: dict[str, object] = {}
    try:
        for name, expected in EXPECTED.items():
            if args.snapshot_dir is not None:
                data = (args.snapshot_dir / name).read_bytes()
            else:
                result = subprocess.run(
                    ["git", "-C", str(args.repo), "show", f"{SNAPSHOT}:{name}"],
                    check=True, capture_output=True, timeout=30,
                )
                data = result.stdout
            documents[name] = analyze(data, expected)
    except (OSError, UnicodeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Подсчёт не выполнен: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"snapshot": SNAPSHOT, "documents": documents}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
