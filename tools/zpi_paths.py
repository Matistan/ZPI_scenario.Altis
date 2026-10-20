"""
Where things are, worked out from where this tools folder sits.

Expected layout (the whole mission folder can be one git repository):

    <Arma profile>\\                      e.g. Documents\\Arma 3  or  Documents\\Arma 3 - Other Profiles\\<name>
      missions\\<Mission>.<World>\\        e.g. missions\\ZPI_scenario.Altis  (mission = repository root)
        mission.sqm, description.ext, init.sqf, zpi\\ ...
        tools\\                           <- this folder
        output\\                          <- everything the tools make (datasets, orthophotos, ...; not in git)
      Screenshots\\zpi\\<session>\\        <- screenshots taken by the mission
    %LOCALAPPDATA%\\Arma 3\\*.rpt          <- game logs with the labels and telemetry

If the tools folder is NOT inside a mission folder (old layout, e.g. Documents\\ZPI\\tools), the
screenshots are searched in the usual Documents locations and outputs go to the current folder.
"""
from __future__ import annotations

import glob
import os
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent


def _is_mission(p: Path) -> bool:
    return (p / "zpi").is_dir() and ((p / "init.sqf").exists() or (p / "description.ext").exists())


MISSION_DIR: Path | None = TOOLS_DIR.parent if _is_mission(TOOLS_DIR.parent) else None

# Arma profile folder: <profile>\missions\<mission>  (also mpmissions)
PROFILE_DIR: Path | None = None
if MISSION_DIR is not None and MISSION_DIR.parent.name.lower() in ("missions", "mpmissions"):
    PROFILE_DIR = MISSION_DIR.parent.parent

# everything the tools write goes here (ignored by git, see .gitignore)
OUTPUT_DIR: Path = (MISSION_DIR / "output") if MISSION_DIR is not None else Path.cwd()


def out_path(p: str | os.PathLike) -> Path:
    """Output location: absolute paths stay as they are, names go into OUTPUT_DIR."""
    p = Path(p)
    return p if p.is_absolute() else OUTPUT_DIR / p


def _home() -> Path:
    return Path(os.environ.get("USERPROFILE", str(Path.home())))


def _documents() -> list[Path]:
    h = _home()
    return [h / "Documents", h / "Dokumenty"] + [Path(p) for p in glob.glob(str(h / "OneDrive*" / "Documents"))] \
        + [Path(p) for p in glob.glob(str(h / "OneDrive*" / "Dokumenty"))]


def screenshot_dirs() -> list[Path]:
    """Arma Screenshots folders, the one of this mission's profile first."""
    dirs: list[Path] = []
    if PROFILE_DIR is not None:
        dirs.append(PROFILE_DIR / "Screenshots")
    for docs in _documents():
        dirs.append(docs / "Arma 3" / "Screenshots")
        dirs += [Path(p) for p in glob.glob(str(docs / "Arma 3 - Other Profiles" / "*" / "Screenshots"))]
    seen, out = set(), []
    for d in dirs:
        k = str(d).lower()
        if k not in seen:
            seen.add(k)
            out.append(d)
    existing = [d for d in out if d.exists()]
    return existing or out[:1]


def rpt_dir() -> Path:
    """Folder with the game logs (%LOCALAPPDATA%\\Arma 3)."""
    local = os.environ.get("LOCALAPPDATA")
    return Path(local) / "Arma 3" if local else _home() / "AppData" / "Local" / "Arma 3"


def rpt_files() -> list[Path]:
    """Every game log, oldest first (a new log starts at every game launch)."""
    return [Path(f) for f in sorted(glob.glob(str(rpt_dir() / "*.rpt")), key=os.path.getmtime)]


def find_mission() -> Path | None:
    """This mission (when the tools are inside it), else the first ZPI mission in the profiles."""
    if MISSION_DIR is not None:
        return MISSION_DIR
    for docs in _documents():
        for pattern in ("Arma 3*/missions/*", "Arma 3*/mpmissions/*", "Arma 3 - Other Profiles/*/missions/*"):
            for p in sorted(docs.glob(pattern)):
                if _is_mission(p) and (p / "zpi" / "config.sqf").exists():
                    return p
    return None


def describe() -> str:
    return (f"mission: {MISSION_DIR or '(tools are not inside a mission folder)'}\n"
            f"screenshots: {', '.join(map(str, screenshot_dirs()))}\n"
            f"logs: {rpt_dir()}\n"
            f"output: {OUTPUT_DIR}")


if __name__ == "__main__":
    print(describe())
