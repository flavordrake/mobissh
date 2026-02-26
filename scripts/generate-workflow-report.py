#!/usr/bin/env python3
"""
scripts/generate-workflow-report.py

Generates a narrative HTML report from emulator test results.
Reads the Playwright JSON report, embeds step screenshots (base64),
video frames, and links to the full recording.

Usage:
    python3 scripts/generate-workflow-report.py
    python3 scripts/generate-workflow-report.py --open
    python3 scripts/generate-workflow-report.py --baseline tests/emulator/baseline
"""

import argparse
import base64
import json
import os
import sys
from pathlib import Path
from datetime import datetime, timezone

def main():
    parser = argparse.ArgumentParser(description="Generate workflow exploration HTML report")
    parser.add_argument("--baseline", default="test-results/emulator",
                        help="Path to results directory")
    parser.add_argument("--open", action="store_true",
                        help="Open the report in a browser after generating")
    parser.add_argument("--output", default=None,
                        help="Output HTML path (default: <baseline>/workflow-report.html)")
    args = parser.parse_args()

    baseline = Path(args.baseline)
    report_path = baseline / "report.json"
    frames_dir = baseline / "frames"
    video_path = baseline / "recording.mp4"
    output_path = Path(args.output) if args.output else baseline / "workflow-report.html"

    if not report_path.exists():
        print(f"Error: {report_path} not found. Run emulator tests first.", file=sys.stderr)
        sys.exit(1)

    with open(report_path) as f:
        report = json.load(f)

    tests = collect_tests(report)
    frames = collect_frames(frames_dir) if frames_dir.exists() else {}
    has_video = video_path.exists()
    video_rel = os.path.relpath(video_path, output_path.parent) if has_video else None

    stats = report.get("stats", {})
    start_time = stats.get("startTime", "")
    duration_ms = stats.get("duration", 0)

    html = render_html(tests, frames, video_rel, start_time, duration_ms)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write(html)

    print(f"Report: {output_path}")

    if args.open:
        import subprocess
        subprocess.run(["xdg-open", str(output_path)], check=False)


def collect_tests(report):
    """Walk the nested suite structure and extract test results with attachments."""
    tests = []

    def walk(suites):
        for suite in suites:
            suite_title = suite.get("title", "")
            for spec in suite.get("specs", []):
                spec_title = spec.get("title", "")
                for test in spec.get("tests", []):
                    project = test.get("projectName", "")
                    for result in test.get("results", []):
                        tests.append({
                            "suite": suite_title,
                            "title": spec_title,
                            "project": project,
                            "status": result.get("status", "unknown"),
                            "duration": result.get("duration", 0),
                            "startTime": result.get("startTime", ""),
                            "error": result.get("error", {}).get("message", ""),
                            "attachments": result.get("attachments", []),
                        })
            walk(suite.get("suites", []))

    walk(report.get("suites", []))
    return tests


