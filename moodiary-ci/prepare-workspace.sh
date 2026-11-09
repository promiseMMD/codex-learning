#!/usr/bin/env bash
# The one pinned upstream + all historical overlays shared by ALL CI tiers.
# Refuse silent failures: no incremental overlay may skip a missing source.
set -euo pipefail
if [[ ! -f moodiary-longrecord/build-payload.b64 ]]; then
  echo "Missing checked-out W1 source bundle; run from repository root" >&2
  exit 2
fi
set -euo pipefail
base64 --decode moodiary-longrecord/build-payload.b64 > /tmp/moodiary-v3-w1.zip
unzip -q /tmp/moodiary-v3-w1.zip
python3 moodiary-ci/inspect-w1-topic-classifier.py
python3 modkit/verify_patch.py
set -euo pipefail
git clone --no-checkout https://github.com/ZhuJHua/moodiary.git upstream
cd upstream
git checkout 570ff99cd150fb2d45eb0949344f7bda22e32bde
python3 ../modkit/apply_beta_patch.py .
python3 ../modkit/apply_v3_patch.py .
unzip -q ../moodiary-v3-w2/ledger-source.zip -d /tmp/moodiary-v3-w2
cp /tmp/moodiary-v3-w2/overlay/mobile/lib/app/home/mod_monthly_ledger.dart mobile/lib/app/home/
cp /tmp/moodiary-v3-w2/overlay/mobile/test/mod_monthly_ledger_test.dart mobile/test/
base64 --decode ../moodiary-v3-w3/live-events.b64 > /tmp/moodiary-v3-w3.zip
unzip -q /tmp/moodiary-v3-w3.zip -d /tmp/moodiary-v3-w3
cp /tmp/moodiary-v3-w3/overlay/mobile/lib/app/home/mod_lan_service.dart mobile/lib/app/home/
cp /tmp/moodiary-v3-w3/overlay/mobile/lib/app/home/mod_lan_events.dart mobile/lib/app/home/
cp /tmp/moodiary-v3-w3/overlay/mobile/test/mod_lan_events_test.dart mobile/test/
python3 ../moodiary-v3-w3/fix_replay_cursor.py
base64 --decode ../moodiary-v3-w4/source.b64 > /tmp/moodiary-v3-w4.zip
unzip -q /tmp/moodiary-v3-w4.zip -d /tmp/moodiary-v3-w4
python3 /tmp/moodiary-v3-w4/scripts/patch_repository.py .
cp /tmp/moodiary-v3-w4/overlay/mobile/lib/app/home/mod_lan_service.dart mobile/lib/app/home/
cp /tmp/moodiary-v3-w4/overlay/mobile/lib/app/home/mod_lan_write.dart mobile/lib/app/home/
cp /tmp/moodiary-v3-w4/overlay/mobile/lib/app/home/mod_lan_page.dart mobile/lib/app/home/
cp /tmp/moodiary-v3-w4/overlay/mobile/test/mod_lan_write_test.dart mobile/test/
cp /tmp/moodiary-v3-w4/overlay/mobile/test/mod_lan_database_cas_test.dart mobile/test/
python3 ../moodiary-v3-w5/apply_w5.py .
python3 ../moodiary-v3-w6/apply_w6.py .
python3 ../moodiary-v3-w7/apply_w7.py .
python3 ../moodiary-v3-w8/apply_w8.py .
python3 ../moodiary-v3-w8-http/apply_w8_http.py .
python3 ../moodiary-v3-w8-attach/apply_w8_attach.py .
python3 ../moodiary-v3-w9/apply_w9.py .
python3 ../moodiary-v3-w9-2/apply_w9_2.py .
python3 ../moodiary-v3-w9-3/apply_w9_3.py .
python3 ../moodiary-v3-w9-4/apply_w9_4.py .
python3 ../moodiary-v3-w9-5/apply_w9_5.py .
python3 ../moodiary-v3-w9-5-2/apply_w9_5_2.py .
python3 ../moodiary-v3-w9-6/apply_w9_6.py .
python3 ../moodiary-v3-w9-7-1/apply_w9_7_1.py .
python3 ../moodiary-v3-w9-7-2/apply_w9_7_2.py .
python3 ../moodiary-v3-w9-7-3/apply_w9_7_3.py .
python3 ../moodiary-v3-w9-7-4/apply_w9_7_4.py .
python3 ../moodiary-v3-w9-7-5/apply_w9_7_5.py .
python3 ../moodiary-v3-w9-7-6/apply_w9_7_6.py .
python3 ../moodiary-v3-w9-7-7/apply_w9_7_7.py .
python3 ../moodiary-v3-w9-7-7-2/apply_w9_7_7_2.py .
python3 ../moodiary-v3-w9-7-7-4/apply_w9_7_7_4.py .
python3 ../moodiary-v3-w9-7-8/apply_w9_7_8.py .
python3 ../moodiary-v3-w9-7-8-3/apply_w9_7_8_3.py .
python3 ../moodiary-v3-w9-7-8-4/apply_w9_7_8_4.py .
python3 ../moodiary-v3-w9-8-1/apply_w9_8_1.py .
python3 ../moodiary-v3-w9-8-2/apply_w9_8_2.py .
python3 ../moodiary-v3-w9-8-3/apply_w9_8_3.py .
python3 ../moodiary-v3-w9-8-4-1/apply_w9_8_4_1.py .
python3 ../moodiary-v3-w9-8-4-2/apply_w9_8_4_2.py .
python3 ../moodiary-v3-w9-8-4-3/apply_w9_8_4_3.py .
python3 ../moodiary-v3-w9-8-4-4/apply_w9_8_4_4.py .
python3 ../moodiary-v3-w9-8-4-5/apply_w9_8_4_5.py .
python3 ../moodiary-v3-w9-8-4-6/apply_w9_8_4_6.py .
python3 ../moodiary-v3-w9-8-4-7/apply_w9_8_4_7.py .
python3 ../moodiary-v3-w9-8-4-8/apply_w9_8_4_8.py .
python3 ../moodiary-v3-w9-8-4-9/apply_w9_8_4_9.py .
python3 ../moodiary-v3-w9-8-4-10/apply_w9_8_4_10.py .
python3 ../moodiary-v3-w9-8-4-11/apply_w9_8_4_11.py .
python3 ../moodiary-v3-w9-8-4-13/apply_w9_8_4_13.py .
