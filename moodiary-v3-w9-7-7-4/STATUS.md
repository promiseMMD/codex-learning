# Moodiary 3.0 W9.7.7.4: Flutter-engine SIGKILL harness

Parent: 79842c1f197f415223aaf1a5f06ef7745968e3e5.
Fast CI 42462043271 exposed true failure: dart:ui is not available in plain dart run.
This patch retains a pure-Dart supervisor and moves all Flutter dependencies to a
separate flutter test process. The supervisor SIGKILLs that engine PID directly.
Fast matrix: directory_moved and pointer_written. Full matrix: all seven phases.
Test-only sandbox under systemTemp; neither app SQLite nor live WebDAV is modified.
Do not claim real Android reboot, power-loss, fsync durability or user-device QA.
Require green sensitive fast + full CI before integration. No APK yet.