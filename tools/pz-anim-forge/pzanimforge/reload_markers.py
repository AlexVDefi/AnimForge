"""Surgically edit the Gunworks reload attachment markers in an AnimSet node XML.

A muzzleloader reload node (e.g. Musket1770_Load.xml) carries timeline events as <m_Events> blocks.
Three of them are the attachment markers the in-game editor tunes:

    gwSetProp     <m_TimePc>0.30</m_TimePc>  <m_ParameterValue>Gunsmithing.MusketBall</m_ParameterValue>
    gwPartToHand  <m_TimePc>0.50</m_TimePc>  <m_ParameterValue>Gunsmithing.Musket1770_RamRod</m_ParameterValue>
    gwPartToGun   <m_TimePc>0.78</m_TimePc>  <m_ParameterValue>Gunsmithing.Musket1770_RamRod</m_ParameterValue>

The engine fires each when normalized playback crosses its <m_TimePc> (a 0..1 clip fraction), so
"retiming an attachment" is just rewriting that fraction. This module edits ONLY those gw marker
blocks - the loadFinished / playReloadSound preamble, the node conditions, and every other byte are
preserved verbatim (text surgery, not an XML reserialise). LF line endings are kept.
"""
from __future__ import annotations

import os
import re

# The editable attachment-marker event names (everything else in <m_Events> is preserved as-is).
# gwSetProp -> off-hand (Prop2) slot; gwSetHandProp -> right-hand slot; the gwPart* pair moves a gun
# part into/out of the off-hand slot; gwSetPart swaps the part at a gun attachment location
# (value "PartType=fullType", or "PartType=" to detach).
GW_EVENTS = ("gwSetProp", "gwSetHandProp", "gwPartToHand", "gwPartToGun", "gwSetPart")

_BLOCK_RE = re.compile(r"[ \t]*<m_Events>.*?</m_Events>(?:\r?\n)?", re.DOTALL)
_NAME_RE = re.compile(r"<m_EventName>\s*(.*?)\s*</m_EventName>", re.DOTALL)
_TIMEPC_RE = re.compile(r"<m_TimePc>\s*(.*?)\s*</m_TimePc>", re.DOTALL)
_TIME_RE = re.compile(r"<m_Time>\s*(.*?)\s*</m_Time>", re.DOTALL)
_VALUE_RE = re.compile(r"<m_ParameterValue>(.*?)</m_ParameterValue>", re.DOTALL)


def _fmt_pc(v):
    return "%.4f" % float(v)


def read_markers(text):
    """Parse every <m_Events> block into {event, timePc|time, value}. Order preserved."""
    out = []
    for block in _BLOCK_RE.findall(text):
        nm = _NAME_RE.search(block)
        if not nm:
            continue
        event = nm.group(1)
        val_m = _VALUE_RE.search(block)
        rec = {"event": event, "value": val_m.group(1) if val_m else ""}
        tpc = _TIMEPC_RE.search(block)
        tm = _TIME_RE.search(block)
        if tpc:
            rec["timePc"] = float(tpc.group(1))
        elif tm:
            rec["time"] = tm.group(1)
        out.append(rec)
    return out


def _marker_block(marker, nl="\n"):
    """Render one editable gw marker (always fraction-timed) as an <m_Events> block (2-space indent).

    `nl` is the file's line ending (LF or CRLF), so the inserted block matches the surrounding text
    and does not churn line endings in a diff.
    """
    return nl.join(
        (
            "  <m_Events>",
            "    <m_EventName>%s</m_EventName>",
            "    <m_TimePc>%s</m_TimePc>",
            "    <m_ParameterValue>%s</m_ParameterValue>",
            "  </m_Events>",
            "",
        )
    ) % (marker["event"], _fmt_pc(marker.get("timePc", 0.0)), marker.get("value", "") or "")


def write_markers(text, markers):
    """Return `text` with its gw attachment markers replaced by `markers` ([{event,timePc,value}]).

    Non-gw <m_Events> (loadFinished / playReloadSound) and everything else are untouched; the new gw
    blocks are inserted just before </animNode> (the engine sorts events by timePc at parse, so file
    order is irrelevant). Idempotent apart from the fractions the editor changed.
    """
    for m in markers:
        if m.get("event") not in GW_EVENTS:
            raise ValueError("marker event %r is not an editable attachment marker" % m.get("event"))

    def drop_gw(block):
        nm = _NAME_RE.search(block)
        return "" if (nm and nm.group(1) in GW_EVENTS) else block

    stripped = _BLOCK_RE.sub(lambda mo: drop_gw(mo.group(0)), text)

    nl = "\r\n" if "\r\n" in text else "\n"   # match the file's line ending so diffs stay clean
    new_blocks = "".join(_marker_block(m, nl) for m in markers)
    idx = stripped.rfind("</animNode>")
    if idx == -1:
        raise ValueError("no </animNode> in node file")
    return stripped[:idx] + new_blocks + stripped[idx:]


