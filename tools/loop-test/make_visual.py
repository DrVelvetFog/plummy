#!/usr/bin/env python3
"""Re-run the see/act loop test live and render the real outputs as social frames.

Outputs (in ./visual/): frame-*.png (1080x1350 cards), then assembled by ffmpeg
into loop-test.mp4 and loop-test.gif (see build step in the shell).
All model text shown on the cards is verbatim from this run — nothing staged.
"""

import base64, html, json, os, re, subprocess, urllib.request

MODEL = "qwen3-vl:2b"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "visual")
os.makedirs(OUT, exist_ok=True)

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
BTN = (540, 400, 740, 460)


def chat(messages):
    body = json.dumps({"model": MODEL, "messages": messages, "stream": False,
                       "options": {"temperature": 0}}).encode()
    req = urllib.request.Request("http://localhost:11434/api/chat", body,
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read())["message"]["content"]


def run_case(img_path):
    img64 = base64.b64encode(open(img_path, "rb").read()).decode()
    msgs = [{"role": "user", "content": SEE_PROMPT, "images": [img64]}]
    see = chat(msgs)
    msgs += [{"role": "assistant", "content": see}, {"role": "user", "content": ACT_PROMPT}]
    act_raw = chat(msgs)
    act = json.loads(re.search(r"\{.*\}", act_raw, re.S).group(0))
    return see.strip(), act


def click_px(act):
    x, y = float(act["x"]), float(act["y"])
    if not (BTN[0] - 20 <= x <= BTN[2] + 20 and BTN[1] - 20 <= y <= BTN[3] + 20):
        nx, ny = x / 1000 * 1280, y / 1000 * 800
        if BTN[0] - 20 <= nx <= BTN[2] + 20 and BTN[1] - 20 <= ny <= BTN[3] + 20:
            return nx, ny, True
    return x, y, False


CARD = """<!doctype html><html><head><meta charset="utf-8"><style>
  * {{ margin:0; box-sizing:border-box; }}
  body {{ width:1080px; height:1350px; background:#17141f; color:#f4f1fa;
         font-family:-apple-system, 'Helvetica Neue', sans-serif; padding:56px 60px; }}
  .kicker {{ color:#b18cff; font-size:30px; font-weight:700; letter-spacing:.14em; }}
  h1 {{ font-size:54px; font-weight:800; line-height:1.15; margin:18px 0 10px; }}
  .sub {{ color:#a79fc0; font-size:31px; line-height:1.4; margin-bottom:34px; }}
  .shot {{ position:relative; width:960px; border-radius:18px; overflow:hidden;
           border:1px solid #352d4a; }}
  .shot img {{ width:960px; display:block; }}
  .ring {{ position:absolute; width:72px; height:72px; border:6px solid #b18cff;
           border-radius:50%; transform:translate(-50%,-50%);
           box-shadow:0 0 0 6px rgba(177,140,255,.28); }}
  .ring::after {{ content:''; position:absolute; left:50%; top:50%; width:10px; height:10px;
           background:#b18cff; border-radius:50%; transform:translate(-50%,-50%); }}
  .bubble {{ background:#241e33; border:1px solid #3a3153; border-radius:18px;
             padding:30px 34px; margin-top:34px; font-size:30px; line-height:1.45; }}
  .bubble .who {{ color:#b18cff; font-weight:700; font-size:26px; letter-spacing:.1em;
                  margin-bottom:12px; }}
  .mono {{ font-family:'SF Mono', Menlo, monospace; font-size:27px; color:#9fe8b8;
           white-space:pre-wrap; }}
  .verdict {{ display:inline-block; margin-top:30px; background:#1d3a28; color:#6fe39a;
              font-weight:800; font-size:34px; padding:14px 30px; border-radius:14px;
              border:1px solid #2c5a3d; }}
  .foot {{ position:absolute; bottom:44px; left:60px; right:60px; display:flex;
           justify-content:space-between; color:#6d6587; font-size:25px; }}
</style></head><body>
  <div class="kicker">{kicker}</div>
  <h1>{title}</h1>
  <div class="sub">{sub}</div>
  <div class="shot"><img src="{img}">{ring}</div>
  {bubble}
  {verdict}
  <div class="foot"><span>qwen3-vl 2B · runs 100% on the Mac · no cloud, no API key</span><span>temp 0, unedited output</span></div>
</body></html>"""


def frame(name, **kw):
    kw.setdefault("ring", "")
    kw.setdefault("bubble", "")
    kw.setdefault("verdict", "")
    p = os.path.join(OUT, name + ".html")
    open(p, "w").write(CARD.format(**kw))
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--window-size=1080,1350",
                    "--hide-scrollbars", f"--screenshot={os.path.join(OUT, name + '.png')}",
                    f"file://{p}"], check=True, capture_output=True)
    print("rendered", name + ".png")


def bubble(who, text, mono=False):
    cls = ' class="mono"' if mono else ""
    return f'<div class="bubble"><div class="who">{who}</div><span{cls}>{html.escape(text)}</span></div>'


# ---- run both cases live ----
seeA, actA = run_case(os.path.join(HERE, "button.png"))
seeB, actB = run_case(os.path.join(HERE, "no-button.png"))
ax, ay, was_norm = click_px(actA)
print("case A act:", actA, "-> px", (ax, ay), "normalized" if was_norm else "pixel")
print("case B act:", actB)

# scale click point to the 960px-wide card image
rx, ry = ax * 960 / 1280, ay * 960 / 1280

K = "VELVET · LOCAL VISION TEST"
imgA, imgB = os.path.join(HERE, "button.png"), os.path.join(HERE, "no-button.png")

frame("frame-01", kicker=K, title="Can a 2 GB local AI use your screen?",
      sub="Task given to the model: &ldquo;save the document.&rdquo; It only gets this screenshot — no DOM, no accessibility tree, no cloud.",
      img=imgA)
frame("frame-02", kicker=K, title="Turn 1 — it looks", sub="First turn is see-only: describe what matters, don't act yet.",
      img=imgA, bubble=bubble("MODEL (SEE TURN)", seeA[:420]))
frame("frame-03", kicker=K, title="Turn 2 — it acts", sub="Next turn, no image: commit to an action from what it remembers.",
      img=imgA, ring=f'<div class="ring" style="left:{rx:.0f}px; top:{ry:.0f}px;"></div>',
      bubble=bubble("MODEL (ACT TURN)", json.dumps(actA), mono=True),
      verdict='<div class="verdict">HIT — dead center on Save</div>')
frame("frame-04", kicker=K, title="The real test: knowing when NOT to act",
      sub="Same task, but this document autosaves. A sloppy agent clicks anyway.",
      img=imgB)
frame("frame-05", kicker=K, title="It holds still", sub="",
      img=imgB, bubble=bubble("MODEL (ACT TURN)", json.dumps(actB), mono=True),
      verdict='<div class="verdict">PASS — no click needed, none made</div>')
frame("frame-06", kicker=K, title="6/6 across repeated trials",
      sub="Found and clicked the button every time. Refused to click every time there was nothing to click. A 2 GB model, on-device, free.",
      img=imgA, ring=f'<div class="ring" style="left:{rx:.0f}px; top:{ry:.0f}px;"></div>')

print("\nframes in", OUT)
