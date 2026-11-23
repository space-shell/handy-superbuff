# Phase 0: Accessibility spike results

Machine: MacBook Pro M5, 16 GB, macOS 26.7.3. Date: 2026-11-23.
Paseo 0.17.3 (Electron 44.2.0), Chrome, Safari, TextEdit on their installed versions.
Tool: `spike/axprobe.swift`, run by `spike/phase0.sh`. Raw output in `spike/out/<app>.txt`.
Test text: 207,685 UTF-16 units (a header line with an emoji, then 20,000 dictionary words).

**Go for design A.** The Paseo composer can be read and selected through the
Accessibility API, and typed text lands at the caret and replaces a selection.

## Phase 0 table

| App            | Read text                                                                                                                                                 | Read caret and selection                                   | Set selection                                            | Typing lands at caret | Typing replaces a selection |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | -------------------------------------------------------- | --------------------- | --------------------------- |
| Paseo composer | First 9,998 units in 0.1 ms. 200,000 units in 2.8 ms by paging `AXStringForRange` (20 calls). Nothing past 200,000 that way; `AXSelectedText` reads there | Yes (caret at 207,685 after the paste, at 41 after typing) | Yes, read-back and text exact at 31, 150,000 and 205,000 | Yes                   | Yes                         |
| Chrome         | Same as Paseo: 9,998 units in 0.1 ms, 200,000 units in 3.6 ms by paging                                                                                   | Yes                                                        | Yes, at 31, 150,000 and 205,000                          | Yes                   | Yes                         |
| TextEdit       | All 207,685 units in 0.1 ms                                                                                                                               | Yes                                                        | Yes                                                      | Yes                   | Yes                         |
| Safari         | Not measured: the probe did not find the page's text area (the address bar had focus)                                                                     |                                                            |                                                          |                       |                             |

Every run ended with the test text deleted. Chrome and TextEdit windows were closed.

## Findings

1. Chromium apps answer with defaults unless their window is key: a selection reads as
   (0, 0), a write reports success and changes nothing, and `AXStringForRange` returns
   an empty string.
2. Chromium cuts `AXValue` and `AXNumberOfCharacters` at about 10,000 units. It cuts
   `AXStringForRange` at offset 200,000. `AXSelectedText` is not cut: 200,000 selected
   units came back whole, and a selection at 205,000 reads correctly.
3. Chromium rejects a selection longer than the field, so the true length is needed
   to select everything. Paged reads give it up to 200,000 units; cleanup took two passes.
4. Electron hands out element handles that die while its tree is first built: one run
   read an element, then got `invalidUIElement` 100 ms later.
5. The composer was not the focused element in the final Paseo run (an `AXGroup` was).
   Searching the focused window found it after 826 elements, by its description
   "Message agent".
6. Offsets are UTF-16 code units in all three apps: the emoji at 18 is selected as 18..20.
7. Agent shells are Accessibility-trusted once Ghostty is. `AXIsProcessTrusted()` was
   false for the agent shell before Ghostty was granted and true afterwards.
8. Chrome built no tree for 12 s of AX queries on its first run. The next run set
   `AXEnhancedUserInterface` (the call returned `notImplemented`) and the tree was
   there. The two causes were not separated.
9. With the screen locked nothing works: no key window, no activation. `AXWindows`
   of background apps also came back empty once while Paseo was frontmost.

## Consequences for the design

- `field` reads the first 10,000 units from `AXValue`, the next 190,000 by paging
  `AXStringForRange`, and anything further through `AXSelectedText` after a selection.
  A field that cannot be read whole gets design B (select-all and copy) or a refusal.
- `field` re-resolves the focused element for every operation and never caches the
  handle from recording start.
- The target app must stay frontmost with a key window. The overlay must not take key
  status: verify in Phase 3.
- Offsets are converted between UTF-16 and Rust strings at the boundary.
- F2 targets the focused text field and refuses with a notice when none is focused.

## Running it

From a terminal with Accessibility, screen unlocked, Mac left alone:

    spike/phase0.sh all        # paseo, chrome, safari, textedit
    spike/phase0.sh paseo

Each app comes to the front for about 15 seconds. The probe types only into a field
that shows exactly the text it expects, and only while that app is frontmost. It
deletes the test text afterwards and closes the windows it opened.

    spike/out/axprobe purge <pid> paseo spike/out/pasted-as-is.txt

removes test text that an interrupted run left in the focused Paseo composer.

## Traps met while writing the probe

- `pbcopy` and `pbpaste` use the shell's encoding. In a shell without a UTF-8 locale
  they turn the emoji into four MacRoman characters. The script sets `LC_ALL`.
- With bun 1.4.4, `bun run tauri build -- --bundles app` passes `--` to cargo. Call
  `node_modules/.bin/tauri` directly.
- A nix `RUSTUP_HOME = "\${HOME}/.rustup"` attribute is not shell-expanded. Export it
  in the shell hook.
- A conditional downcast to a CF class type (`as? AXValue`) does not check anything.
  Compare `CFGetTypeID` with the type's `GetTypeID()`.
- `AXError` does not conform to `Error`; `Result.value` is not available for it.

## Phase 1 facts (macOS, Command Line Tools only)

- Build: `nix develop --command sh spike/out/build-app.sh`, 3 min 43 s cold.
- Apple Intelligence is compiled as stubs: `FoundationModels` needs full Xcode.
