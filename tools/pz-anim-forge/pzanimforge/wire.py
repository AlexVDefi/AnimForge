"""Emit AnimSet XML so a converted clip is actually played by the game.

Two modes:
  - Override: ship the .glb under the SAME name as a vanilla clip. The engine
    prefers the mod's .glb over the vanilla .x, so NO AnimSet XML is needed.
  - New node: ship the .glb under a NEW name and add an AnimNode that plays it,
    gated to a specific weapon (via WeaponReloadType) or a custom anim variable,
    so only your gun uses it. That node XML is generated here.

The node structure mirrors vanilla handgun AnimSet nodes (m_AnimName must equal
the .glb filename without extension).
"""

import os

NODE_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<animNode>
    <m_Name>{node_name}</m_Name>
    <m_AnimName>{anim_name}</m_AnimName>
    <m_BlendTime>{blend_time}</m_BlendTime>
    <m_Looped>{looped}</m_Looped>
    <m_ConditionPriority>{priority}</m_ConditionPriority>
{conditions}</animNode>
"""

CONDITION_TEMPLATE = """    <m_Conditions>
        <m_Name>{name}</m_Name>
        <m_Type>{ctype}</m_Type>
        <m_Value>{value}</m_Value>
    </m_Conditions>
"""


def make_node_xml(node_name, anim_name, conditions, blend_time=0.2,
                  looped=True, priority=10):
    cond_xml = "".join(
        CONDITION_TEMPLATE.format(name=c["name"], ctype=c.get("type", "STRING"),
                                  value=c["value"])
        for c in (conditions or [])
    )
    return NODE_TEMPLATE.format(
        node_name=node_name, anim_name=anim_name,
        blend_time=blend_time, looped=str(looped).lower(),
        priority=priority, conditions=cond_xml,
    )


def write_node(mod_root, state_subdir, node_name, anim_name, conditions,
               build="42", **kw):
    """Write an AnimNode XML into <mod_root>/<build>/media/AnimSets/<state_subdir>/.
    state_subdir e.g. 'player/idle' or 'player/aim' or 'player/actions'."""
    out_dir = os.path.join(mod_root, build, "media", "AnimSets", state_subdir)
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, node_name + ".xml")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(make_node_xml(node_name, anim_name, conditions, **kw))
    return out_path
