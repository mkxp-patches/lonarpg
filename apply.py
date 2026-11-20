#!/usr/bin/env python3
"""Reproducible installer, verifier, and reverter for LonaRPG B.0.10.7.5 on JoiPlay."""

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
DROPIN_SRC = REPO_DIR / "files" / "ModScripts" / "99990_joiplay_perf.rb"
DROPIN_REL = Path("ModScripts") / "99990_joiplay_perf.rb"

DEFAULT_GAME_DIRS = (
    Path("/storage/emulated/0/Games/Windows/LonaRPG"),
    Path.home() / "storage/shared/Games/Windows/LonaRPG",
)

INI_CACHE_OVERRIDES = (
    ("DisablePartsClear", "1"),
    ("DisableChsMaterialClear", "1"),
    ("DisableChsDataCacheClear", "1"),
)


@dataclass(frozen=True)
class TextPatch:
    name: str
    relpath: str
    old: str
    new: str


VANILLA_PATCHES = (
    TextPatch(
        name="01-commandline-args",
        relpath="Data/Scripts/0_CommandLineArgs.rb",
        old=(
            'fnGetCommandLine = Win32API.new("Kernel32", "GetCommandLine", "", "P")\n'
            "ARGV = Shellwords.shellwords(fnGetCommandLine.call)\n"
            "ARGV.shift"
        ),
        new=(
            'fnGetCommandLine = Win32API.new("Kernel32", "GetCommandLine", "", "P")\n'
            "_cmd = fnGetCommandLine.call\n"
            "ARGV = _cmd.is_a?(String) ? Shellwords.shellwords(_cmd) : []\n"
            "ARGV.shift"
        ),
    ),
    TextPatch(
        name="02-rubytool-prp",
        relpath="Data/Scripts/20_RubyTool.rb",
        old="        $PRP_REC << [val,color]\n        p val\n    end",
        new="        $PRP_REC << [val,color]\n        p val if $TEST\n    end",
    ),
    TextPatch(
        name="03-gamelona-ini-sleep",
        relpath="Data/Scripts/50_Create_GameLonaINI.rb",
        old=(
            "sleep 0.1\n"
            '$LonaINI = IniFile.load(userDir + "GameLona.ini")\n'
            '$GameINI = IniFile.load("Game.ini")\n'
            "sleep 0.9"
        ),
        new=(
            '$LonaINI = IniFile.load(userDir + "GameLona.ini")\n'
            '$GameINI = IniFile.load("Game.ini")'
        ),
    ),
    TextPatch(
        name="04-loading-screen-throttle",
        relpath="Data/Scripts/70_CreateLoadingScreen.rb",
        old=(
            "\tdef update(tmp_text)\n"
            "\t\t@count += 1\n"
            "\t\tnext_text(tmp_text)\n"
            "\t\tif @count >= @countTar\n"
            "\t\t\tnext_pic\n"
            "\t\t\tGraphics.update\n"
            "\t\t\t@count = 0\n"
            "\t\tend\n"
            "\tend"
        ),
        new=(
            "\tdef update(tmp_text)\n"
            "\t\t@count += 1\n"
            "\t\tnext_text(tmp_text)\n"
            "\t\tnow = Time.now.to_f\n"
            "\t\tif @jp_last_upd.nil? || (now - @jp_last_upd) >= 0.25\n"
            "\t\t\tnext_pic\n"
            "\t\t\tGraphics.update\n"
            "\t\t\t@jp_last_upd = now\n"
            "\t\t\t@count = 0\n"
            "\t\tend\n"
            "\tend"
        ),
    ),
    TextPatch(
        name="05-palette-moot-case",
        relpath="ModScripts/PaletteChanger/9999_DEFAULT_Races.json",
        old=(
            '\t\t"palette_new": ["race/moot/eyes_moot.act",\n'
            '\t\t\t\t\t\t"race/moot/skin_moot.act",\n'
            '\t\t\t\t\t\t"race/moot/skin_h_moot.act"]'
        ),
        new=(
            '\t\t"palette_new": ["race/Moot/eyes_moot.act",\n'
            '\t\t\t\t\t\t"race/Moot/skin_moot.act",\n'
            '\t\t\t\t\t\t"race/Moot/skin_h_moot.act"]'
        ),
    ),
)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def resolve_game_dir(cli_dir: str | None) -> Path:
    if cli_dir:
        return Path(cli_dir).expanduser()
    for candidate in DEFAULT_GAME_DIRS:
        if candidate.is_dir():
            return candidate
    return DEFAULT_GAME_DIRS[0]


