# Cove 0.1.67, build 69: Ask Cove reads attachments

## User request

"allow to read … my question will be give the amounts and capture lines that are on the pdf", shown on an email with two PDFs (IMSS and ISN payment forms). The user then asked to "deploy to all".

## Changes

- **Shared reader:** `AttachmentText` (CoveCore) is the extraction agents already used, now shared by Mac and iPhone:
  - PDFs, including `.pdf` names that Gmail labels octet-stream, and text files;
  - the first five files, 5 MB each, 20 PDF pages;
  - scans and images are returned as warnings, never guesses.
- **Prompts:** `AIPrompt(files:)` gives file text its own budget (`AIPromptLimits.fileBytes`: 24 KB standard, 1.5 KB on-device, none at the minimal on-device size), split per file. It sits in `dataMessage` as untrusted text cited as [1], with an instruction to quote amounts, references and codes exactly. `resized` keeps the files.
- **Mac:** Ask Cove's selected-email answers and follow-ups include the file text (`AppStore.attachmentTexts`, cached per email this session). Progress shows "Reading attachments…" and the source line "read N attachments".
- **iPhone/iPad:** the reader's Ask Cove does the same (`MobileMailbox.attachmentTexts`) and shows "Read N attachments".
- **Privacy page:** it now says attachment text is included when asking about an email.

## Verification

- **Mac suite:** TEST SUCCEEDED (both suites, 0 failures). New tests:
  - `PromptFilesTests`: exact figures in their own section; separate from the shared evidence budget; each file gets a share; smaller models get less; resizing keeps files.
  - `AttachmentTextTests`: a real generated PDF labeled octet-stream yields the amount and capture line; a JPEG is reported; the result is cached.
- **iPhone:** the simulator build succeeded.
- **Not done:** not run against the user's real IMSS and ISN PDFs. If those are scans without a text layer, they will be reported as unreadable.

## Release

- **App notarization:** `c4d798af-983f-4517-a56a-32e9ecb1ae43`, Accepted and stapled.
- **DMG notarization:** `bed737eb-0ab8-4bd4-bd94-8d8207ce99f2`, Accepted and stapled.
- **DMG:** 24,570,132 bytes, SHA-256 `ae3f73f53574e8319cb4f51f1367ba4abc9579ebd64078b8517ec7a988b6359c`.
- **Feed:**
  - Signed with 46 verified downloads.
  - The appcast keeps the newest three entries: 0.1.64 aged out of the feed, and its DMG is still published.
  - The 0.1.65 and 0.1.66 signatures are unchanged.
- **Site:** Cloudflare Pages deployment `6a221d07`.
- **Public checks:**
  - `/release.json` reports 0.1.67 (build 69); the beta page, `/download/latest` and the privacy text are updated.
  - The SHA-256 matches.
  - The Ed25519 signature verifies, and a one-byte change is rejected.
- **TestFlight:** build 16 was uploaded.
