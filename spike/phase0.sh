#!/bin/sh
# Phase 0 spike for the Handy fork: can the macOS Accessibility API read the
# focused text field, set a selection in it, and does typed text land at the
# caret and replace a selection? Targets: the Paseo composer, two browsers,
# TextEdit.
#
# usage: spike/phase0.sh all | paseo | chrome | safari | textedit
#
# Run it from a terminal that has Accessibility (System Settings > Privacy &
# Security > Accessibility), with the screen unlocked and the Mac left alone.
# Each app comes to the front for about 15 seconds, receives about 20,000
# dictionary words in a text field, two short tokens, and is cleared again.
# The windows the script opens are closed at the end.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SPIKE="$ROOT/spike"
OUT="$SPIKE/out"
mkdir -p "$OUT"

# Text fields only take selections and keystrokes in a key window, and there is none while the screen is locked.
if ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleUsers xml1 -o - - 2>/dev/null | grep -A1 CGSSessionScreenIsLocked | grep -q "<true/>"; then
  echo "the screen is locked: unlock it and run again"
  exit 1
fi

if [ ! -x "$OUT/axprobe" ] || [ "$SPIKE/axprobe.swift" -nt "$OUT/axprobe" ]; then
  echo "== compiling spike/axprobe.swift"
  if ! swiftc -O "$SPIKE/axprobe.swift" -o "$OUT/axprobe" 2> "$OUT/build.log"; then
    echo "compile failed:"
    grep -E "error:" -A4 "$OUT/build.log"
    exit 1
  fi
fi
"$OUT/axprobe" selftest || { echo "axprobe selftest failed"; exit 1; }
"$OUT/axprobe" mktext "$OUT" || exit 1
rm -f "$OUT/paseo.txt" "$OUT/chrome.txt" "$OUT/safari.txt" "$OUT/textedit.txt" "$OUT"/*-value.txt

pid_of() { pgrep -x "$1" | head -n 1; }

# pbcopy and pbpaste read and write in the shell's encoding, which is not UTF-8 in every shell.
clip_in() { LC_ALL=en_US.UTF-8 pbcopy; }
clip_out() { LC_ALL=en_US.UTF-8 pbpaste; }

# clip_save, then the paste, then clip_restore: keeps the clipboard's text (text only).
clip_save() { clip_out > "$OUT/clipboard-before.txt" 2>/dev/null || true; }
clip_restore() {
  if [ -s "$OUT/clipboard-before.txt" ]; then
    clip_in < "$OUT/clipboard-before.txt"
    echo "clipboard: previous text restored"
  else
    printf '' | clip_in
    echo "clipboard: emptied (it held no plain text before the test)"
  fi
}

paseo() {
  echo
  echo "== paseo: pastes the test text into the composer, then clears it"
  pid=$(pid_of "Paseo")
  [ -n "$pid" ] || { echo "Paseo is not running"; return 1; }
  clip_save
  clip_in < "$OUT/test.txt" || return 1
  "$OUT/axprobe" run "$pid" paseo "$OUT" --paste "$OUT/test.txt" --focus "Message agent" 2>&1 | tee "$OUT/paseo.txt"
  clip_restore
}

# fileapp <label> <app name> <extension> <close title part> [paste]
# Opens the test file in the app. With "paste", an app that still shows an emptied copy of
# the document from an earlier run gets the text pasted into it instead.
fileapp() {
  label=$1
  app=$2
  ext=$3
  close_title=$4
  paste=${5:-no}
  sheet=no
  enhance=no
  echo
  echo "== $label: opens spike/out/test.$ext in $app"
  open -a "$app" "$OUT/test.$ext" || return 1
  i=0
  pid=$(pid_of "$app")
  while [ -z "$pid" ] && [ "$i" -lt 30 ]; do
    sleep 0.5
    i=$((i + 1))
    pid=$(pid_of "$app")
  done
  [ -n "$pid" ] || { echo "$app did not start"; return 1; }
  [ "$label" = textedit ] && sheet=yes
  [ "$label" = chrome ] && enhance=yes
  if [ "$paste" = paste ]; then
    clip_save
    clip_in < "$OUT/test.txt"
    "$OUT/axprobe" run "$pid" "$label" "$OUT" --close "$close_title" --sheet "$sheet" --header yes --paste "$OUT/test.txt" 2>&1 | tee "$OUT/$label.txt"
    clip_restore
  else
    "$OUT/axprobe" run "$pid" "$label" "$OUT" --close "$close_title" --sheet "$sheet" --enhance "$enhance" --header yes 2>&1 | tee "$OUT/$label.txt"
  fi
}

case "${1:-all}" in
  all) paseo; fileapp chrome "Google Chrome" html axprobe; fileapp safari Safari html axprobe; fileapp textedit TextEdit txt test.txt paste ;;
  paseo) paseo ;;
  chrome) fileapp chrome "Google Chrome" html axprobe ;;
  safari) fileapp safari Safari html axprobe ;;
  textedit) fileapp textedit TextEdit txt test.txt paste ;;
  *)
    echo "usage: spike/phase0.sh all | paseo | chrome | safari | textedit"
    exit 1
    ;;
esac

echo
echo "== summary"
grep -h "^RESULT" "$OUT/paseo.txt" "$OUT/chrome.txt" "$OUT/safari.txt" "$OUT/textedit.txt" 2>/dev/null || true