def read_text_preserve_eol(path: Path) -> tuple[str, bytes]:
    raw = path.read_bytes()
    eol = b"\r\n" if b"\r\n" in raw else b"\n"
    return raw.replace(b"\r\n", b"\n").decode("utf-8"), eol


def write_text_with_eol(path: Path, text_lf: str, eol: bytes) -> None:
    encoded = text_lf.encode("utf-8")
    if eol == b"\r\n":
        encoded = encoded.replace(b"\n", b"\r\n")
    path.write_bytes(encoded)


def inspect_cache_ini(text_lf: str) -> tuple[bool, list[str]]:
    in_cache = False
    found: dict[str, str] = {}
    for line in text_lf.splitlines():
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            in_cache = s.lower() == "[cache]"
            continue
        if in_cache and "=" in s and not s.startswith((";", "#")):
            k, v = s.split("=", 1)
            found[k.strip()] = v.strip()

    missing_or_diff = []
    for k, want in INI_CACHE_OVERRIDES:
        if found.get(k) != want:
            missing_or_diff.append(f"{k}={found.get(k)!r} (want {want!r})")
    return len(missing_or_diff) == 0, missing_or_diff


def update_cache_ini(text_lf: str, overrides: tuple[tuple[str, str], ...]) -> str:
    want = dict(overrides)
    remaining = dict(overrides)
    lines = text_lf.splitlines(keepends=True)
    out: list[str] = []
    in_cache = False
    saw_cache = False

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if in_cache and remaining:
                for k, v in remaining.items():
                    out.append(f"{k} = {v}\n")
                remaining.clear()
            in_cache = stripped.lower() == "[cache]"
            if in_cache:
                saw_cache = True
            out.append(line)
            continue

        if in_cache and "=" in stripped and not stripped.startswith((";", "#")):
            k = stripped.split("=", 1)[0].strip()
            if k in want:
                ending = "\n" if line.endswith("\n") else ""
                out.append(f"{k} = {want[k]}{ending}")
                remaining.pop(k, None)
                continue

        out.append(line)

    if in_cache and remaining:
        if out and not out[-1].endswith("\n"):
            out[-1] = out[-1] + "\n"
        for k, v in remaining.items():
            out.append(f"{k} = {v}\n")
        remaining.clear()
    elif not saw_cache:
        if out and not out[-1].endswith("\n"):
            out[-1] = out[-1] + "\n"
        out.append("\n[Cache]\n")
        for k, v in overrides:
            out.append(f"{k} = {v}\n")

    return "".join(out)


def cmd_check(game_dir: Path) -> int:
    if not DROPIN_SRC.is_file():
        print(f"ERROR: repo file missing: {DROPIN_SRC}", file=sys.stderr)
        return 2
    if not game_dir.is_dir():
        print(f"ERROR: game directory not found: {game_dir}", file=sys.stderr)
        return 2

    issues = 0

    # 1. Drop-in mod script
    dst_dropin = game_dir / DROPIN_REL
    src_hash = sha256_bytes(DROPIN_SRC.read_bytes())
    if not dst_dropin.is_file():
        print(f"MISSING: {DROPIN_REL}")
        issues += 1
    else:
        dst_hash = sha256_bytes(dst_dropin.read_bytes())
        if dst_hash != src_hash:
            print(f"MISMATCH: {DROPIN_REL} ({dst_hash[:12]} != {src_hash[:12]})")
            issues += 1
        else:
            print(f"OK: {DROPIN_REL} ({src_hash[:12]})")

    # 2. Five vanilla file patches
    for p in VANILLA_PATCHES:
        target = game_dir / p.relpath
        if not target.is_file():
            print(f"MISSING: {p.relpath}")
            issues += 1
            continue
        text, _ = read_text_preserve_eol(target)
        has_new = p.new in text
        has_old = p.old in text
        if has_new and not (has_old and p.old not in p.new):
            print(f"OK: {p.relpath} ({p.name})")
        elif has_old:
            print(f"UNPATCHED: {p.relpath} ({p.name})")
            issues += 1
        else:
            print(f"UNKNOWN_STATE: {p.relpath} ({p.name})")
            issues += 1

    # 3. UserData/GameLona.ini
    ini_path = game_dir / "UserData" / "GameLona.ini"
    if not ini_path.is_file():
        print("WARN: UserData/GameLona.ini missing (created on first game launch)")
    else:
        ini_text, _ = read_text_preserve_eol(ini_path)
        ok_ini, diffs = inspect_cache_ini(ini_text)
        if ok_ini:
            print("OK: UserData/GameLona.ini ([Cache] Disable*Clear = 1)")
        else:
            print(f"UNPATCHED: UserData/GameLona.ini ({', '.join(diffs)})")
            issues += 1

    # 4. settings.json
    settings_path = game_dir / "settings.json"
    if not settings_path.is_file():
        print("WARN: settings.json missing (created by JoiPlay on first run)")
    else:
        data = json.loads(settings_path.read_text(encoding="utf-8"))
        dbg = data.get("rpg", {}).get("debug", {}).get("boolean")
        if dbg is False:
            print("OK: settings.json (rpg.debug.boolean = false)")
        else:
            print(f"UNPATCHED: settings.json (rpg.debug.boolean = {dbg!r})")
            issues += 1

    return 1 if issues else 0


