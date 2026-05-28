#!/usr/bin/env bash
# Generate a multi-speaker WAV fixture for the audio loopback E2E.
#
# Uses macOS `say` (built-in TTS voices) to synthesise distinct speakers,
# concatenates them with deliberate pauses, and mixes in low-amplitude
# pink-ish noise so the recording isn't pure silence between phrases.
# That noise exercises the same VAD threshold-vs-ambient regression we
# kept tripping over in real conversations.
#
# Output is a single 16 kHz mono WAV that matches the format Mila feeds
# whisper internally. Total length ~120s.
#
# Usage:
#   ./scripts/generate-audio-fixture.sh [output-path] [language]
#
# Defaults:
#   output-path: /tmp/mila-audio-fixture.wav
#   language:    en  (also accepts: he)
#
# Language voices:
#   en → Allison + Tom
#   he → Carmit  (macOS doesn't ship a second Hebrew voice; the speaker
#                 pool test exercises one-voice transcription)

set -euo pipefail

OUT="${1:-/tmp/mila-audio-fixture.wav}"
LANG="${2:-en}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

case "$LANG" in
  en)
    # ~120s of conversation. Alternating speakers + a mix of single-word,
    # short, and long-sentence lines so the VAD has variety.
    LINES=(
      "Allison|Hello team, thanks for joining today's roadmap review."
      "Tom|Hi."
      "Allison|I want to walk through three items: the auth rewrite, the search index migration, and the new billing dashboard."
      "Tom|Sounds good."
      "Allison|For the auth rewrite, the goal is to be done before the end of the quarter, including the legacy session token migration."
      "Tom|Yes, that aligns with what security flagged last sprint."
      "Allison|Who's owning the search index?"
      "Tom|I can take it. The migration tooling from last sprint should still work."
      "Allison|Great."
      "Tom|When do we need to ship?"
      "Allison|Mid March is the target, but the auth rewrite is the hard dependency. The billing dashboard can slip a week if needed."
      "Tom|OK."
      "Allison|Let's also talk about the new analytics pipeline that ingest needs."
      "Tom|How big is that scope? Are we talking weeks or months?"
      "Allison|Probably four to six weeks. We need to backfill historical events and build a real-time stream side by side."
      "Tom|Got it. I'll write up a tech plan by Friday."
      "Allison|Perfect. Let's regroup Thursday and confirm the timeline."
      "Tom|Done."
    )
    ;;
  he)
    # Hebrew equivalent — same conversation shape, same alternating
    # rhythm. Carmit is the only stock Hebrew voice on macOS so both
    # "speakers" share it; the test still exercises transcription +
    # VAD silence detection in Hebrew.
    LINES=(
      "Carmit|שלום צוות, תודה שהצטרפתם לסקירת מפת הדרכים היום."
      "Carmit|היי."
      "Carmit|אני רוצה לעבור על שלושה נושאים: שכתוב המערכת לאימות, מעבר אינדקס החיפוש, ולוח החיובים החדש."
      "Carmit|נשמע טוב."
      "Carmit|לגבי שכתוב המערכת לאימות, המטרה היא לסיים לפני סוף הרבעון, כולל מעבר אסימוני הסשן הישנים."
      "Carmit|כן, זה מתיישב עם מה שצוות האבטחה ציין בספרינט הקודם."
      "Carmit|מי אחראי על אינדקס החיפוש?"
      "Carmit|אני אקח את זה. כלי המעבר מהספרינט הקודם אמורים עוד לעבוד."
      "Carmit|מצוין."
      "Carmit|מתי צריך לשחרר?"
      "Carmit|אמצע מרץ הוא היעד, אבל שכתוב האימות הוא התלות הקשה. לוח החיובים יכול להידחות בשבוע אם צריך."
      "Carmit|בסדר."
      "Carmit|בואו נדבר גם על צינור הניתוחים החדש שהקליטה צריכה."
      "Carmit|כמה גדול ההיקף? אנחנו מדברים על שבועות או חודשים?"
      "Carmit|כנראה ארבעה עד שישה שבועות. צריך למלא אירועים היסטוריים ולבנות זרם בזמן אמת במקביל."
      "Carmit|הבנתי. אכתוב תכנית טכנית עד שישי."
      "Carmit|מושלם. נתכנס שוב ביום חמישי ונאשר את לוח הזמנים."
      "Carmit|סיימנו."
    )
    ;;
  *)
    echo "Unknown language: $LANG (expected en|he)" >&2
    exit 2
    ;;
esac

i=0
for entry in "${LINES[@]}"; do
  voice="${entry%%|*}"
  text="${entry#*|}"
  say -v "$voice" -o "$WORK/$i.aiff" "$text"
  i=$((i + 1))
done
TOTAL=$i

for ((n = 0; n < TOTAL; n++)); do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$WORK/$n.aiff" "$WORK/$n.wav"
done

# Concatenate speech with ~800ms silences between lines so the VAD has
# clear silence threshold crossings. Then mix in low-amplitude noise
# everywhere — ~0.005 RMS — so the "silence" between phrases isn't
# pure zero. Our threshold (0.012) must stay above this floor.
python3 - "$OUT" "$WORK" "$TOTAL" <<'EOF'
import wave, sys, struct, random
out_path, work, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
SR = 16000
SILENCE_MS = 800
NOISE_AMP_INT16 = 200   # ~0.006 of int16 range — quiet ambient floor

silence_samples = SR * SILENCE_MS // 1000

# Pre-generate a noise buffer with a fixed seed for reproducibility.
random.seed(7)
def noise_samples(n):
    return [random.randint(-NOISE_AMP_INT16, NOISE_AMP_INT16) for _ in range(n)]

out = wave.open(out_path, "wb")
first = True
total_dur = 0.0
out_frames = []
for n in range(total):
    w = wave.open(f"{work}/{n}.wav", "rb")
    if first:
        out.setnchannels(w.getnchannels())
        out.setsampwidth(w.getsampwidth())
        out.setframerate(w.getframerate())
        first = False
    raw = w.readframes(w.getnframes())
    speech_samples = list(struct.unpack("<%dh" % (len(raw) // 2), raw))
    out_frames.extend(speech_samples)
    out_frames.extend([0] * silence_samples)
    total_dur += w.getnframes() / w.getframerate() + SILENCE_MS / 1000
    w.close()

# Now mix noise across the whole buffer.
noise = noise_samples(len(out_frames))
mixed = [max(-32767, min(32767, s + ns)) for s, ns in zip(out_frames, noise)]
out.writeframes(struct.pack("<%dh" % len(mixed), *mixed))
out.close()
print(f"Wrote {out_path} ({total_dur:.1f}s, {total} speech segments, ambient noise mixed)")
EOF
