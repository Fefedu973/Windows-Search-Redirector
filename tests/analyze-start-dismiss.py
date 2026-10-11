"""Track a Start border strip in a local recording, without changing the image.

Choose an unobscured strip using the recorded Start UIA bounds and virtual-screen
origin. A normal-animation control recording must show a slide before trusting
the no-animation comparison. Scores are evidence, not a universal visual oracle.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser()
parser.add_argument("video", type=Path)
parser.add_argument("--strip", nargs=4, type=int, required=True, metavar=("X", "Y", "W", "H"))
parser.add_argument("--template-y", type=int, required=True)
parser.add_argument("--reference", type=float, default=2.5)
parser.add_argument("--end", type=float, default=4.5)
parser.add_argument("--expect", choices=("slide", "instant"))
args = parser.parse_args()
x, y, width, height = args.strip
if min(x, y) < 0 or width <= 0 or height < 48 or not 0 <= args.template_y <= height - 48:
    parser.error("Invalid crop/template geometry")
if not 0 <= args.reference < args.end:
    parser.error("Require 0 <= reference < end")
decoded = subprocess.run([
    "ffmpeg", "-hide_banner", "-loglevel", "info", "-i", str(args.video),
    "-t", str(args.end), "-vf", f"crop={width}:{height}:{x}:{y},showinfo",
    "-vsync", "0", "-pix_fmt", "gray", "-f", "rawvideo", "pipe:1",
], check=True, capture_output=True)
raw = decoded.stdout
frames = np.frombuffer(raw, dtype=np.uint8).reshape(-1, height, width)
times = [float(t) for t in re.findall(r"n:\s*\d+\s+pts:\s*\d+\s+pts_time:([\d.]+)", decoded.stderr.decode())][:len(frames)]
if len(times) != len(frames) or len(frames) < 2:
    raise SystemExit("Cannot pair decoded frames with actual timestamps")
reference_index = int(np.argmin(np.abs(np.array(times) - args.reference)))
template_height = 48
template = frames[reference_index, args.template_y:args.template_y + template_height].astype(np.float32)
centered = template - template.mean()
norm = np.linalg.norm(centered)
if norm < 10:
    raise SystemExit("Ambiguous reference: strip lacks contrast")
rows = []
for index in range(reference_index, len(frames)):
    current = frames[index].astype(np.float32)
    candidates = np.lib.stride_tricks.sliding_window_view(current, (template_height, width))[:, 0]
    candidates = candidates[max(0, args.template_y - 3):]
    means = candidates.mean(axis=(1, 2))
    variance = np.maximum(0, (candidates * candidates).sum(axis=(1, 2)) - means * means * template.size)
    numerator = np.einsum("ijk,jk->i", candidates, centered)
    scores = numerator / (np.sqrt(variance) * norm + 1e-6)
    best = int(scores.argmax())
    top = best + max(0, args.template_y - 3)
    mae = float(np.abs(current[top:top + template_height] - template).mean())
    rows.append({"frame": index, "time": times[index],
                 "offset": top - args.template_y, "score": round(float(scores[best]), 4),
                 "mae": round(mae, 3)})
valid = [row for row in rows if row["score"] >= 0.90 and row["mae"] <= 12]
moved = [row for row in valid if row["offset"] > 3]
last_visible = valid[-1]["frame"] if valid else reference_index
first_change = next((row["frame"] for row in rows
                     if row["offset"] > 3 or row["score"] < .9 or row["mae"] > 12), None)
transition_times = times[max(reference_index, (first_change or last_visible) - 1):last_visible + 3]
transition_gap = float(np.diff(transition_times).max()) * 1000 if len(transition_times) >= 2 else None
disappearance = first_change is not None and last_visible < len(frames) - 3
stationary_count = sum(abs(row["offset"]) <= 3 for row in valid)
conclusive = bool(disappearance and stationary_count >= 3 and
                  transition_gap is not None and transition_gap <= 50.1)
summary = {"video": str(args.video), "strip": args.strip, "reference_time": args.reference,
           "reference_template_y": args.template_y, "frames_analyzed": len(rows),
           "tracked_frames": len(valid), "moving_frames": len(moved),
           "max_frame_gap_ms": round(float(np.diff(times).max()) * 1000, 2),
           "transition_max_frame_gap_ms": round(transition_gap, 2) if transition_gap is not None else None,
           "last_tracked_time": times[last_visible] if valid else None,
           "next_frame_time": times[last_visible + 1] if last_visible + 1 < len(times) else None,
           "disappearance_observed": disappearance,
           "conclusive": conclusive,
           "max_tracked_downward_offset": max((row["offset"] for row in valid), default=None),
           "movement_detected": bool(moved), "rows": rows}
output = args.video.parent / "analysis.json"
output.write_text(json.dumps(summary, indent=2), encoding="utf-8")
if first_change is None:
    first_change = reference_index
selected = list(range(max(reference_index, first_change - 2), min(len(frames), first_change + 13)))
sheet = Image.new("RGB", (len(selected) * (width + 35), min(height, 1000) + 35), "white")
draw = ImageDraw.Draw(sheet)
for col, index in enumerate(selected):
    shot = Image.fromarray(frames[index, :1000]).convert("RGB")
    sheet.paste(shot, (col * (width + 35), 35))
    draw.text((col * (width + 35), 5), f"{times[index]:.3f}", fill="black")
sheet.save(args.video.parent / "contact-sheet.png")
print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, indent=2))
if args.expect and (not conclusive or bool(moved) != (args.expect == "slide")):
    raise SystemExit("FAIL: recording is inconclusive or does not match the expected transition")
