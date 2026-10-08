import time
import numpy as np
from kokoro import KPipeline

pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
line = "Done. The window's on the left now."
# warm-up
_ = [a for (_, _, a) in pipeline(line, voice="af_heart")]
t0 = time.time()
chunks = [a for (_, _, a) in pipeline(line, voice="af_heart")]
dt = time.time() - t0
audio = np.concatenate(chunks)
print(f"synthesized {len(audio)/24000:.1f}s of audio in {dt:.2f}s (warm, CPU)")
