#!/usr/bin/env python3
"""Render a slice of a verify.sh log into a terminal style PNG.

    python3 tools/render-log.py <log> <first-line> <last-line> <out.png> "<title>"
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = "/System/Library/Fonts/SFNSMono.ttf"
SIZE, PAD, TITLEBAR, WRAP = 26, 28, 40, 120
BG, TITLE_BG, FG = (30, 32, 38), (44, 47, 54), (222, 226, 232)
GREEN, CYAN, GREY, YELLOW = (126, 208, 128), (108, 190, 214), (140, 146, 158), (226, 192, 116)
DOTS = [(255, 95, 86), (255, 189, 46), (39, 201, 63)]
FLAGS = ("OUTAGE", "CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "OOMKilled",
         "AccessDenied", "is invalid", "immutable", "Pending", "Error", "denied", "exit=7")


def colour(line):
    if line.startswith("$ "):
        return GREEN
    if line.startswith("====="):
        return CYAN
    if line.startswith("#"):
        return GREY
    return YELLOW if any(f in line for f in FLAGS) else FG


def wrap(lines):
    out = []
    for line in lines:
        while len(line) > WRAP:
            cut = line.rfind(" ", 0, WRAP)
            if cut < 40:
                cut = WRAP
            out.append(line[:cut])
            line = "    " + line[cut:].lstrip()
        out.append(line)
    return out


def render(lines, out_path, title):
    font = ImageFont.truetype(FONT, SIZE)
    title_font = ImageFont.truetype(FONT, 22)
    lines = wrap([l.rstrip("\n").replace("\t", "    ") for l in lines])
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()

    probe = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    line_height = SIZE + 10
    width = max(int(max(probe.textlength(l, font=font) for l in lines)) + PAD * 2, 700)
    height = TITLEBAR + PAD * 2 + line_height * len(lines)

    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, width, TITLEBAR], fill=TITLE_BG)
    for i, dot in enumerate(DOTS):
        cx = 20 + i * 22
        draw.ellipse([cx - 7, TITLEBAR // 2 - 7, cx + 7, TITLEBAR // 2 + 7], fill=dot)
    draw.text(((width - draw.textlength(title, font=title_font)) / 2, TITLEBAR / 2 - 11),
              title, font=title_font, fill=GREY)

    y = TITLEBAR + PAD
    for line in lines:
        draw.text((PAD, y), line, font=font, fill=colour(line))
        y += line_height

    img.save(out_path)
    print(f"{os.path.basename(out_path)}  {width}x{height}  {len(lines)}L")


if __name__ == "__main__":
    log, start, end, out_path, title = sys.argv[1:6]
    render(open(log).read().split("\n")[int(start) - 1:int(end)], out_path, title)
