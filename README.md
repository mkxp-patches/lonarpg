# LonaRPG — JoiPlay Performance, Compatibility & Boot Cache Patch

> **Disclaimer:** Unofficial community performance & compatibility patch. This repository contains no copyrighted game assets, archives, or full game scripts, and requires an existing copy of the base game.

Performance, Android compatibility, and startup boot-cache optimizations for **LonaRPG B.0.10.7.5** running on **JoiPlay** (`libmkxp19.so`, Ruby 1.9.2, RGSS3).

## Measured Results (POCO F6 / Android 16 / JoiPlay `libmkxp19.so`)

| Metric | Result |
|---|---|
| Active gameplay (Map 65, 75 events) | **58.3–59.3 FPS** (`avg=16.59ms`, `sp50=1`) |
| `DataManager.load_normal_database` (cold boot) | **13,146.1–15,860.7 ms** (writes `Data/jp_boot_cache.rvdata2`, **6,047 KB**) |
| `DataManager.load_normal_database` (cached boot #2+) | **944.2 ms** (`BOOT_CACHE HIT`, ~15× faster than cold boot) |

## Repository Structure

### 1. Drop-in Mod Script (`files/ModScripts/99990_joiplay_perf.rb`)
Loads at priority `99990` (after `500_Mod_loader.rb` and `65535_PrevSaveSupport.rb`) before `Main.rb`:
- **Patch 1 (Save safety):** Fixes `Cache.savefile_bitmap` cache lookup with fallback to `Graphics/System/SaveNotFound.png` (prevents crashes on `.path_cache` misses for newly created save PNGs) and stubs `DataManager.make_save_screenshot` on MKXP.
- **Patch 2 (Dead Windows/x86 bypass):** Restores `Bitmap#initialize` to `initialize_pre_failsafe` (bypassing `RtlMoveMemory` checks), stubs `BitmapChanger.load_settings` / `find_cache_name` / `change_bitmap`, and stubs `WolfPad.update` and `Shadow` (`draw`, `clear`, `draw_lights`) on MKXP.
- **Patch 3 (Sprite & character rendering):** Rewrites `Sprite_Character` (`update`, `need_update?`, `update_bitmap`, dirty-checked `update_src_rect`, `update_position`, `update_other`, `update_tone`) and single-pass `Spriteset_Map#update_characters`.
- **Patch 4 (Event & AI loop allocations):** Zero-allocation `Game_Map#update_events` (reuses `@jp_del_keys`, skips `backgroundEvent`), `Game_Event` (`update`, `check_event_trigger_region`, `npc_disabled?`, cached `current_page_charset?`), and `Game_CharacterBase#update_character_ex_effects`.
- **Patch 5 (Map/tile queries & sensor memoization):** Zero-allocation `Game_Map` helpers (`spec_dir_blocker_passable?`, `check_passage`, `layered_tiles_flag?`, `get_event_terrain_tag`, `terrain_tag`) and memoized `detection_array` on `Sensors::Basic_Sensor` subclasses.
- **Patch 6 (HUD & scene transitions):** Fixes/memoizes `Map_Hud` (`refresh_face`, `refresh_mood_meter`, `refresh_exp_meter`) and speeds `Scene_Base#transition_speed` from `10` to `4`.
- **Patch 7 (Transfer GC):** Runs `GC.start` inside `Scene_Map#perform_transfer`.
- **Patch 8 (Fast JSON parser):** Replaces `JSON.decode` with `::JPFastJSON.decode` (C-regex tokenizer with fallback to `jpopt_orig_decode`).
- **Patch 9 (Self-validating Marshal boot cache):** Captures/restores all loaded database globals + `LONA_PORTRAIT_CANVAS_SETTING` + `NPC_Portrait` hashes in `Data/jp_boot_cache.rvdata2` (keyed by game version, `UserData/GameMods.ini` content, `ModScripts/_Mods/*`, and `Data/System.rvdata2` size).

### 2. Early-Boot & Case-Sensitivity Unified Diffs (`patches/`)
These run before `ModScripts/` loads (or are static data JSON) and are stored both as standard unified diffs and in `apply.py`:
- `01-commandline-args.patch` — `Data/Scripts/0_CommandLineArgs.rb`: guards `Kernel32.GetCommandLine` returning `0` on MKXP before `Shellwords.shellwords`.
- `02-rubytool-prp.patch` — `Data/Scripts/20_RubyTool.rb`: gates `p val` inside `prp` behind `if $TEST` to avoid excessive FUSE log writes while keeping `$PRP_REC`.
- `03-gamelona-ini-sleep.patch` — `Data/Scripts/50_Create_GameLonaINI.rb`: removes `sleep 0.1` + `sleep 0.9` on boot.
- `04-loading-screen-throttle.patch` — `Data/Scripts/70_CreateLoadingScreen.rb`: throttles `Loading_Screen#update` `Graphics.update` calls to at most once every `0.25s` by wall clock.
- `05-palette-moot-case.patch` — `ModScripts/PaletteChanger/9999_DEFAULT_Races.json`: fixes `"race/moot/..."` -> `"race/Moot/..."` for Android case sensitivity.
- `all-vanilla-fixes.patch` — Combined patch applicable with `patch -p1 < patches/all-vanilla-fixes.patch`.

### 3. Config Tweaks (merged in place by `apply.py`)
- `UserData/GameLona.ini`: sets `[Cache]` `DisablePartsClear = 1`, `DisableChsMaterialClear = 1`, `DisableChsDataCacheClear = 1`.
- `settings.json`: sets `rpg.debug.boolean` to `false`.

## Usage

```bash
# Check whether patches & config are applied in /storage/emulated/0/Games/Windows/LonaRPG
python3 apply.py --check

# Apply drop-in script, 5 vanilla fixes, and INI/JSON tweaks (creates .bak files automatically)
python3 apply.py --apply

# Revert all patches and restore backups
python3 apply.py --revert

# Custom game folder
python3 apply.py --apply --game-dir "/path/to/LonaRPG"
```

Or apply the 5 vanilla diffs directly with standard GNU `patch`:

```bash
patch -d "/storage/emulated/0/Games/Windows/LonaRPG" -p1 < patches/all-vanilla-fixes.patch
```