def collect_frames(frames_dir):
    """Group video frames by test name prefix."""
    frames = {}
    for png in sorted(frames_dir.glob("*.png")):
        # Frame names: prefix-0-before.png, prefix-1-midpoint.png, etc.
        name = png.stem
        # Split off the frame suffix (e.g., -0-before, -1-midpoint, -2-end-failed)
        parts = name.rsplit("-", 2)
        if len(parts) >= 3:
            # e.g. "explore-workflow-clear-SSH-login-...-vertical-swipe" + "0" + "before"
            test_prefix = parts[0]
        else:
            test_prefix = name

        # More robust: find the -N- pattern that separates prefix from frame label
        import re
        m = re.match(r"^(.+?)-(\d+[a-z]?)-(.+)$", name)
        if m:
            test_prefix = m.group(1)
            frame_order = m.group(2)
            frame_label = m.group(3)
        else:
            test_prefix = name
            frame_order = "0"
            frame_label = "unknown"

        if test_prefix not in frames:
            frames[test_prefix] = []

        with open(png, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()

        frames[test_prefix].append({
            "order": frame_order,
            "label": frame_label,
            "b64": b64,
            "filename": png.name,
        })

    # Sort each group by order
    for prefix in frames:
        frames[prefix].sort(key=lambda x: x["order"])

    return frames


def img_from_attachment(att):
    """Extract a base64 image from an attachment dict."""
    body = att.get("body", "")
    path = att.get("path", "")
    content_type = att.get("contentType", "")

    if not content_type.startswith("image/"):
        return None

    if body:
        return f"data:{content_type};base64,{body}"

    if path and os.path.exists(path):
        with open(path, "rb") as f:
            b64 = base64.b64encode(f.read()).decode()
        return f"data:{content_type};base64,{b64}"

    return None


def text_from_attachment(att):
    """Extract text content from an attachment."""
    body = att.get("body", "")
    if body:
        try:
            return base64.b64decode(body).decode("utf-8", errors="replace")
        except Exception:
            return body
    path = att.get("path", "")
    if path and os.path.exists(path):
        with open(path, "r") as f:
            return f.read()
    return None


def match_test_to_frames(test_title, frames):
    """Find the best matching frame group for a test title."""
    # Normalize test title to match frame prefixes
    import re
    normalized = re.sub(r"[^a-zA-Z0-9]+", "-", test_title).strip("-").lower()

    best_match = None
    best_score = 0

    for prefix in frames:
        prefix_lower = prefix.lower()
        # Count matching words
        title_words = set(normalized.split("-"))
        prefix_words = set(prefix_lower.split("-"))
        overlap = len(title_words & prefix_words)
        if overlap > best_score:
            best_score = overlap
            best_match = prefix

    return best_match if best_score >= 3 else None


def status_badge(status):
    if status == "passed":
        return '<span class="badge pass">PASSED</span>'
    elif status == "failed":
        return '<span class="badge fail">FAILED</span>'
    elif status == "skipped":
        return '<span class="badge skip">SKIPPED</span>'
    return f'<span class="badge">{status.upper()}</span>'


def format_duration(ms):
    s = ms / 1000
    if s < 60:
        return f"{s:.1f}s"
    m = int(s // 60)
    s = s % 60
    return f"{m}m {s:.0f}s"


def render_html(tests, frames, video_rel, start_time, duration_ms):
    # Group tests by suite
    suites = {}
    for t in tests:
        s = t["suite"] or "Ungrouped"
        suites.setdefault(s, []).append(t)

    passed = sum(1 for t in tests if t["status"] == "passed")
    failed = sum(1 for t in tests if t["status"] == "failed")
    total = len(tests)

    # Format timestamp
    try:
        dt = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        time_str = dt.strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        time_str = start_time

    test_sections = []

    for suite_name, suite_tests in suites.items():
        for t in suite_tests:
            section = render_test_section(t, frames)
            test_sections.append(section)

    video_section = ""
    if video_rel:
        video_section = f'''
    <section class="video-section">
      <h2>Full Recording</h2>
      <video controls width="360" preload="metadata">
        <source src="{video_rel}" type="video/mp4">
        Your browser does not support video playback.
      </video>
      <p class="video-link"><a href="{video_rel}" download>Download recording</a></p>
    </section>'''

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Workflow Exploration Report</title>
<style>
* {{ margin: 0; padding: 0; box-sizing: border-box; }}
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  background: #0d1117; color: #c9d1d9; line-height: 1.5; padding: 20px; max-width: 1200px; margin: 0 auto; }}
h1 {{ color: #f0f6fc; margin-bottom: 4px; font-size: 1.5rem; }}
h2 {{ color: #f0f6fc; margin: 24px 0 12px; font-size: 1.2rem; }}
h3 {{ color: #e6edf3; margin: 16px 0 8px; font-size: 1rem; }}
.summary {{ display: flex; gap: 16px; flex-wrap: wrap; margin: 12px 0 24px; }}
.summary .stat {{ background: #161b22; border: 1px solid #30363d; border-radius: 6px; padding: 8px 16px; }}
.summary .stat .label {{ font-size: 0.75rem; color: #8b949e; text-transform: uppercase; }}
.summary .stat .value {{ font-size: 1.25rem; font-weight: 600; }}
.summary .stat .value.pass {{ color: #3fb950; }}
.summary .stat .value.fail {{ color: #f85149; }}
.badge {{ display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem;
  font-weight: 600; text-transform: uppercase; }}
.badge.pass {{ background: #1a3a2a; color: #3fb950; }}
.badge.fail {{ background: #3a1a1a; color: #f85149; }}
.badge.skip {{ background: #2a2a1a; color: #d29922; }}
.test-section {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
  margin-bottom: 20px; overflow: hidden; }}
.test-header {{ padding: 12px 16px; border-bottom: 1px solid #30363d;
  display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; }}
.test-header .title {{ font-weight: 600; color: #f0f6fc; }}
.test-header .meta {{ font-size: 0.8rem; color: #8b949e; }}
.test-body {{ padding: 16px; }}
.error-box {{ background: #2d1117; border: 1px solid #f8514966; border-radius: 6px;
  padding: 10px 14px; margin: 8px 0 16px; font-family: monospace; font-size: 0.8rem;
  color: #f85149; white-space: pre-wrap; word-break: break-word; max-height: 200px; overflow-y: auto; }}
.step {{ margin: 12px 0; }}
.step-label {{ font-size: 0.85rem; color: #8b949e; margin-bottom: 4px; }}
.step img {{ max-width: 360px; border-radius: 6px; border: 1px solid #30363d; cursor: pointer;
  transition: max-width 0.2s; }}
.step img:hover {{ max-width: 100%; }}
.step img.wide {{ max-width: 100%; }}
.step-text {{ background: #0d1117; border: 1px solid #30363d; border-radius: 6px;
  padding: 10px 14px; font-family: monospace; font-size: 0.8rem; white-space: pre-wrap; }}
.frames-section {{ margin-top: 20px; border-top: 1px solid #30363d; padding-top: 16px; }}
.frames-grid {{ display: flex; flex-wrap: wrap; gap: 12px; }}
.frame {{ text-align: center; }}
.frame img {{ max-width: 240px; border-radius: 4px; border: 1px solid #30363d; cursor: pointer;
  transition: max-width 0.2s; }}
.frame img:hover {{ max-width: 480px; }}
.frame .frame-label {{ font-size: 0.7rem; color: #8b949e; margin-top: 4px; }}
.video-section {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
  padding: 16px; margin-top: 20px; }}
.video-section video {{ border-radius: 6px; display: block; margin: 8px 0; }}
.video-link {{ margin-top: 8px; }}
.video-link a {{ color: #58a6ff; text-decoration: none; }}
.video-link a:hover {{ text-decoration: underline; }}
a {{ color: #58a6ff; }}
.narrative {{ color: #8b949e; font-style: italic; margin: 4px 0; font-size: 0.85rem; }}
.timestamp {{ color: #484f58; font-size: 0.75rem; }}
</style>
</head>
<body>

<h1>Workflow Exploration Report</h1>
<p class="timestamp">Generated {time_str} / Total duration: {format_duration(duration_ms)}</p>

<div class="summary">
  <div class="stat"><div class="label">Total</div><div class="value">{total}</div></div>
  <div class="stat"><div class="label">Passed</div><div class="value pass">{passed}</div></div>
  <div class="stat"><div class="label">Failed</div><div class="value fail">{failed}</div></div>
</div>

{"".join(test_sections)}

{video_section}

<script>
// Toggle image size on click
document.querySelectorAll('.step img, .frame img').forEach(img => {{
  img.addEventListener('click', () => img.classList.toggle('wide'));
}});
</script>

</body>
</html>'''


def render_test_section(test, frames):
    title = test["title"]
    status = test["status"]
    duration = test["duration"]

    header = f'''
    <div class="test-header">
      <div>
        <span class="title">{title}</span>
        <span class="meta">{format_duration(duration)}</span>
      </div>
      {status_badge(status)}
    </div>'''

    body_parts = []

    # Error message
    if test["error"]:
        # Truncate very long errors
        err = test["error"]
        if len(err) > 500:
            err = err[:500] + "..."
        body_parts.append(f'<div class="error-box">{err}</div>')

    # Step screenshots and text attachments
    for att in test["attachments"]:
        name = att.get("name", "")
        content_type = att.get("contentType", "")

        # Skip auto-generated final screenshot and traces
        if name == "screenshot" or name == "trace":
            continue

        if content_type.startswith("image/"):
            src = img_from_attachment(att)
            if src:
                # Generate narrative from step name
                narrative = step_narrative(name)
                body_parts.append(f'''
      <div class="step">
        <div class="step-label">{name}</div>
        {f'<div class="narrative">{narrative}</div>' if narrative else ''}
        <img src="{src}" alt="{name}" loading="lazy">
      </div>''')

        elif content_type == "text/plain":
            text = text_from_attachment(att)
            if text:
                body_parts.append(f'''
      <div class="step">
        <div class="step-label">{name}</div>
        <div class="step-text">{text}</div>
      </div>''')

    # Match video frames
    frame_key = match_test_to_frames(title, frames)
    if frame_key and frames.get(frame_key):
        frame_items = []
        for fr in frames[frame_key]:
            label = fr["label"].replace("-", " ").replace("end ", "end: ")
            frame_items.append(f'''
        <div class="frame">
          <img src="data:image/png;base64,{fr['b64']}" alt="{fr['filename']}" loading="lazy">
          <div class="frame-label">{label}</div>
        </div>''')

        body_parts.append(f'''
      <div class="frames-section">
        <h3>Video Frames</h3>
        <div class="narrative">Extracted from screen recording at key moments during test execution</div>
        <div class="frames-grid">{"".join(frame_items)}</div>
      </div>''')

    body = "\n".join(body_parts) if body_parts else '<p class="narrative">No step data captured</p>'

    return f'''
    <section class="test-section">
      {header}
      <div class="test-body">{body}</div>
    </section>'''


def step_narrative(step_name):
    """Generate a brief narrative description from the step screenshot name."""
    narratives = {
        "fresh-start": "Application loaded with cleared state (localStorage wiped, page reloaded)",
        "connected": "SSH connection established via the test SSH server",
        "scrollback-generated": "Terminal filled with scrollback content (seq 1 100)",
        "after-swipe-up": "Vertical swipe up performed on terminal (scroll back through output)",
        "after-second-swipe": "Second vertical swipe up (continued scrolling)",
        "tmux-started": "tmux session started inside SSH connection",
        "tmux-second-window": "Second tmux window created (Ctrl-B c)",
        "after-swipe-left": "Horizontal swipe left (should trigger tmux prev window)",
        "after-swipe-right": "Horizontal swipe right (should trigger tmux next window)",
        "terminal-loaded": "Terminal view loaded, ready for interaction",
        "settings-panel": "Navigated to Settings panel via tab bar",
        "after-pinch-zoom-in": "Pinch-to-zoom gesture performed on settings panel",
        "back-to-terminal": "Navigated back to terminal view after zoom test",
    }
    for key, desc in narratives.items():
        if key in step_name:
            return desc
    return ""


if __name__ == "__main__":
    main()
