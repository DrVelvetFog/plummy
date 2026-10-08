"""Plummy voice bake-off: the same three lines in four Kokoro voices -> WAVs."""
import numpy as np
import soundfile as sf
from kokoro import KPipeline

LINES = [
    "Hey — I'm Plummy. I live on the old iPhone, and I run the Mac.",
    "Verified — I'm a hybrid agent. A real human delegated my key. I just checked the chain, so that's its word, not mine.",
    "Put the window on the left? Done. If you want it back, just say undo.",
]
VOICES = ["af_heart", "af_bella", "af_nicole", "af_sky"]

pipeline = KPipeline(lang_code="a")  # American English
text = " ... ".join(LINES)
for voice in VOICES:
    chunks = [audio for (_, _, audio) in pipeline(text, voice=voice)]
    audio = np.concatenate(chunks)
    out = f"plummy-voice-{voice}.wav"
    sf.write(out, audio, 24000)
    print(out, f"{len(audio)/24000:.1f}s")
