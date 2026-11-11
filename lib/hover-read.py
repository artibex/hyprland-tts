#!/usr/bin/env python3
"""Print whatever text AT-SPI exposes at a given screen coordinate.

Usage: hover-read.py <x> <y> [focused-window-class]

Internal helper for `hyprland-tts hover` (see lib/hover.sh for the scope notes). Best-effort
accessibility integration: it only finds anything in apps that implement AT-SPI (GTK/Qt/Electron
apps, most browsers). It is silent (no output, exit 0) whenever AT-SPI is unavailable or nothing
is found at the point; the caller treats empty output as "nothing to speak".
"""
import sys  # Command line and output stream.

# AT-SPI is optional: without the GI binding the helper stays silent instead of failing.
try:
    import gi
    gi.require_version("Atspi", "2.0")
    from gi.repository import Atspi
except Exception:  # noqa: BLE001 - any import problem simply means "no AT-SPI here"
    sys.exit(0)


# Node budget for pathological trees (a browser tab exposes tens of thousands of nodes); the
# caller's wall-clock timeout is the second guard, so a huge tree degrades to "nothing found".
MAX_VISITS = 4000


def _extents_of(accessible):
    """Return the on-screen bounds of an accessible.

    Args:
        accessible: An AT-SPI accessible object.

    Returns:
        The extents, or None when it has none or is not realized.
    """
    # Any binding error means "no usable geometry" for this node.
    try:
        component = accessible.get_component_iface()
        if not component:
            return None
        # Screen coordinates match the pointer position the caller passes in.
        extents = component.get_extents(Atspi.CoordType.SCREEN)
    except Exception:  # noqa: BLE001 - GI raises many exception types
        return None
    # Zero-sized nodes cannot contain a point.
    if extents is None or extents.width <= 0 or extents.height <= 0:
        return None
    return extents


def _text_iface_content(accessible):
    """Return the text content of an accessible.

    Args:
        accessible: An AT-SPI accessible object.

    Returns:
        The stripped text, or None when there is none.
    """
    try:
        iface = accessible.get_text_iface()
        if iface:
            # iface.get_text(start, end) fails with "takes exactly 1 argument (3 given)" on this
            # GI binding; the static form works (confirmed against a live GTK app, Agent.md §5).
            content = Atspi.Text.get_text(iface, 0, -1)
            if content and content.strip():
                return content.strip()
    except Exception:  # noqa: BLE001 - a failing text node simply contributes nothing
        pass
    return None


def _name_of(accessible):
    """Return the accessible name (a button label, for example).

    Args:
        accessible: An AT-SPI accessible object.

    Returns:
        The stripped name, or None when there is none.
    """
    try:
        name = accessible.get_name()
        if name and name.strip():
            return name.strip()
    except Exception:  # noqa: BLE001 - a failing node simply has no name
        pass
    return None


def _contains_point(extents, x, y):
    """Tell whether screen bounds contain a point.

    Args:
        extents: Bounds with x, y, width and height.
        x: Screen x coordinate.
        y: Screen y coordinate.

    Returns:
        True when the point lies inside the bounds.
    """
    # Half-open intervals: the right and bottom edges belong to the neighbour.
    inside_x = extents.x <= x < extents.x + extents.width
    inside_y = extents.y <= y < extents.y + extents.height
    return inside_x and inside_y


def _child_nodes(accessible):
    """List the children of an accessible, skipping the ones that cannot be read.

    Args:
        accessible: An AT-SPI accessible object.

    Returns:
        A list of child accessibles.
    """
    try:
        count = accessible.get_child_count()
    except Exception:  # noqa: BLE001 - a broken node has no children
        count = 0
    children = []
    for index in range(count):
        # One unreadable child must not hide its siblings.
        try:
            children.append(accessible.get_child_at_index(index))
        except Exception:  # noqa: BLE001
            continue
    return children


def _better(candidate, area, best, best_area):
    """Tell whether a candidate beats the best one so far (smaller area wins).

    Args:
        candidate: The new value (text or name).
        area: Screen area of the candidate's node.
        best: Best value so far, or None.
        best_area: Area of the best value, or None.

    Returns:
        True when the candidate exists and is more specific than the best.
    """
    # The smallest enclosing node is the most specific one.
    return candidate is not None and (best_area is None or area < best_area)


