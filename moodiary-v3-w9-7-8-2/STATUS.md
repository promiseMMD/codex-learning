# Moodiary W9.7.8.2 — SQLite3 CI-native test isolation

2026-11-08; parent a1c3efdd5d03b49a5cbee7b98bf11522b97eca98.
Two CI runs (42464131349 and 42464432139) failed before app tests on an
upstream sqlite3-3.5.2 Linux shared library SHA mismatch.
Vendor SHA verification MUST NOT be disabled. For Linux CI Flutter unit tests
only, the temporary upstream/pubspec.yaml uses sqlite3 hooks source: system.
The full CI restores the pristine pubspec.yaml before Android APK compilation.
Production native SQLite binary checksum validation is NOT bypassed.
Android runtime parity versus Linux system SQLite remains separately unverified.
Accepted only after full green CI; no release or APK claimed.
Reference: https://github.com/simolus3/sqlite3.dart/blob/main/sqlite3/doc/hook.md