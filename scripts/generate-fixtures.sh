#!/bin/bash
set -euo pipefail

FIXTURES_DIR="$(dirname "$0")/../Packages/TranscriptionCore/Fixtures"
mkdir -p "$FIXTURES_DIR"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg is required but not installed."; exit 1; }

generate() {
    local name="$1" voice="$2" lang="$3" text="$4"
    local aiff="$FIXTURES_DIR/${name}.aiff"
    local wav="$FIXTURES_DIR/${name}.wav"
    local expected="$FIXTURES_DIR/${name}.expected.txt"

    echo "Generating $name..."
    say -v "$voice" -o "$aiff" "$text"
    ffmpeg -y -i "$aiff" -ar 16000 -ac 1 -f wav -acodec pcm_f32le "$wav" 2>/dev/null
    rm "$aiff"
    printf '%s\n%s\n' "$lang" "$text" > "$expected"
}

generate "en_hello_world"         "Samantha"  "en" "hello world"
generate "en_the_quick_brown_fox" "Samantha"  "en" "the quick brown fox jumps over the lazy dog"
generate "en_meeting_notes"       "Samantha"  "en" "we agreed to migrate the staging environment to the new account by Friday and the team will open a pull request"
generate "en_numbers_and_dates"   "Samantha"  "en" "the meeting is scheduled for January 15th 2025 at 3 30 in the afternoon"
generate "he_shalom_olam"         "Carmit"    "he" "שלום עולם"
generate "he_toda_raba"           "Carmit"    "he" "תודה רבה על העזרה"
generate "he_meeting_summary"     "Carmit"    "he" "סיכמנו שנעביר את סביבת הבדיקות לחשבון החדש עד יום שישי"
generate "he_technical"           "Carmit"    "he" "צריך לעדכן את הגרסה של המערכת ולבדוק שהכל עובד כמו שצריך"

# Quiet speech: generate at normal volume then reduce
generate "en_quiet_speech"        "Samantha"  "en" "this is quiet speech"
ffmpeg -y -i "$FIXTURES_DIR/en_quiet_speech.wav" -af "volume=0.05" \
    -ar 16000 -ac 1 -f wav -acodec pcm_f32le \
    "$FIXTURES_DIR/en_quiet_speech_tmp.wav" 2>/dev/null
mv "$FIXTURES_DIR/en_quiet_speech_tmp.wav" "$FIXTURES_DIR/en_quiet_speech.wav"
echo "0.5" > "$FIXTURES_DIR/en_quiet_speech.max-wer"

echo "Done. Generated $(ls "$FIXTURES_DIR"/*.wav 2>/dev/null | wc -l | tr -d ' ') fixtures."
