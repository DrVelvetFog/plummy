#!/usr/bin/env python3
"""Toy see/act loop test for a local Ollama vision model (Velvet Phase 4 revisit).

Two cases:
  A (button.png)    — task needs a click; Save button rect is (540,400)-(740,460).
  B (no-button.png) — doc autosaves; correct action is none.

Two alternating turns per trial, matching Velvet's loop shape:
  SEE  — image + "describe what matters for the task" (no action yet)
  ACT  — text-only follow-up: commit to a JSON action from the remembered screen.

Scores clicks against the button rect under both coordinate conventions
(raw pixels on the 1280x800 image, and 0-1000 normalized).
"""

import base64, json, re, sys, urllib.request

MODEL = sys.argv[1] if len(sys.argv) > 1 else "qwen3-vl:2b"
TRIALS = 3
BTN = (540, 400, 740, 460)  # x0 y0 x1 y1 in image pixels
IMG_W, IMG_H = 1280, 800
PAD = 20

SEE_PROMPT = (
    "You are the eyes of a Mac assistant. This is a 1280x800 screenshot of the screen. "
    "The user's task is: save the document. "
    "Look carefully and describe only what matters for the task: is the document already saved, "
    "and is there any control (button, menu item) that would save it? If there is one, state its "
    "exact location as pixel coordinates of its center. Do not take any action yet."
)

ACT_PROMPT = (
    "Now commit to an action based on what you saw. Respond with ONLY one JSON object, no other text: "
    '{"action":"click","x":<int>,"y":<int>,"target":"<what you are clicking>"} '
    'if clicking accomplishes the task, or {"action":"none","reason":"<why>"} if no click is needed. '
    "Coordinates are pixels on the 1280x800 screenshot."
)


def chat(messages):
    body = json.dumps({
        "model": MODEL,
        "messages": messages,
        "stream": False,
        "options": {"temperature": 0},
    }).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", body,
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read())["message"]["content"]


def parse_action(text):
    m = re.search(r"\{.*\}", text, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return None


def in_rect(x, y, pad=PAD):
    return (BTN[0] - pad) <= x <= (BTN[2] + pad) and (BTN[1] - pad) <= y <= (BTN[3] + pad)


def score_click(x, y):
    """Return (hit, convention) checking pixel and 0-1000-normalized conventions."""
    if in_rect(x, y):
        return True, "pixel"
    nx, ny = x / 1000 * IMG_W, y / 1000 * IMG_H
    if in_rect(nx, ny):
        return True, "normalized-1000"
    return False, "-"


def run_case(name, img_path, expect_click):
    img64 = base64.b64encode(open(img_path, "rb").read()).decode()
    results = []
    for t in range(1, TRIALS + 1):
        msgs = [{"role": "user", "content": SEE_PROMPT, "images": [img64]}]
        see = chat(msgs)
        msgs.append({"role": "assistant", "content": see})
        msgs.append({"role": "user", "content": ACT_PROMPT})
        act_raw = chat(msgs)
        act = parse_action(act_raw)

        verdict, detail = "FAIL", act_raw.strip()[:200]
        if act and act.get("action") == "click" and expect_click:
            try:
                x, y = float(act["x"]), float(act["y"])
                hit, conv = score_click(x, y)
                verdict = "PASS" if hit else "FAIL"
                detail = f"click ({x:.0f},{y:.0f}) conv={conv} target={act.get('target','')!r}"
            except (KeyError, TypeError, ValueError):
                detail = f"malformed click: {act_raw.strip()[:200]}"
        elif act and act.get("action") == "none" and not expect_click:
            verdict = "PASS"
            detail = f"none: {act.get('reason','')[:120]}"
        elif act:
            detail = f"wrong action {act.get('action')!r}: {act_raw.strip()[:160]}"

        results.append(verdict)
        print(f"  [{name} trial {t}] {verdict} — {detail}")
        print(f"      see-turn said: {see.strip()[:220].replace(chr(10), ' ')}")
    return results


print(f"model: {MODEL}, trials per case: {TRIALS}, temp 0, alternating see/act turns\n")
print("Case A — button present, task: save the document (expect click on Save):")
a = run_case("A", "button.png", expect_click=True)
print("\nCase B — autosaved, no button (expect action none):")
b = run_case("B", "no-button.png", expect_click=False)
print(f"\nRESULT {MODEL}: case A {a.count('PASS')}/{TRIALS} pass, case B {b.count('PASS')}/{TRIALS} pass")