def _find_text_at_point(root, x, y):
    """Walk the whole subtree and pick the most specific text at a point.

    The walk deliberately does NOT prune a branch whose own bounds miss the point: AT-SPI's
    tree follows widget hierarchy, not visual containment (a GTK notebook tab reports only the
    tab label's rectangle while its page content is a child with much larger bounds).
    Pruning there silently missed real text (Agent.md §5). A flat, bounded walk is correct.

    Args:
        root: The accessible to start from (an application).
        x: Screen x coordinate.
        y: Screen y coordinate.

    Returns:
        The smallest enclosing text, else the smallest enclosing name, else None.
    """
    best_text, best_text_area = None, None
    best_name, best_name_area = None, None
    stack = [root]
    # The counter keeps the walk within the MAX_VISITS budget.
    visited = 0
    while stack:
        node = stack.pop()
        if node is None:
            continue
        # The visit budget bounds the work on huge trees.
        visited += 1
        if visited > MAX_VISITS:
            break
        extents = _extents_of(node)
        if extents is not None and _contains_point(extents, x, y):
            area = extents.width * extents.height
            content = _text_iface_content(node)
            # A text that loses to a smaller one still lets the node compete as a plain name.
            if _better(content, area, best_text, best_text_area):
                best_text, best_text_area = content, area
            else:
                name = _name_of(node)
                if _better(name, area, best_name, best_name_area):
                    # The smallest named node seen so far wins.
                    best_name, best_name_area = name, area
        stack.extend(_child_nodes(node))
    # Real text content (a paragraph) beats a mere widget name (a button label).
    return best_text if best_text is not None else best_name


def _parse_arguments(argv):
    """Parse the command line.

    Args:
        argv: Arguments after the program name: x, y and an optional window class.

    Returns:
        Tuple (x, y, hint) with the hint lowercased (None when absent), or None when invalid.
    """
    # Two or three arguments are valid; anything else ends silently.
    if len(argv) not in (2, 3):
        return None
    try:
        x, y = int(argv[0]), int(argv[1])
    except ValueError:
        # Non-numeric coordinates end silently.
        return None
    hint = argv[2].strip().lower() if len(argv) == 3 and argv[2].strip() else None
    return x, y, hint


def _desktop_applications():
    """List the applications registered with AT-SPI.

    Returns:
        A list of application accessibles (empty when AT-SPI does not answer).
    """
    try:
        desktop = Atspi.get_desktop(0)
        count = desktop.get_child_count() if desktop else 0
    except Exception:  # noqa: BLE001 - no registry means nothing to read
        return []
    applications = []
    for index in range(count):
        # An application that vanished while listing is skipped.
        try:
            application = desktop.get_child_at_index(index)
        except Exception:  # noqa: BLE001
            continue
        if application is not None:
            applications.append(application)
    return applications


def _matches_hint(application, hint):
    """Tell whether an application's name matches the focused window's class.

    Args:
        application: An application accessible.
        hint: Lowercase window class.

    Returns:
        True when one name contains the other.
    """
    try:
        name = (application.get_name() or "").lower()
    except Exception:  # noqa: BLE001 - an unreadable name never matches
        return False
    return bool(name) and (hint in name or name in hint)


def main(argv):
    """Print the text under a screen point.

    AT-SPI has no window stacking order and occluded windows keep their old geometry, so the
    focused window's class (passed by lib/hover.sh) is checked first; a full scan follows when
    that app is not AT-SPI-registered (common for Electron apps).

    Args:
        argv: Arguments after the program name.

    Returns:
        Always 0: the caller treats empty output as "nothing found".
    """
    parsed = _parse_arguments(argv)
    if parsed is None:
        return 0
    # The pointer position and the optional focused-window class.
    x, y, hint = parsed
    applications = _desktop_applications()
    # The focused app's tree is searched first (stable sort keeps the rest in order).
    if hint:
        applications.sort(key=lambda app: 0 if _matches_hint(app, hint) else 1)
    for application in applications:
        text = _find_text_at_point(application, x, y)
        # The first application with text at the point answers.
        if text:
            sys.stdout.write(text)
            return 0
    # Nothing found anywhere: silent success is the contract.
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