def edit_file(src, dst, markers):
    """Read `src` node XML, replace its gw markers with `markers`, write `dst` (== src for in place)."""
    with open(src, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()
    before = read_markers(text)
    new_text = write_markers(text, markers)
    os.makedirs(os.path.dirname(os.path.abspath(dst)) or ".", exist_ok=True)
    with open(dst, "w", encoding="utf-8", newline="") as fh:
        fh.write(new_text)
    after = read_markers(new_text)
    return {
        "ok": True, "src": os.path.abspath(src), "dst": os.path.abspath(dst),
        "inPlace": os.path.abspath(src) == os.path.abspath(dst),
        "gwBefore": [m for m in before if m.get("event") in GW_EVENTS],
        "gwAfter": [m for m in after if m.get("event") in GW_EVENTS],
        "preserved": [m for m in after if m.get("event") not in GW_EVENTS],
    }


# ---- offline self-test -----------------------------------------------------

_SAMPLE = """<?xml version="1.0" encoding="utf-8"?>
<animNode>
  <m_Name>Musket1770_Load</m_Name>
  <m_AnimName>Bob_MusketReload</m_AnimName>
  <m_Conditions>
    <m_Name>GunworksReloadAnim</m_Name>
    <m_Type>STRING</m_Type>
    <m_StringValue>Musket1770</m_StringValue>
  </m_Conditions>
  <m_Events>
    <m_EventName>loadFinished</m_EventName>
    <m_Time>End</m_Time>
    <m_ParameterValue></m_ParameterValue>
  </m_Events>
  <m_Events>
    <m_EventName>playReloadSound</m_EventName>
    <m_TimePc>0.3000</m_TimePc>
    <m_ParameterValue>load</m_ParameterValue>
  </m_Events>
  <m_Events>
    <m_EventName>gwSetProp</m_EventName>
    <m_TimePc>0.0500</m_TimePc>
    <m_ParameterValue>Gunsmithing.PaperCartridge</m_ParameterValue>
  </m_Events>
  <m_Events>
    <m_EventName>gwSetProp</m_EventName>
    <m_TimePc>0.3000</m_TimePc>
    <m_ParameterValue>Gunsmithing.MusketBall</m_ParameterValue>
  </m_Events>
</animNode>
"""


def _selftest():
    ok = True
    before = read_markers(_SAMPLE)
    gw_before = [m for m in before if m["event"] in GW_EVENTS]
    ok = ok and len(gw_before) == 2 and len(before) == 4
    print("  parsed %d events (%d gw, %d preamble)" % (len(before), len(gw_before), len(before) - len(gw_before)))

    # retime the ball 0.30 -> 0.15, keep the cartridge, add a clear at 0.60
    new = [
        {"event": "gwSetProp", "timePc": 0.05, "value": "Gunsmithing.PaperCartridge"},
        {"event": "gwSetProp", "timePc": 0.15, "value": "Gunsmithing.MusketBall"},
        {"event": "gwSetProp", "timePc": 0.60, "value": ""},
    ]
    out = write_markers(_SAMPLE, new)
    after = read_markers(out)
    gw_after = [m for m in after if m["event"] in GW_EVENTS]
    preamble_after = [m for m in after if m["event"] not in GW_EVENTS]

    ok = ok and len(gw_after) == 3
    ball = next((m for m in gw_after if m.get("value") == "Gunsmithing.MusketBall"), None)
    ok = ok and ball is not None and abs(ball["timePc"] - 0.15) < 1e-6
    # preamble preserved verbatim
    ok = ok and len(preamble_after) == 2
    ok = ok and any(m["event"] == "loadFinished" and m.get("time") == "End" for m in preamble_after)
    ok = ok and any(m["event"] == "playReloadSound" and abs(m.get("timePc", 0) - 0.30) < 1e-6 for m in preamble_after)
    # the empty <m_ParameterValue></m_ParameterValue> round-trips
    ok = ok and "<m_ParameterValue></m_ParameterValue>" in out
    # conditions untouched
    ok = ok and "<m_StringValue>Musket1770</m_StringValue>" in out
    print("  after: gw=%d preamble=%d, ball@%.4f" % (len(gw_after), len(preamble_after), ball["timePc"]))
    print("selftest:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if _selftest() else 1)
