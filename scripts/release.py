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
    - install.sh         (EPHOR_TAG for Zig 0.16.0+)
    - README.md          (JSON example only, NOT changelog. The install URL
                          tracks the latest remote tag per check-version.sh
                          section 3. Bump it manually in the first post-tag
                          commit.)
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


def replace_in_file(
    path: Path,
    replacements: list[tuple[str, str]],
    dry_run: bool = False,
    flags: int = 0,
) -> bool:
    """
    Apply regex replacements to a file.
    Returns True if any replacement was made.
    """
    text = path.read_text()
    original = text
    for pattern, repl in replacements:
        text = re.sub(pattern, repl, text, flags=flags)
    if text == original:
        return False
    if not dry_run:
        path.write_text(text)
    return True


def bump_build_zig_zon(old: str, new: str, dry_run: bool) -> None:
    path = REPO_ROOT / "build.zig.zon"
    changed = replace_in_file(
        path,
        [
            # Only match .version field on its own line
            (rf'^(\s*\.version\s*=\s*"){re.escape(old)}("\s*,)', rf'\g<1>{new}\g<2>'),
        ],
        dry_run,
        flags=re.MULTILINE,
    )
    print(f"  {'✓' if changed else '○'} build.zig.zon")


def bump_main_zig(old: str, new: str, dry_run: bool) -> None:
    path = REPO_ROOT / "src" / "main.zig"
    old_re = re.escape(old)
    changed = replace_in_file(path, [
        # EPHOR_VERSION constant
        (rf'(const EPHOR_VERSION = "){old_re}(")', rf'\g<1>{new}\g<2>'),
        # --version=X.Y.Z in help text
        (rf'(--version=){old_re}', rf'\g<1>{new}'),
        # "version": "X.Y.Z" in JSON example
        (rf'("version": "){old_re}(")', rf'\g<1>{new}\g<2>'),
    ], dry_run)
    print(f"  {'✓' if changed else '○'} src/main.zig")


def bump_install_sh(old: str, new: str, dry_run: bool) -> None:
    # EPH-I0253: this rewrite is dead. install.sh computes EPHOR_TAG at
    # runtime, so the pattern never matches. EPHOR_FALLBACK_TAG in
    # install.sh and install.ps1 bumps manually in the first post-tag
    # commit (mega-audit file-scripts.md finding 3).
    path = REPO_ROOT / "install.sh"
    old_re = re.escape(old)
    changed = replace_in_file(path, [
        # EPHOR_TAG="vX.Y.Z" for the 0.16.0+ branch
        (rf'(EPHOR_TAG="v){old_re}(")', rf'\g<1>{new}\g<2>'),
    ], dry_run)
    print(f"  {'✓' if changed else '○'} install.sh")


def bump_readme(old: str, new: str, dry_run: bool) -> None:
    """Bump the JSON example version only. Never rewrite the install URL.

    EPH-I0702, EPH-I0188: the install URL tracks the latest remote tag
    (check-version.sh section 3), not the zon version. Rewriting it here
    re-creates a 404 on every release cycle. It bumps manually in the first
    post-tag commit. verify_bumped skips README.md for the same reason:
    the changelog and the install URL legitimately keep older versions
    (mega-audit file-scripts.md finding 2, EPH-I0656).
    """
    path = REPO_ROOT / "README.md"
    old_re = re.escape(old)
    changed = replace_in_file(path, [
        # JSON example: "version": "X.Y.Z"
        (rf'("version": "){old_re}(")', rf'\g<1>{new}\g<2>'),
    ], dry_run)
    print(f"  {'✓' if changed else '○'} README.md")


# Production locations that carry the release version. Only these lines
# matter for a bump. Test fixtures and help-text examples elsewhere in
# src/main.zig keep older versions by design (EPH-I0765). install.sh is
# excluded: EPHOR_FALLBACK_TAG keeps the old tag until the first post-tag
# commit (EPH-I0702). scripts/check-version.sh section 5 governs that
# post-tag bump. EPH-I0253 tracks the dead EPHOR_TAG rewrite.
VERSION_PATTERNS = [
    (REPO_ROOT / "build.zig.zon", r'^\s*\.version\s*=\s*"{}"'),
    (REPO_ROOT / "src" / "main.zig", r'const EPHOR_VERSION = "{}"'),
]


def verify_bumped(old: str, new: str) -> None:
    """Verify the bump: the old version is gone and the new version is
    present at every production pattern in VERSION_PATTERNS."""
    stale: list[str] = []
    missing: list[str] = []
    for path, template in VERSION_PATTERNS:
        text = path.read_text()
        old_re = template.format(re.escape(old))
        for i, line in enumerate(text.splitlines(), 1):
            if re.search(old_re, line):
                stale.append(f"  {path.name}:{i}: {line.strip()}")
        new_re = template.format(re.escape(new))
        if not re.search(new_re, text, re.MULTILINE):
            missing.append(f"  {path.name}: no line matches {template.format(new)!r}")
    if stale:
        print(f"\nerror: stale references to {old} found:")
        for line in stale:
            print(line)
    if missing:
        print(f"\nerror: version {new} missing from a production location:")
        for line in missing:
            print(line)
    if stale or missing:
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

    if old_version == new_version:
        print(f"error: already at version {new_version}")
        sys.exit(1)

    mode = "(dry-run)" if dry_run else ""
    print(f"Bumping ephor {old_version} → {new_version} {mode}")
    print()

    bump_build_zig_zon(old_version, new_version, dry_run)
    bump_main_zig(old_version, new_version, dry_run)
    bump_install_sh(old_version, new_version, dry_run)
    bump_readme(old_version, new_version, dry_run)

    if dry_run:
        print("\nDry run complete. No files were modified.")
        sys.exit(0)

    verify_bumped(old_version, new_version)

    print("\nAll files updated and verified.")
    print("Next steps:")
    print(f'  git add -A')
    print(f'  git commit -m "chore: bump version to {new_version}"')
    print(f'  git tag v{new_version}')
    print(f'  git push origin main && git push origin v{new_version}')


if __name__ == "__main__":
    main()
