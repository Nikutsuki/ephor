#!/usr/bin/env python3
"""
Ephor release version bump script.

Usage:
    python3 scripts/release.py <new_version>
    python3 scripts/release.py <new_version> --dry-run

Example:
    python3 scripts/release.py 0.12.7

Files updated:
    - build.zig.zon      (the .version field)
    - src/main.zig       (EPHOR_VERSION const + help text examples)
    - README.md          (the JSON example only. The changelog and the
                          install URL keep other versions: the install URL
                          tracks the latest remote tag (check-version.sh
                          section 3) and bumps in the first post-tag commit.)

Not rewritten by this script:
    - install.sh and install.ps1 keep EPHOR_FALLBACK_TAG at the previous
      release until the first post-tag commit (EPH-I0702, check-version.sh
      sections 5 and 5b). The EPHOR_TAG rewrite in install.sh is dead code,
      tracked by EPH-I0253.

Guards (EPH-I0663, EPH-I0656):
    - A new version equal to or below the current version is refused.
    - A bump that changes nothing on a required surface fails the run.
    - Every file is rewritten in memory, verified, then written. A failed
      verification leaves the tree untouched.
"""

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent


def extract_version_from_zon() -> str:
    """Read the current ephor version from build.zig.zon."""
    zon = (REPO_ROOT / "build.zig.zon").read_text()
    m = re.search(r'^\s*\.version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"', zon, re.MULTILINE)
    if not m:
        print("error: could not find .version in build.zig.zon", file=sys.stderr)
        sys.exit(1)
    return m.group(1)


def version_tuple(version: str) -> tuple[int, int, int]:
    """Parse a strict X.Y.Z string into comparable ints (EPH-I0663)."""
    major, minor, patch = version.split(".")
    return int(major), int(minor), int(patch)


def compute_replacements(
    path: Path,
    replacements: list[tuple[str, str]],
    flags: int = 0,
) -> tuple[str, bool]:
    """
    Apply regex replacements to file content in memory.
    Return the new content and whether anything changed. Never write:
    the files are written only after all of them verify (EPH-I0663).
    """
    text = path.read_text()
    original = text
    for pattern, repl in replacements:
        text = re.sub(pattern, repl, text, flags=flags)
    return text, text != original


def prepare_bumps(old: str, new: str) -> list[tuple[Path, str, bool]]:
    """Compute every bumped file's new content in memory. Nothing is
    written here (EPH-I0663)."""
    old_re = re.escape(old)

    def bump(path: Path, replacements: list[tuple[str, str]], flags: int = 0):
        content, changed = compute_replacements(path, replacements, flags)
        return path, content, changed

    return [
        # Only match the .version field on its own line.
        bump(
            REPO_ROOT / "build.zig.zon",
            [(rf'^(\s*\.version\s*=\s*"){old_re}("\s*,)', rf'\g<1>{new}\g<2>')],
            flags=re.MULTILINE,
        ),
        bump(REPO_ROOT / "src" / "main.zig", [
            # EPHOR_VERSION constant
            (rf'(const EPHOR_VERSION = "){old_re}(")', rf'\g<1>{new}\g<2>'),
            # --version=X.Y.Z in help text. The rewrite targets the printHelp
            # examples. Test fixtures pin non-current versions so this pattern
            # never matches them (EPH-I0770).
            (rf'(--version=){old_re}', rf'\g<1>{new}'),
            # "version": "X.Y.Z" in JSON example
            (rf'("version": "){old_re}(")', rf'\g<1>{new}\g<2>'),
        ]),
        # EPH-I0253: this rewrite is dead. install.sh computes EPHOR_TAG at
        # runtime, so the pattern never matches. EPHOR_FALLBACK_TAG in
        # install.sh and install.ps1 bumps manually in the first post-tag
        # commit (mega-audit file-scripts.md finding 3).
        bump(REPO_ROOT / "install.sh", [
            (rf'(EPHOR_TAG="v){old_re}(")', rf'\g<1>{new}\g<2>'),
        ]),
        # The JSON example only. Never rewrite the install URL: it tracks the
        # latest remote tag (check-version.sh section 3), not the zon version
        # (EPH-I0702, EPH-I0188).
        bump(REPO_ROOT / "README.md", [
            (rf'("version": "){old_re}(")', rf'\g<1>{new}\g<2>'),
        ]),
    ]


# Surfaces whose bump must change something (EPH-I0656). A no-op bump here
# means the old version string was not found where the release model
# requires it. install.sh is exempt: its EPHOR_TAG rewrite is dead code
# (EPH-I0253), and a release that fails on dead code could never land.
REQUIRED_SURFACES = {
    REPO_ROOT / "build.zig.zon",
    REPO_ROOT / "src" / "main.zig",
    REPO_ROOT / "README.md",
}


