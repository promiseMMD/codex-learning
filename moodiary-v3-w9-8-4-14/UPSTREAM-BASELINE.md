# Official Moodiary upstream baseline

Repository: https://github.com/ZhuJHua/moodiary
Branch observed: develop
Pinned commit: 570ff99cd150fb2d45eb0949344f7bda22e32bde
Commit date: 2026-11-09 04:31:59 UTC

The previous project baseline was the 2.9.2 release commit
2c552ddd7939a054122380397fb914cf000824b0. The develop branch is two commits
ahead of that release. The intervening commits update README download badges,
mood-insights UI behavior/tests, and dependency declarations. No custom W9
feature is part of the official upstream delta.

CI must use the exact pinned commit above, not a floating develop branch, to
keep Fast CI, Full CI and APK provenance reproducible. Before a future release,
check the official develop head again and explicitly review any new upstream
delta before changing this pin.
