#!/usr/bin/env python3
"""Audit WCAG 2.1 contrast ratios for every theme in apps/desktop/src/theme.zig.

Run from the repo root:

    python scripts/audit_contrast.py

The script parses theme.zig directly (no Zig compiler needed) and prints a
human-readable report plus the data the docs/reference/accessibility.md page
is built from. It uses only the Python standard library.

WCAG 2.1 targets used here:
  - AA normal text   : ratio >= 4.5   (foreground/background, accent/background)
  - AA large text    : ratio >= 3.0   (muted/background -- secondary text)
  - "Red on bg"      : ratio >= 4.5   (ansi[1] is used for error messages)
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import date
from pathlib import Path
from typing import Dict, List, Optional, Tuple


REPO_ROOT = Path(__file__).resolve().parent.parent
THEME_FILE = REPO_ROOT / "apps" / "desktop" / "src" / "theme.zig"

# Per-pair AA targets used by ZiggyZag. muted is documented secondary text, so
# we use the AA large-text threshold (3.0) for it; everything else uses the
# normal-text threshold (4.5).
TARGETS = {
    "fg_bg": 4.5,
    "accent_bg": 4.5,
    "muted_bg": 3.0,
    "red_bg": 4.5,
}


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

THEME_BLOCK_RE = re.compile(
    r"pub const (?P<symbol>\w+)\s*=\s*Theme\{(?P<body>.*?)\n\};",
    re.DOTALL,
)

FIELD_COLOR_RE = re.compile(
    r"\.(?P<field>\w+)\s*=\s*Color\.rgb\(\s*0x([0-9a-fA-F]{2})\s*,\s*"
    r"0x([0-9a-fA-F]{2})\s*,\s*0x([0-9a-fA-F]{2})\s*\)"
)

FIELD_STRING_RE = re.compile(r'\.(?P<field>\w+)\s*=\s*"(?P<value>[^"]*)"')

ANSI_ARRAY_RE = re.compile(
    r"\.ansi\s*=\s*\.\{(?P<body>.*?)\n\s*\}", re.DOTALL
)
ANSI_COLOR_RE = re.compile(
    r"Color\.rgb\(\s*0x([0-9a-fA-F]{2})\s*,\s*"
    r"0x([0-9a-fA-F]{2})\s*,\s*0x([0-9a-fA-F]{2})\s*\)"
)


def _hex(rgb: Tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)


def parse_themes(zig_source: str) -> List[Dict]:
    """Parse every `pub const <id> = Theme{ ... }` block into a dict.

    Returns a list of dicts with keys: symbol, id, name, background, foreground,
    accent, muted, ansi (list of 16 hex strings). Any structural problem
    (missing field, wrong ansi length) is captured in an `issues` list on the
    theme dict so the caller can report it instead of crashing.
    """
    themes: List[Dict] = []
    for match in THEME_BLOCK_RE.finditer(zig_source):
        symbol = match.group("symbol")
        body = match.group("body")

        # Skip the Theme struct definition itself if it ever matched.
        if symbol == "Theme":
            continue

        colors: Dict[str, Tuple[int, int, int]] = {}
        for color_match in FIELD_COLOR_RE.finditer(body):
            field = color_match.group("field")
            rgb = (
                int(color_match.group(2), 16),
                int(color_match.group(3), 16),
                int(color_match.group(4), 16),
            )
            colors[field] = rgb

        strings: Dict[str, str] = {}
        for string_match in FIELD_STRING_RE.finditer(body):
            strings[string_match.group("field")] = string_match.group("value")

        ansi_match = ANSI_ARRAY_RE.search(body)
        ansi: List[Tuple[int, int, int]] = []
        if ansi_match:
            for color_match in ANSI_COLOR_RE.finditer(ansi_match.group("body")):
                ansi.append(
                    (
                        int(color_match.group(1), 16),
                        int(color_match.group(2), 16),
                        int(color_match.group(3), 16),
                    )
                )

        issues: List[str] = []
        for required in ("background", "foreground", "accent", "muted"):
            if required not in colors:
                issues.append(f"missing field: {required}")
        if len(ansi) != 16:
            issues.append(f"ansi array length is {len(ansi)}, expected 16")

        themes.append(
            {
                "symbol": symbol,
                "id": strings.get("id", symbol),
                "name": strings.get("name", symbol),
                "background": colors.get("background"),
                "foreground": colors.get("foreground"),
                "accent": colors.get("accent"),
                "muted": colors.get("muted"),
                "ansi": ansi,
                "issues": issues,
            }
        )
    return themes


# ---------------------------------------------------------------------------
# WCAG math
# ---------------------------------------------------------------------------


def _channel_to_linear(c: int) -> float:
    s = c / 255.0
    if s <= 0.03928:
        return s / 12.92
    return ((s + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb: Tuple[int, int, int]) -> float:
    r, g, b = rgb
    return (
        0.2126 * _channel_to_linear(r)
        + 0.7152 * _channel_to_linear(g)
        + 0.0722 * _channel_to_linear(b)
    )


def contrast_ratio(a: Tuple[int, int, int], b: Tuple[int, int, int]) -> float:
    la = relative_luminance(a)
    lb = relative_luminance(b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


# ---------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------


def audit_theme(theme: Dict) -> Dict:
    """Return a dict with computed ratios and pass/fail per pair."""
    bg = theme["background"]
    fg = theme["foreground"]
    accent = theme["accent"]
    muted = theme["muted"]
    red = theme["ansi"][1] if len(theme["ansi"]) > 1 else None

    pairs = {
        "fg_bg": (fg, bg, TARGETS["fg_bg"]),
        "accent_bg": (accent, bg, TARGETS["accent_bg"]),
        "muted_bg": (muted, bg, TARGETS["muted_bg"]),
        "red_bg": (red, bg, TARGETS["red_bg"]),
    }

    results: Dict[str, Dict] = {}
    failures: List[Dict] = []
    for label, (a, b, target) in pairs.items():
        if a is None or b is None:
            results[label] = {"ratio": None, "target": target, "pass": False}
            failures.append(
                {
                    "label": label,
                    "ratio": None,
                    "target": target,
                    "fg_hex": _hex(a) if a else "n/a",
                    "bg_hex": _hex(b) if b else "n/a",
                }
            )
            continue
        ratio = contrast_ratio(a, b)
        passed = ratio >= target
        results[label] = {
            "ratio": ratio,
            "target": target,
            "pass": passed,
            "fg_hex": _hex(a),
            "bg_hex": _hex(b),
        }
        if not passed:
            failures.append(
                {
                    "label": label,
                    "ratio": ratio,
                    "target": target,
                    "fg_hex": _hex(a),
                    "bg_hex": _hex(b),
                }
            )

    return {
        "id": theme["id"],
        "name": theme["name"],
        "background_hex": _hex(bg) if bg else "n/a",
        "foreground_hex": _hex(fg) if fg else "n/a",
        "accent_hex": _hex(accent) if accent else "n/a",
        "muted_hex": _hex(muted) if muted else "n/a",
        "red_hex": _hex(red) if red else "n/a",
        "results": results,
        "failures": failures,
        "issues": theme["issues"],
        "passed": not failures and not theme["issues"],
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

PAIR_LABEL = {
    "fg_bg": "foreground/background",
    "accent_bg": "accent/background",
    "muted_bg": "muted/background",
    "red_bg": "ansi[1] red/background",
}


def fmt_ratio(value) -> str:
    if value is None:
        return "n/a"
    return f"{value:.2f}:1"


def _git_short_revision() -> Optional[str]:
    """Return the short revision of HEAD if available, else None."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    rev = result.stdout.strip()
    return rev or None


