# Moodiary Long-Record Beta — data safety first

This branch is an isolated Beta build for [Moodiary](https://github.com/ZhuJHua/moodiary), derived from upstream commit `2c552ddd7939a054122380397fb914cf000824b0`.

## P0 safety changes
- Durable per-topic local drafts with atomic writes and stable entry IDs.
- Idempotent repeated submission; reject reuse of ID for different contents.
- Preserve event time and new-record creation UTC metadata in original Diary JSON tags.
- Read-only local integrity audit of topics, orphan entries, pin ordering and timestamps.
- Stop automatic upstream push if the prior pull reported partial failures.
- CI runs unit, serialization and simulated cloud round-trip tests **before** building Android APK.

## Limitations
The app keeps the native Moodiary diary, media, ZIP and WebDAV object formats. It does not perform real two-device WebDAV verification in CI. Simultaneous edits of the *same* diary still follow upstream timestamp logic. Unsubmitted drafts are local-only. This Android `alpha`-flavor package uses a temporary debug signing key; upgrading an earlier APK may fail if signatures differ. Do not put personal records in the test WebDAV directory; this is not an independently audited release.

Source bundle: `moodiary-longrecord/build-payload.b64` (Base64 of the downloadable open-source modkit ZIP).

CI: [Beta safety build](https://github.com/promiseMMD/codex-learning/actions/workflows/moodiary-longrecord-beta.yml)