# Production locations that carry the release version. Only these lines
# matter for a bump. Test fixtures and help-text examples elsewhere in
# src/main.zig keep older versions by design (EPH-I0765). install.sh and
# install.ps1 are not in the pattern list: their EPHOR_FALLBACK_TAG keeps
# the old tag until the first post-tag commit (EPH-I0702), and
# check-version.sh sections 5 and 5b govern that post-tag bump. The README
# pattern is scoped to the JSON example, so the changelog and the install
# URL legitimately keep older versions (EPH-I0656).
VERSION_PATTERNS = [
    (REPO_ROOT / "build.zig.zon", r'^\s*\.version\s*=\s*"{}"'),
    (REPO_ROOT / "src" / "main.zig", r'const EPHOR_VERSION = "{}"'),
    (REPO_ROOT / "README.md", r'"version": "{}"'),
]


def verify_bumped(old: str, new: str, contents: dict[Path, str]) -> None:
    """Verify the bump on the given contents: the old version is gone and
    the new version is present at every production pattern, and no
    installer fallback names the untagged version. The check reads the
    contents dict, never the files, so it runs before the write as well
    as after it (EPH-I0663)."""
    stale: list[str] = []
    missing: list[str] = []
    for path, template in VERSION_PATTERNS:
        text = contents[path]
        old_re = template.format(re.escape(old))
        for i, line in enumerate(text.splitlines(), 1):
            if re.search(old_re, line):
                stale.append(f"  {path.name}:{i}: {line.strip()}")
        new_re = template.format(re.escape(new))
        if not re.search(new_re, text, re.MULTILINE):
            missing.append(f"  {path.name}: no line matches {template.format(new)!r}")

    # EPH-I0656: the installer fallbacks join the checked surfaces. Each
    # fallback keeps the previous release until the first post-tag commit
    # (EPH-I0702), but it must never name the untagged version under
    # development: installs would fetch a 404 archive during an API
    # outage. The premature pin is the defect this guard catches.
    fallback_new = re.compile(rf'\$?EPHOR_FALLBACK_TAG\s*=\s*"v{re.escape(new)}"')
    premature: list[str] = []
    for path in (REPO_ROOT / "install.sh", REPO_ROOT / "install.ps1"):
        for i, line in enumerate(contents[path].splitlines(), 1):
            if fallback_new.search(line):
                premature.append(f"  {path.name}:{i}: {line.strip()}")

    if stale:
        print(f"\nerror: stale references to {old} found:")
        for line in stale:
            print(line)
    if premature:
        print(f"\nerror: an installer fallback names the untagged version {new}:")
        for line in premature:
            print(line)
        print("The fallbacks move to the new tag in the first post-tag commit.")
    if missing:
        print(f"\nerror: version {new} missing from a production location:")
        for line in missing:
            print(line)
    if stale or missing or premature:
        print("Fix the files above, then run the bump again.")
        sys.exit(1)


def main() -> None:
    dry_run = "--dry-run" in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith("-")]

    if len(args) != 1:
        print(__doc__)
        sys.exit(1)

    new_version = args[0]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", new_version):
        print(f"error: version must be semver-ish (X.Y.Z), got: {new_version}")
        sys.exit(1)

    old_version = extract_version_from_zon()

    # EPH-I0663: refuse an equal or lower version before any file is read
    # for rewriting. A downgrade used to succeed and half-bumped the tree.
    if version_tuple(new_version) == version_tuple(old_version):
        print(f"error: already at version {new_version}")
        sys.exit(1)
    if version_tuple(new_version) < version_tuple(old_version):
        print(f"error: refusing downgrade from {old_version} to {new_version}")
        sys.exit(1)

    mode = "(dry-run)" if dry_run else ""
    print(f"Bumping ephor {old_version} → {new_version} {mode}")
    print()

    pending = prepare_bumps(old_version, new_version)
    for path, _, changed in pending:
        print(f"  {'✓' if changed else '○'} {path.relative_to(REPO_ROOT)}")

    # EPH-I0656: a bump that changes nothing on a required surface is a
    # defect, not a pass. It means the old version string is missing from
    # a file the release model requires it in.
    noops = [
        path.relative_to(REPO_ROOT)
        for path, _, changed in pending
        if path in REQUIRED_SURFACES and not changed
    ]
    if noops:
        print()
        for label in noops:
            print(f"error: the {label} bump would change nothing: "
                  f"version {old_version} not found there")
        print("Fix the files above, then run the bump again.")
        sys.exit(1)

    # Verify the new contents in memory, then write, then verify the
    # written files (EPH-I0663). install.ps1 is read for the fallback
    # guard even though this script never rewrites it.
    contents = {path: content for path, content, _ in pending}
    contents[REPO_ROOT / "install.ps1"] = (REPO_ROOT / "install.ps1").read_text()
    verify_bumped(old_version, new_version, contents)

    if dry_run:
        print("\nDry run complete. No files were modified.")
        sys.exit(0)

    for path, content, _ in pending:
        path.write_text(content)

    verify_bumped(old_version, new_version, {path: path.read_text() for path in contents})

    print("\nAll files updated and verified.")
    print("Next steps:")
    print("  git add -A")
    print(f'  git commit -m "chore: bump version to {new_version}"')
    print(f"  git tag v{new_version}")
    print(f"  git push origin main && git push origin v{new_version}")


if __name__ == "__main__":
    main()