def build_markdown(audits: List[Dict]) -> str:
    total = len(audits)
    passing = sum(1 for a in audits if a["passed"])
    failing = total - passing

    lines: List[str] = []
    lines.append("# Theme accessibility audit")
    lines.append("")
    lines.append(
        "WCAG 2.1 defines a contrast ratio between two colors as "
        "`(L_lighter + 0.05) / (L_darker + 0.05)`, where each `L` is the "
        "relative luminance of the sRGB color after gamma decoding. The "
        "scale runs from `1:1` (no contrast) to `21:1` (black on white). "
        "WCAG AA requires `>= 4.5:1` for normal body text and `>= 3:1` "
        "for large text or non-text UI. ZiggyZag targets AA across every "
        "shipped theme: **4.5:1** for `foreground/background`, **4.5:1** "
        "for `accent/background` (used for prompts and links), **4.5:1** "
        "for `ansi[1]` red on background (error visibility), and **3:1** "
        "for `muted/background` since `muted` is documented as secondary "
        "text. AAA (`7:1` normal, `4.5:1` large) is a stretch goal, not "
        "a release gate."
    )
    lines.append("")
    lines.append(
        f"Audited **{total} themes**: {passing} pass AA on all four pairs, "
        f"{failing} need work."
    )
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(
        "| Theme | fg/bg | accent/bg | muted/bg | red/bg | Status |"
    )
    lines.append(
        "| --- | --- | --- | --- | --- | --- |"
    )
    for audit in audits:
        r = audit["results"]
        status = "PASS" if audit["passed"] else "NEEDS WORK"

        def cell(label: str) -> str:
            info = r.get(label)
            if not info or info.get("ratio") is None:
                return "n/a"
            mark = "" if info["pass"] else " (fail)"
            return f"{info['ratio']:.2f}:1{mark}"

        lines.append(
            f"| {audit['name']} (`{audit['id']}`) | "
            f"{cell('fg_bg')} | {cell('accent_bg')} | "
            f"{cell('muted_bg')} | {cell('red_bg')} | {status} |"
        )
    lines.append("")

    failing_audits = [a for a in audits if a["failures"] or a["issues"]]
    if failing_audits:
        lines.append("## Needs work")
        lines.append("")
        for audit in failing_audits:
            lines.append(f"### {audit['name']} (`{audit['id']}`)")
            lines.append("")
            lines.append(
                f"- background `{audit['background_hex']}`, "
                f"foreground `{audit['foreground_hex']}`, "
                f"accent `{audit['accent_hex']}`, "
                f"muted `{audit['muted_hex']}`, "
                f"ansi[1] `{audit['red_hex']}`"
            )
            if audit["issues"]:
                for issue in audit["issues"]:
                    lines.append(f"- structural issue: {issue}")
            for failure in audit["failures"]:
                pair = PAIR_LABEL[failure["label"]]
                ratio_str = fmt_ratio(failure["ratio"])
                lines.append(
                    f"- `{pair}` is {ratio_str} "
                    f"(`{failure['fg_hex']}` on `{failure['bg_hex']}`), "
                    f"AA target {failure['target']:.1f}:1"
                )
            lines.append("")
    else:
        lines.append("## Needs work")
        lines.append("")
        lines.append("None. Every theme passes its AA targets.")
        lines.append("")

    lines.append("## Methodology")
    lines.append("")
    lines.append(
        "Ratios are computed by `scripts/audit_contrast.py`, which parses "
        "`apps/desktop/src/theme.zig` with a small regex pass (no Zig "
        "toolchain needed) and applies the WCAG 2.1 relative-luminance "
        "formula. Re-run it after any theme change:"
    )
    lines.append("")
    lines.append("```sh")
    lines.append("python scripts/audit_contrast.py --write-report")
    lines.append("```")
    lines.append("")
    lines.append(
        "The script uses only the Python standard library and rewrites "
        "this file in place when `--write-report` is passed."
    )
    lines.append("")
    rev = _git_short_revision()
    rev_phrase = f" revision `{rev}`" if rev else ""
    lines.append(
        f"Last audit: {date.today().isoformat()} against "
        f"`apps/desktop/src/theme.zig`{rev_phrase}. Re-run via "
        f"`python scripts/audit_contrast.py --write-report`."
    )
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--theme-file",
        type=Path,
        default=THEME_FILE,
        help="Path to theme.zig (default: apps/desktop/src/theme.zig)",
    )
    parser.add_argument(
        "--report-path",
        type=Path,
        default=REPO_ROOT / "docs" / "reference" / "accessibility.md",
        help="Where to write the markdown report when --write-report is set.",
    )
    parser.add_argument(
        "--write-report",
        action="store_true",
        help="Write the markdown report instead of just printing to stdout.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit raw audit data as JSON on stdout (skips markdown).",
    )
    args = parser.parse_args(argv)

    zig_source = args.theme_file.read_text(encoding="utf-8")
    themes = parse_themes(zig_source)
    audits = [audit_theme(t) for t in themes]

    if args.json:
        json.dump(audits, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0

    markdown = build_markdown(audits)
    if args.write_report:
        args.report_path.parent.mkdir(parents=True, exist_ok=True)
        args.report_path.write_text(markdown, encoding="utf-8")
        print(f"Wrote {args.report_path}")
    else:
        sys.stdout.write(markdown)

    # Exit non-zero if anything fails, so CI can gate on this script.
    if any(not a["passed"] for a in audits):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
tion="store_true",
        help="Emit raw audit data as JSON on stdout (skips markdown).",
    )
    args = parser.parse_args(argv)

    zig_source = args.theme_file.read_text(encoding="utf-8")
    themes = parse_themes(zig_source)
    audits = [audit_theme(t) for t in themes]

    if args.json:
        json.dump(audits, sys.stdout, indent=2, default=str)
        sys.stdout.write("\n")
        return 0

    markdown = build_markdown(audits)
    if args.write_report:
        args.report_path.parent.mkdir(parents=True, exist_ok=True)
        args.report_path.write_text(markdown, encoding="utf-8")
        print(f"Wrote {args.report_path}")
    else:
        sys.stdout.write(markdown)

    # Exit non-zero if anything fails, so CI can gate on this script.
    if any(not a["passed"] for a in audits):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
