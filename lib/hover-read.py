#!/usr/bin/env python3
"""Print whatever text AT-SPI exposes at a given screen coordinate.

Usage: hover-read.py <x> <y>

Internal helper for `hyprland-tts hover` (see lib/hover.sh for the full scope
notes). Best-effort accessibility integration: only finds anything in apps
that implement AT-SPI (GTK/Qt/Electron apps, most browsers) — terminals,
games, and other custom-rendered apps generally expose nothing here. Silent
(no output, exit 0) whenever AT-SPI is unavailable or nothing is found at the
point; the caller already treats empty output as "nothing to speak", so this
never needs to raise a scary error for what is an optional, opt-in feature.
"""
import sys

try:
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
except Exception:
    sys.exit(0)


# Safety valve for pathological trees (a browser tab can expose tens of
# thousands of accessible nodes for its DOM) — bounded by node count here,
# and the caller (lib/hover.sh) additionally wraps this whole script in a
# hard wall-clock `timeout`, so a slow/huge tree degrades to "nothing found"
# rather than ever hanging the shortcut.
MAX_VISITS = 4000


def _extents_of(acc):
    """acc's on-screen bounds, or None if it has none / isn't realized."""
    try:
        comp = acc.get_component_iface()
        if not comp:
            return None
        ext = comp.get_extents(Atspi.CoordType.SCREEN)
    except Exception:
        return None
    if ext is None or ext.width <= 0 or ext.height <= 0:
        return None
    return ext


def _text_iface_content(acc):
    try:
        iface = acc.get_text_iface()
        if iface:
            # NOTE: iface.get_text(start, end) throws
            # "takes exactly 1 argument (3 given)" on this GI binding version
            # — get_text is exposed as a static/free function here, not a
            # bound instance method. Confirmed against a live GTK app during
            # development; use the static form or this silently returns
            # nothing for every real text node (it did, for a while).
            s = Atspi.Text.get_text(iface, 0, -1)
            if s and s.strip():
                return s.strip()
    except Exception:
        pass
    return None


def _name_of(acc):
    try:
        name = acc.get_name()
        if name and name.strip():
            return name.strip()
    except Exception:
        pass
    return None


def _find_text_at_point(root, x, y):
    """Walk the whole subtree looking for the smallest (most specific)
    accessible whose on-screen bounds contain (x, y) and that exposes text.

    Deliberately does NOT prune a branch just because a node's own bounds
    don't contain the point: AT-SPI's tree structure follows widget
    hierarchy, not visual containment, so a child's real screen extents can
    fall completely outside its parent's reported bounds. Concretely: a GTK
    notebook's "page tab" accessible reports only the tiny tab-label
    rectangle, while the actual page content (the thing you're actually
    hovering) is a child of that node with much larger, unrelated bounds.
    Pruning there — the natural-looking optimization — silently missed real
    text; confirmed against a live GTK app (mousepad) during development.
    A flat, bounded, unpruned walk is the correct trade-off here.
    """
    best_text, best_text_area = None, None
    best_name, best_name_area = None, None
    stack = [root]
    visited = 0

    while stack:
        acc = stack.pop()
        if acc is None:
            continue
        visited += 1
        if visited > MAX_VISITS:
            break

        ext = _extents_of(acc)
        if ext is not None and ext.x <= x < ext.x + ext.width and ext.y <= y < ext.y + ext.height:
            area = ext.width * ext.height
            t = _text_iface_content(acc)
            if t is not None and (best_text_area is None or area < best_text_area):
                best_text, best_text_area = t, area
            else:
                nm = _name_of(acc)
                if nm is not None and (best_name_area is None or area < best_name_area):
                    best_name, best_name_area = nm, area

        try:
            n = acc.get_child_count()
        except Exception:
            n = 0
        for i in range(n):
            try:
                stack.append(acc.get_child_at_index(i))
            except Exception:
                continue

    # prefer actual text content (a text view, a paragraph) over a mere
    # widget name (a button label) whenever both are present
    return best_text if best_text is not None else best_name


def main():
    # argv: <x> <y> [focused-window-class]
    if len(sys.argv) not in (3, 4):
        return 0
    try:
        x, y = int(sys.argv[1]), int(sys.argv[2])
    except ValueError:
        return 0
    hint = sys.argv[3].strip().lower() if len(sys.argv) == 4 and sys.argv[3].strip() else None

    try:
        desktop = Atspi.get_desktop(0)
        napps = desktop.get_child_count() if desktop else 0
    except Exception:
        return 0

    apps = []
    for i in range(napps):
        try:
            app = desktop.get_child_at_index(i)
        except Exception:
            continue
        if app is not None:
            apps.append(app)

    # AT-SPI exposes no window stacking order, and multiple apps' reported
    # bounds can overlap (an occluded/background window keeps reporting its
    # old geometry). Without knowing which window is actually on top, the
    # wrong (hidden) app can shadow the real one — confirmed against a live
    # desktop during development. lib/hover.sh passes the *actually focused*
    # window's class (from `hyprctl activewindow`) as a hint; check that
    # app's tree first, falling back to a full scan if it has no match
    # (e.g. it isn't AT-SPI-registered at all — common for Electron apps
    # unless they've had accessibility explicitly toggled on).
    if hint:
        def _matches(app):
            try:
                name = (app.get_name() or "").lower()
            except Exception:
                return False
            return bool(name) and (hint in name or name in hint)
        apps.sort(key=lambda a: 0 if _matches(a) else 1)

    for app in apps:
        text = _find_text_at_point(app, x, y)
        if text:
            sys.stdout.write(text)
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
