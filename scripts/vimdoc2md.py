#!/usr/bin/env python3
"""Convert the VRC Vim help file to a GitHub-friendly Markdown document."""

from __future__ import annotations

import re
import sys
import textwrap
from pathlib import Path

SECTION_TITLES = {
    "INTRODUCTION": "Introduction",
    "FEATURES": "Features",
    "INSTALLATION": "Installation",
    "EXAMPLES": "Examples",
    "USAGE": "Usage",
    "CONFIGURATION": "Configuration",
    "TIPS 'N TRICKS": "Tips 'n Tricks",
    "CONTRIBUTORS": "Contributors",
    "LICENSE": "License",
}

TAG_RE = re.compile(r"\*([A-Za-z0-9_.-]+)\*")
LINK_RE = re.compile(r"\|([A-Za-z0-9_.-]+)\|")
TOC_RE = re.compile(r"^\s*(.*?)\.{2,}\s*\|([A-Za-z0-9_.-]+)\|\s*$")
HEADING_RE = re.compile(r"^\s*(\d+(?:\.\d+)?)\.?\s+(.+?)(?:~)?\s*$")


def strip_inline_markup(line: str) -> tuple[str, list[str]]:
    anchors: list[str] = []

    def keep_tag(match: re.Match[str]) -> str:
        anchors.append(match.group(1))
        return ""

    line = TAG_RE.sub(keep_tag, line)
    line = LINK_RE.sub(lambda m: f"[{m.group(1)}](#{m.group(1)})", line)
    return line, anchors


def infer_language(lines: list[str]) -> str:
    text = "\n".join(lines)
    if re.search(r"^\s*(let|nnoremap|xnoremap|inoremap|setlocal|set)\b", text, re.M):
        return "vim"
    if re.search(r"^\s*(GET|POST|PUT|DELETE|HEAD|PATCH|OPTIONS|TRACE)\s+", text, re.M):
        return "http"
    if re.search(r"^\s*(cd|git|curl|echo|grep|jq|xmllint|python\d*|printf)\b", text, re.M):
        return "sh"
    return ""


def render_code(lines: list[str]) -> list[str]:
    block = textwrap.dedent("\n".join(lines)).strip("\n")
    language = infer_language(lines)
    return ["", f"```{language}", block, "```", ""]


def convert(source: Path) -> str:
    raw = source.read_text(encoding="utf-8").splitlines()

    output: list[str] = [
        "<!-- Generated from doc/vim-rest-console.txt. Do not edit manually. -->",
        "",
        "# Vim REST Console (VRC)",
        "",
        "A plug-in to help work with RESTful services.",
        "",
    ]
    in_code = False
    code_lines: list[str] = []
    in_contents = False
    started_intro = False
    anchors: set[str] = set()

    for index, line in enumerate(raw):
        if index == 0 and line.startswith("*vim-rest-console.txt*"):
            continue
        if not started_intro:
            if line.startswith("VRC creates"):
                started_intro = True
            else:
                continue
        if re.fullmatch(r"\s*vim:.*", line):
            continue
        if re.fullmatch(r"\s*[\\/_~| ]{3,}\s*", line):
            continue
        if re.fullmatch(r"\s*[=-]{4,}\s*", line):
            continue

        if in_code:
            if line.strip() == "<":
                output.extend(render_code(code_lines))
                code_lines = []
                in_code = False
            else:
                code_lines.append(line)
            continue

        if line.strip() == ">":
            in_code = True
            continue
        if line.rstrip().endswith(" >"):
            code_lines.append(line.rstrip()[:-2].rstrip())
            in_code = True
            continue

        if not line.strip():
            if output and output[-1] != "":
                output.append("")
            continue

        stripped = line.strip()

        standalone_tag = re.fullmatch(r"\*([A-Za-z0-9_.-]+)\*", stripped)
        if standalone_tag:
            tag = standalone_tag.group(1)
            anchors.add(tag)
            if output and output[-1] != "":
                output.append("")
            if tag.startswith("vrc_"):
                output.extend([f'<a id="{tag}"></a>', f"### `{tag}`", ""])
            else:
                output.extend([f'<a id="{tag}"></a>', ""])
            continue

        if stripped.startswith("CONTENTS"):
            output.extend(['<a id="VrcContents"></a>', "## Contents", ""])
            in_contents = True
            continue

        clean_line, found = strip_inline_markup(line.rstrip())

        if in_contents:
            toc = TOC_RE.match(line)
            if toc:
                text = re.sub(r"\s+", " ", toc.group(1)).strip()
                indent = "  " if len(line) - len(line.lstrip()) >= 4 else ""
                output.append(f"{indent}* [{text}](#{toc.group(2)})")
                continue
            heading = HEADING_RE.match(clean_line)
            if heading or (stripped.endswith("~")
                and stripped[:-1].upper() in SECTION_TITLES):
                in_contents = False
            else:
                continue

        if stripped == "Examples~":
            output.extend(["#### Examples", ""])
            continue

        heading = HEADING_RE.match(clean_line)
        if heading and (
            stripped.endswith("~")
            or re.match(r"^\d+\.\d+\s", stripped)
        ):
            number, title = heading.groups()
            title = SECTION_TITLES.get(title.upper(), title)
            level = "###" if "." in number else "##"
            label = number if "." in number else f"{number}."
            for anchor in found:
                if anchor not in anchors:
                    anchors.add(anchor)
                    output.append(f'<a id="{anchor}"></a>')
            output.extend([f"{level} {label} {title}", ""])
            continue

        if stripped.endswith("~") and stripped[:-1].upper() in SECTION_TITLES:
            title = SECTION_TITLES[stripped[:-1].upper()]
            output.extend([f"## {title}", ""])
            continue

        text, found = strip_inline_markup(line.rstrip())
        text = re.sub(r"^\s{1,4}([*+-]|\d+\.)\s+", r"\1 ", text)
        text = re.sub(r"^\s{4}`([>%])`\s*-\s*", r"* `\1` - ", text)
        for anchor in found:
            if anchor not in anchors:
                anchors.add(anchor)
                output.append(f'<a id="{anchor}"></a>')
        output.append(text)

    if in_code:
        output.extend(render_code(code_lines))

    while output and output[-1] == "":
        output.pop()

    result = "\n".join(output) + "\n"
    return re.sub(r"\n{3,}", "\n\n", result)


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(f"usage: {sys.argv[0]} INPUT.txt [OUTPUT.md]", file=sys.stderr)
        return 2
    source = Path(sys.argv[1])
    result = convert(source)
    if len(sys.argv) == 3:
        Path(sys.argv[2]).write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
