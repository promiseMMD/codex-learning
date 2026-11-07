"""W3 hotfix applied after W1/W2/W3 overlays: replay cursor and status.

This patch is deliberately verified by exact anchors. Never silently patch a
different upstream source or expose writes.
"""
from pathlib import Path

p = Path('mobile/lib/app/home/mod_lan_service.dart')
s = p.read_text(encoding='utf-8')

def replace_one(old, new):
    global s
    if s.count(old) != 1:
        raise RuntimeError(f'W3 replay fix anchor changed ({s.count(old)}): {old[:45]}')
    s = s.replace(old, new, 1)

replace_one("'mode': 'w1_read_only'", "'mode': 'w3_realtime_read_only'")
replace_one("'type': 'reset', 'epoch': hub.epoch,\n          'reason': 'new_or_unknown_cursor'",
            "'type': 'reset', 'epoch': hub.epoch,\n          'sequence': hub.sequence, 'reason': 'new_or_unknown_cursor'")
replace_one("'type': 'reset', 'epoch': hub.epoch,\n            'reason': 'replay_window_expired'",
            "'type': 'reset', 'epoch': hub.epoch,\n            'sequence': hub.sequence, 'reason': 'replay_window_expired'")
replace_one("if(epoch!==payload.epoch){epoch=payload.epoch;cursor=0;scheduleRefresh()}",
            "if(epoch!==payload.epoch){epoch=payload.epoch;cursor=Number(payload.sequence)||0;scheduleRefresh()}")
replace_one("epoch=payload.epoch;cursor=0;scheduleRefresh();",
            "epoch=payload.epoch;cursor=Math.max(cursor,Number(payload.sequence)||0);scheduleRefresh();")

p.write_text(s, encoding='utf-8')
print('W3 cursor replay patch applied')