def cmd_apply(game_dir: Path) -> int:
    if not DROPIN_SRC.is_file():
        print(f"ERROR: repo file missing: {DROPIN_SRC}", file=sys.stderr)
        return 2
    if not game_dir.is_dir():
        print(f"ERROR: game directory not found: {game_dir}", file=sys.stderr)
        return 2

    errors = 0

    # 1. Drop-in mod script
    dst_dropin = game_dir / DROPIN_REL
    dst_dropin.parent.mkdir(parents=True, exist_ok=True)
    src_bytes = DROPIN_SRC.read_bytes()
    src_hash = sha256_bytes(src_bytes)
    if dst_dropin.is_file() and sha256_bytes(dst_dropin.read_bytes()) == src_hash:
        print(f"OK: {DROPIN_REL} already up to date ({src_hash[:12]})")
    else:
        if dst_dropin.is_file():
            bak = dst_dropin.with_suffix(dst_dropin.suffix + ".bak")
            if not bak.exists():
                bak.write_bytes(dst_dropin.read_bytes())
                print(f"BACKUP: {bak.relative_to(game_dir)}")
        dst_dropin.write_bytes(src_bytes)
        print(f"APPLIED: {DROPIN_REL} ({src_hash[:12]})")

    # 2. Five vanilla file patches
    for p in VANILLA_PATCHES:
        target = game_dir / p.relpath
        if not target.is_file():
            print(f"ERROR: missing target {p.relpath}", file=sys.stderr)
            errors += 1
            continue
        text, eol = read_text_preserve_eol(target)
        if p.new in text and (p.old in p.new or p.old not in text):
            print(f"OK: {p.relpath} already patched ({p.name})")
            continue
        count = text.count(p.old)
        if count != 1:
            print(
                f"ERROR: cannot apply {p.name} to {p.relpath} (expected 1 match, found {count})",
                file=sys.stderr,
            )
            errors += 1
            continue
        bak = target.with_suffix(target.suffix + ".bak")
        if not bak.exists():
            bak.write_bytes(target.read_bytes())
            print(f"BACKUP: {bak.relative_to(game_dir)}")
        write_text_with_eol(target, text.replace(p.old, p.new, 1), eol)
        print(f"APPLIED: {p.relpath} ({p.name})")

    # 3. UserData/GameLona.ini
    ini_path = game_dir / "UserData" / "GameLona.ini"
    if not ini_path.is_file():
        print("WARN: UserData/GameLona.ini not found yet; launch game once and re-run --apply")
    else:
        ini_text, eol = read_text_preserve_eol(ini_path)
        ok_ini, _ = inspect_cache_ini(ini_text)
        if ok_ini:
            print("OK: UserData/GameLona.ini already configured")
        else:
            bak = ini_path.with_suffix(".ini.bak")
            if not bak.exists():
                bak.write_bytes(ini_path.read_bytes())
                print(f"BACKUP: {bak.relative_to(game_dir)}")
            new_ini = update_cache_ini(ini_text, INI_CACHE_OVERRIDES)
            write_text_with_eol(ini_path, new_ini, eol)
            print("APPLIED: UserData/GameLona.ini ([Cache] Disable*Clear = 1)")

    # 4. settings.json
    settings_path = game_dir / "settings.json"
    if not settings_path.is_file():
        print("WARN: settings.json not found yet; launch once via JoiPlay and re-run --apply")
    else:
        raw_settings = settings_path.read_text(encoding="utf-8")
        data = json.loads(raw_settings)
        dbg = data.get("rpg", {}).get("debug", {}).get("boolean")
        if dbg is False:
            print("OK: settings.json already configured")
        else:
            bak = settings_path.with_suffix(".json.bak")
            if not bak.exists():
                bak.write_text(raw_settings, encoding="utf-8")
                print(f"BACKUP: {bak.relative_to(game_dir)}")
            data.setdefault("rpg", {}).setdefault("debug", {})["boolean"] = False
            settings_path.write_text(
                json.dumps(data, separators=(",", ":"), ensure_ascii=False),
                encoding="utf-8",
            )
            print("APPLIED: settings.json (rpg.debug.boolean = false)")

    return 1 if errors else 0


