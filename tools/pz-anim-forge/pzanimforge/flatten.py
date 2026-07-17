"""Flatten a PZ AnimSet node by resolving its `x_extends` chain offline.

This is a faithful port of the engine's merge so a generated mod node can be
SELF-CONTAINED (no `x_extends`). That matters because the engine resolves
`x_extends` RELATIVE TO THE FILE'S OWN FOLDER
(zombie/util/PZXmlUtil.java parseXml L62-69 -> resolveRelativePath); a mod node
that keeps `x_extends="aim.xml"` looks for `aim.xml` inside the MOD folder, throws
FileNotFoundException at AnimNode.Parse, and the whole node is silently dropped
(only the client DebugLog shows it) so vanilla plays. Flattening sidesteps that.

The merge mirrors `PZXmlUtil.resolve` + `TagTable.resolveWith` exactly:
  - result element = child's tag; attributes = parent's then child's (child wins);
    `x_extends`/`x_include` are dropped from the final root.
  - children are keyed by (tagName, key) where key = the `x_name` attribute if
    present, else `node_<i>` with i = the element's 0-based ordinal AMONG ALL
    same-tag siblings (named and unnamed counted together, in document order -
    matching TagTable.getTagIndex using namedTags.size()).
  - a child element whose key matches a parent entry REPLACES it if the child is
    a text-only leaf (e.g. <m_AnimName>X</m_AnimName>), else merges recursively.
    Unmatched child elements are appended after the parent's, in child order.

Engine references (bin/output/zombie/util/PZXmlUtil.java):
  parseXml L51-73, resolve L125-184, isTextOnly L186-206,
  TagTable.createTagTable L357-370, getEntry L372-381, addEntry/getTagIndex
  L383-428, resolveWith L430-439.
"""
from __future__ import annotations

import copy
import os
import sys
import xml.etree.ElementTree as ET


def _parse(path):
    """Parse one node file into its root Element (no resolution)."""
    if not os.path.isfile(path):
        raise FileNotFoundError("AnimSet node file not found: %s" % path)
    return ET.parse(path).getroot()


def _is_text_only(elem):
    """True iff `elem` has a non-whitespace text value and no child elements.

    Matches PZXmlUtil.isTextOnly: such a child REPLACES its parent counterpart
    wholesale; an empty element (no children, no text) is NOT text-only, so it
    merges and contributes nothing (keeping the parent's content).
    """
    if len(elem) > 0:
        return False
    return elem.text is not None and elem.text.strip() != ""


def _entries(elem):
    """Ordered list of {tag, key, el(deep copy)} for elem's child elements.

    key replicates TagTable: x_name if set, else node_<ordinal among same-tag
    siblings>. Deep-copied so merging never mutates a shared source tree.
    """
    counter = {}
    out = []
    for child in list(elem):
        tag = child.tag
        idx = counter.get(tag, 0)
        counter[tag] = idx + 1
        xname = child.get("x_name")
        key = xname.strip() if xname and xname.strip() else "node_%d" % idx
        out.append({"tag": tag, "key": key, "el": copy.deepcopy(child)})
    return out


def _resolve(child, parent):
    """Merge `child` over `parent` (PZXmlUtil.resolve). Returns a new Element."""
    if _is_text_only(child):
        return copy.deepcopy(child)

    result = ET.Element(child.tag)
    merged_attrs = dict(parent.attrib)
    merged_attrs.update(child.attrib)  # child overrides same-named attributes
    result.attrib = merged_attrs

    ordered = _entries(parent)
    index = {(e["tag"], e["key"]): e for e in ordered}
    for ce in _entries(child):
        k = (ce["tag"], ce["key"])
        pe = index.get(k)
        if pe is None:
            ordered.append(ce)
            index[k] = ce
        else:
            pe["el"] = _resolve(ce["el"], pe["el"])

    for e in ordered:
        result.append(e["el"])
    return result


def _flatten_elem(root, basedir):
    ext = root.get("x_extends")
    if ext and ext.strip():
        base_path = os.path.join(basedir, ext.strip())
        base = _flatten_elem(_parse(base_path), os.path.dirname(base_path))
        merged = _resolve(root, base)
    else:
        merged = copy.deepcopy(root)
    # The engine ignores these post-resolve; we must strip them so the engine
    # does not try to re-resolve relative to the mod folder (and fail).
    merged.attrib.pop("x_extends", None)
    merged.attrib.pop("x_include", None)
    return merged


def flatten_file(path):
    """Return the fully-resolved (self-contained) root Element for a node file.

    `x_extends` targets are bare filenames resolved in the SAME directory as the
    referring file (vanilla never uses cross-dir extends or x_include), recursed
    to any depth.
    """
    return _flatten_elem(_parse(os.path.abspath(path)), os.path.dirname(os.path.abspath(path)))


def to_pretty_xml(elem):
    """Serialise a flattened Element to tab-indented XML with a declaration."""
    e = copy.deepcopy(elem)
    ET.indent(e, space="\t")
    body = ET.tostring(e, encoding="unicode")
    return '<?xml version="1.0" encoding="utf-8"?>\n' + body + "\n"


def main(argv=None):
    argv = argv if argv is not None else sys.argv[1:]
    if not argv:
        raise SystemExit("usage: python -m pzanimforge.flatten <node.xml>")
    sys.stdout.write(to_pretty_xml(flatten_file(argv[0])))


if __name__ == "__main__":
    main()