def cmd_revert(game_dir: Path) -> int:
    if not game_dir.is_dir():
        print(f"ERROR: game directory not found: {game_dir}", file=sys.stderr)
        return 2

    # 1. Drop-in + generated boot cache
    dst_dropin = game_dir / DROPIN_REL
    dropin_bak = dst_dropin.with_suffix(dst_dropin.suffix + ".bak")
    if dropin_bak.is_file():
        dst_dropin.write_bytes(dropin_bak.read_bytes())
        dropin_bak.unlink()
        print(f"REVERTED: restored {DROPIN_REL} from backup")
    elif dst_dropin.is_file():
        dst_dropin.unlink()
        print(f"REVERTED: removed {DROPIN_REL}")

    boot_cache = game_dir / "Data" / "jp_boot_cache.rvdata2"
    if boot_cache.is_file():
        boot_cache.unlink()
        print("REVERTED: removed Data/jp_boot_cache.rvdata2")

    # 2. Vanilla file patches
    for p in VANILLA_PATCHES:
        target = game_dir / p.relpath
        bak = target.with_suffix(target.suffix + ".bak")
        if bak.is_file():
            target.write_bytes(bak.read_bytes())
            bak.unlink()
            print(f"REVERTED: restored {p.relpath} from backup")
        elif target.is_file():
            text, eol = read_text_preserve_eol(target)
            if p.new in text and (p.old not in p.new):
                write_text_with_eol(target, text.replace(p.new, p.old, 1), eol)
                print(f"REVERTED: reverse-patched {p.relpath}")

    # 3. UserData/GameLona.ini
    ini_path = game_dir / "UserData" / "GameLona.ini"
    ini_bak = ini_path.with_suffix(".ini.bak")
    if ini_bak.is_file():
        ini_path.write_bytes(ini_bak.read_bytes())
        ini_bak.unlink()
        print("REVERTED: restored UserData/GameLona.ini from backup")
    elif ini_path.is_file():
        ini_text, eol = read_text_preserve_eol(ini_path)
        reset = tuple((k, "0") for k, _ in INI_CACHE_OVERRIDES)
        write_text_with_eol(ini_path, update_cache_ini(ini_text, reset), eol)
        print("REVERTED: reset [Cache] Disable*Clear = 0 in UserData/GameLona.ini")

    # 4. settings.json
    settings_path = game_dir / "settings.json"
    settings_bak = settings_path.with_suffix(".json.bak")
    if settings_bak.is_file():
        settings_path.write_bytes(settings_bak.read_bytes())
        settings_bak.unlink()
        print("REVERTED: restored settings.json from backup")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install, verify, or revert LonaRPG B.0.10.7.5 JoiPlay patches."
    )
    parser.add_argument(
        "--game-dir",
        help="Path to the LonaRPG game folder (default: /storage/emulated/0/Games/Windows/LonaRPG)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true", help="Apply all patches (default)")
    mode.add_argument("--check", action="store_true", help="Verify patch status without editing")
    mode.add_argument("--revert", action="store_true", help="Revert all patches cleanly")

    args = parser.parse_args()
    game_dir = resolve_game_dir(args.game_dir)

    if args.check:
        return cmd_check(game_dir)
    if args.revert:
        return cmd_revert(game_dir)
    return cmd_apply(game_dir)


if __name__ == "__main__":
    raise SystemExit(main())
