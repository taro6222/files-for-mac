#!/usr/bin/env python3
"""Capture the pinned Windows Files app through WinAppDriver."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET


DRIVER = "http://127.0.0.1:4723"


def element_bounds(element):
    return tuple(int(element.attrib[key]) for key in ("x", "y", "width", "height"))


def process_is_elevated(pid):
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = (wintypes.HANDLE,)
    kernel32.CloseHandle.restype = wintypes.BOOL
    advapi32.OpenProcessToken.argtypes = (wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE))
    advapi32.OpenProcessToken.restype = wintypes.BOOL
    advapi32.GetTokenInformation.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p,
                                            wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
    advapi32.GetTokenInformation.restype = wintypes.BOOL
    process = kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    token = wintypes.HANDLE()
    try:
        if not advapi32.OpenProcessToken(process, 0x0008, ctypes.byref(token)):  # TOKEN_QUERY
            raise ctypes.WinError(ctypes.get_last_error())
        elevated, size = wintypes.DWORD(), wintypes.DWORD()
        if not advapi32.GetTokenInformation(token, 20, ctypes.byref(elevated),
                                            ctypes.sizeof(elevated), ctypes.byref(size)):  # TokenElevation
            raise ctypes.WinError(ctypes.get_last_error())
        return bool(elevated.value)
    finally:
        if token:
            kernel32.CloseHandle(token)
        kernel32.CloseHandle(process)


def drag_pointer(start, end):
    import ctypes
    from ctypes import wintypes

    class MouseInput(ctypes.Structure):
        _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("data", wintypes.DWORD),
                    ("flags", wintypes.DWORD), ("time", wintypes.DWORD), ("extra", ctypes.c_size_t)]

    class Input(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("mouse", MouseInput)]

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.SetCursorPos.argtypes = (ctypes.c_int, ctypes.c_int)
    user32.SetCursorPos.restype = wintypes.BOOL
    user32.GetCursorPos.argtypes = (ctypes.POINTER(wintypes.POINT),)
    user32.GetCursorPos.restype = wintypes.BOOL
    user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(Input), ctypes.c_int)
    user32.SendInput.restype = wintypes.UINT

    def move(x, y):
        if not user32.SetCursorPos(x, y):
            raise ctypes.WinError(ctypes.get_last_error())

    def button(flags):
        event = Input(mouse=MouseInput(flags=flags))
        if user32.SendInput(1, ctypes.byref(event), ctypes.sizeof(event)) != 1:
            raise RuntimeError("Windows could not inject the drag button event")

    def verify_position(expected):
        position = wintypes.POINT()
        if not user32.GetCursorPos(ctypes.byref(position)):
            raise ctypes.WinError(ctypes.get_last_error())
        actual = (position.x, position.y)
        if actual != expected:
            raise RuntimeError(f"Drag pointer position was {actual}, expected {expected}")

    move(*start)
    time.sleep(0.1)
    verify_position(start)
    print(f"Tab drag starts at {start}; expected drop point {end}", flush=True)
    button(0x0002)  # MOUSEEVENTF_LEFTDOWN
    try:
        for step in range(1, 25):
            fraction = step / 24
            move(*(round(a + (b - a) * fraction) for a, b in zip(start, end)))
            time.sleep(0.025)
        time.sleep(0.3)
        verify_position(end)
        print(f"Tab drag reached {end}", flush=True)
    finally:
        button(0x0004)  # MOUSEEVENTF_LEFTUP


def request(method, path, body=None, *, timeout=12):
    data = None if body is None else json.dumps(body).encode()
    command = Request(DRIVER + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urlopen(command, timeout=timeout) as response:
            payload = response.read()
            result = json.loads(payload) if payload else {}
    except HTTPError as error:
        raise RuntimeError(error.read().decode(errors="replace")) from error
    if result.get("status", 0) != 0:
        raise RuntimeError(str(result.get("value")))
    return result


def wait_for(description, read):
    deadline = time.monotonic() + 35
    last_error = None
    while time.monotonic() < deadline:
        try:
            result = read()
            if result:
                return result
        except (URLError, TimeoutError, RuntimeError) as error:
            last_error = error
        time.sleep(0.5)
    raise RuntimeError(f"Timed out waiting for {description}") from last_error


def advanced_security_matches(tree, expected):
    def short_name(display):
        return display.partition(" (")[0].rsplit("\\", 1)[-1].strip().casefold()

    visible = [element for element in tree.iter() if element.get("IsOffscreen") == "False"]
    owner = next((element.get("Name", "") for element in visible if element.get("AutomationId") == "OwnerText"), "")
    entries = next((element for element in visible if element.get("AutomationId") == "AdvancedPermissionListView"), None)
    if not owner or not expected["owner"] or short_name(owner) != short_name(expected["owner"]) or entries is None:
        return False

    for row in entries.iter("ListItem"):
        if row.get("IsOffscreen") != "False":
            continue
        names = [element.get("Name", "") for element in row.iter() if element.get("IsOffscreen") == "False"]
        principals = {short_name(name) for name in names}
        labels = {name.casefold() for name in names}
        if any(short_name(entry["principal"]) in principals and entry["effect"].casefold() in labels
               and (not entry["fullControl"] or "full control" in labels) for entry in expected["entries"]):
            return True
    return False


def completed_copy_card(tree, destination):
    for listing in tree.iter():
        if listing.get("AutomationId") != "StatusCenterItemsListView" or listing.get("IsOffscreen") != "False":
            continue
        for row in listing.iter("ListItem"):
            if row.get("IsOffscreen") != "False":
                continue
            for element in row.iter():
                name = element.get("Name", "").strip()
                if (element.get("IsOffscreen") == "False" and name.casefold().startswith("copied 1 item to ")
                        and name.casefold().endswith(f'"{destination.casefold()}"')):
                    return name
    return None



def operation_copy_card(tree, destination, *, cancelled=False):
    """Match state and controls on the same visible card, never a completed or hidden sibling."""
    for listing in tree.iter():
        if listing.get("AutomationId") != "StatusCenterItemsListView" or listing.get("IsOffscreen") != "False":
            continue
        for row in listing.iter("ListItem"):
            if row.get("IsOffscreen") != "False":
                continue
            visible = [element for element in row.iter() if element.get("IsOffscreen") == "False"]
            titles = [element.get("Name", "").casefold() for element in visible
                      if element.get("AutomationId") == "StatusCenterItemHeaderTextBlock"]
            controls = {element.get("AutomationId") for element in visible}
            if not any(f'"{destination.casefold()}"' in title for title in titles):
                continue
            if cancelled:
                if (any("cancelled" in title or "canceled" in title for title in titles)
                        and "CloseItemButton" in controls and "MoreOptionsButton" not in controls):
                    return row
            elif (any(title.startswith("copying ") for title in titles) and "MoreOptionsButton" in controls
                  and {"MainProgressBar", "MainGraphCartesianChartClipGrid"} & controls):
                return row
    return None




def editor_has_keyboard_focus(tree, identifier):
    editors = [element for element in tree.iter() if element.get("AutomationId") == identifier
               and element.get("IsOffscreen") == "False"]
    return (len(editors) == 1 and editors[0].get("IsEnabled") == "True"
            and editors[0].get("HasKeyboardFocus") == "True")


def bulk_rename_controls(tree, *, enabled, invalid=False):
    visible = [element for element in tree.iter() if element.get("IsOffscreen") == "False"]
    def unique(identifier):
        matches = [element for element in visible if element.get("AutomationId") == identifier]
        return matches[0] if len(matches) == 1 else None
    editor, primary, cancel = (unique(identifier) for identifier in ("FileNameBox", "PrimaryButton", "SecondaryButton"))
    if editor is None or primary is None or cancel is None:
        return False
    if (primary.get("Name") != "Rename" or cancel.get("Name") != "Cancel"
            or primary.get("IsEnabled") != str(enabled) or cancel.get("IsEnabled") != "True"):
        return False
    warning = any(element.get("Name", "").strip() == "The item name specified is invalid" for element in visible)
    return warning if invalid else not warning


def transfer_fixture_manifest(root):
    """Hash names, types and file bytes, including empty directories; reject unknown locations and links."""
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("The transfer fixture root is unavailable or is a symbolic link")
    entries, files, directories, total_bytes = [], 0, 0, 0
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("A transfer fixture contains an unexpected symbolic link")
        name = path.relative_to(root).as_posix()
        if path.is_dir():
            entries.append((name, "directory", 0, None))
            directories += 1
            continue
        if not path.is_file():
            raise RuntimeError("A transfer fixture contains an unexpected special file")
        data = path.read_bytes()
        entries.append((name, "file", len(data), hashlib.sha256(data).hexdigest()))
        files += 1
        total_bytes += len(data)
    digest = hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()
    return {"files": files, "directories": directories, "bytes": total_bytes, "sha256": digest}


def capture(output, app_id, window_handle, fixture=None, scope="all"):
    output.mkdir(parents=True, exist_ok=True)
    session = None
    last_source = None

    def screenshot(filename):
        png = base64.b64decode(request("GET", session + "/screenshot")["value"], validate=True)
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("WinAppDriver did not return a PNG")
        (output / filename).write_bytes(png)
        return hashlib.sha256(png).hexdigest()

    try:
        wait_for("WinAppDriver", lambda: request("GET", "/status"))
        capabilities = {"appTopLevelWindow": window_handle, "deviceName": "WindowsPC"}
        result = request("POST", "/session", {"desiredCapabilities": capabilities}, timeout=45)
        session_id = result.get("sessionId") or result["value"]["sessionId"]
        session = f"/session/{session_id}"

        def read_tree():
            nonlocal last_source
            last_source = request("GET", session + "/source")["value"]
            return ET.ElementTree(ET.fromstring(last_source))

        def element_route(strategy, value):
            element = request("POST", session + "/element", {"using": strategy, "value": value})["value"]
            identifier = element.get("ELEMENT") or element["element-6066-11e4-a52e-4f735466cecf"]
            return f"{session}/element/{identifier}"

        def home_source():
            for handle in request("GET", session + "/window_handles")["value"]:
                request("POST", session + "/window", {"name": handle})
                tree = read_tree()
                elements = list(tree.iter())
                if any(element.get("Name") == "Disclaimer" for element in elements):
                    request("POST", element_route("name", "Accept") + "/click", {})
                    continue
                names = {element.get("Name", "").casefold() for element in elements}
                if {"drives", "network locations"} <= names:
                    return tree
            return None

        wait_for("Files Home accessibility elements", home_source)
        request("POST", session + "/window/maximize", {})
        tree = wait_for("maximized Files Home", home_source)
        screenshot_sha = screenshot("UI-01_home.png")
        tree.write(output / "UI-01_home.xml", encoding="utf-8", xml_declaration=True)
        record = {
            "upstreamSHA": os.environ["UPSTREAM_SHA"],
            "packageSHA256": os.environ["FILES_WINDOWS_PACKAGE_SHA"],
            "appID": app_id,
            "windows": platform.version(),
            "architecture": platform.machine(),
            "scope": scope,
            "screen": "UI-01 Home, initial runner defaults",
            "screenshotSHA256": screenshot_sha,
        }
        report = output / "capture.json"
        report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
        if fixture is not None:
            fixture = fixture.resolve(strict=True)
            entries = sorted(item.name for item in fixture.iterdir())
            normalized_names = {
                name.casefold() for item in fixture.iterdir()
                for name in ([item.name] if item.is_dir() else [item.name, item.stem])
            }

            def set_editor_text(identifier, value):
                editor = wait_for(f"the {identifier} editor", lambda: element_route("accessibility id", identifier))
                request("POST", editor + "/click", {})

                def focused_editor():
                    tree = read_tree()
                    return editor_has_keyboard_focus(tree, identifier)

                wait_for(f"keyboard focus in {identifier}", focused_editor)
                request("POST", editor + "/clear", {})
                request("POST", editor + "/value", {"value": list(value)})
                actual = request("GET", editor + "/text")["value"]
                if actual != value or not focused_editor():
                    raise RuntimeError(f"The {identifier} editor lost focus or did not receive the requested input: {actual!r}")
                return editor

            def submit_omnibar(key, value):
                request("POST", session + "/keys", {"value": ["\ue009", key, "\ue000"]})
                editor = set_editor_text("PART_TextBox", value)
                request("POST", editor + "/value", {"value": ["\ue007"]})

            def open_path(path):
                submit_omnibar("l", str(path))

            open_path(fixture)

            def has_fixture_items(names):
                return all(item.name.casefold() in names or (item.is_file() and item.stem.casefold() in names)
                           for item in fixture.iterdir())

            def folder_source():
                current = element_route("accessibility id", "CurrentPathGet")
                text = request("GET", current + "/text")["value"]
                if text.rstrip("\\").casefold() != str(fixture).rstrip("\\").casefold():
                    return None
                tree = read_tree()
                names = {element.get("Name", "").casefold() for element in tree.iter()}
                if not has_fixture_items(names):
                    return None
                return tree

            tree = wait_for("the fixture folder and its entries", folder_source)
            columns = sorted({element.get("Name", "") for element in tree.iter()
                              if element.get("Name", "").casefold() in {"name", "date modified", "type", "size"}})
            record["folder"] = {
                "screens": ["UI-02"],
                "entries": entries,
                "visibleEntryNames": sorted({element.get("Name", "") for element in tree.iter()
                                            if element.get("Name", "").casefold() in normalized_names}),
                "detailColumnNames": columns,
                "screenshotSHA256": screenshot("UI-02_folder.png"),
            }
            if {"name", "date modified", "type", "size"} <= {column.casefold() for column in columns}:
                record["folder"]["screens"].append("UI-03")
            tree.write(output / "UI-02_folder.xml", encoding="utf-8", xml_declaration=True)
            report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

            def send_control_shift(key):
                request("POST", session + "/keys", {"value": ["\ue009", "\ue008", key, "\ue000"]})

            def grid_source():
                tree = folder_source()
                if tree is not None and any(element.get("AutomationId") == "GridViewBrowserListedItem"
                                            or element.get("ClassName") == "GridViewItem" for element in tree.iter()):
                    return tree
                return None

            def column_host(tree):
                return next((element for element in tree.iter()
                             if element.get("AutomationId") == "ColumnHost" or element.get("ClassName") == "BladeView"), None)

            def columns_source():
                tree = read_tree()
                host = column_host(tree)
                return tree if host is not None else None

            def expanded_columns_source():
                tree = columns_source()
                if tree is not None:
                    blades = [
                        {element.get("Name", "").casefold() for element in blade.iter()}
                        for blade in column_host(tree) if blade.get("ClassName") == "BladeItem"
                    ]
                    if any({"alpha", "workshop"} <= parent and {"column-note.txt", "column-note"} & child
                           for parent, child in zip(blades, blades[1:])):
                        return tree
                return None

            def capture_layout(tree, identifier, mode):
                base = f"{identifier}_{mode}"
                tree.write(output / f"{base}.xml", encoding="utf-8", xml_declaration=True)
                record.setdefault("layouts", {})[identifier] = {
                    "mode": mode, "screenshotSHA256": screenshot(f"{base}.png"),
                }
                report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

            def split_source(secondary_opened=False, stacked=False):
                tree = read_tree()
                panes = [element for element in tree.iter() if element.get("AutomationId") == "RootGridZoom"
                         and element.get("IsOffscreen") == "False"]
                if len(panes) != 2:
                    return None
                try:
                    first, second = map(element_bounds, panes)
                except (KeyError, ValueError):
                    return None
                if stacked:
                    arranged = first[1] + first[3] <= second[1] + 1 and abs(first[0] - second[0]) <= 1
                else:
                    arranged = first[0] + first[2] <= second[0] + 1 and abs(first[1] - second[1]) <= 1
                if not arranged:
                    return None
                names = [{element.get("Name", "").casefold() for element in pane.iter()} for pane in panes]
                right_matches = ({"column-note.txt", "column-note"} & names[1]) if secondary_opened else has_fixture_items(names[1])
                return tree if has_fixture_items(names[0]) and right_matches else None

            def visible_tabs(tree):
                return [tab for tab in tree.iter("TabItem") if tab.get("IsOffscreen") == "False"]

            def verify_tab_selection(tree, active):
                if tree is None:
                    return None
                tabs = visible_tabs(tree)
                names = [tab.get("Name") for tab in tabs]
                selected = [tab.get("Name") for tab in tabs if tab.get("IsSelected") == "True"]
                return tree if names == [fixture.name, "Alpha"] and selected == [active] else None

            def capture_tab_drop():
                request("POST", session + "/keys", {"value": ["\ue009", "t", "\ue000"]})
                wait_for("the second tab", lambda: len(visible_tabs(read_tree())) == 2)
                open_path(fixture / "Alpha")
                wait_for("the two tabs with Alpha selected", lambda: verify_tab_selection(read_tree(), "Alpha"))
                # Files binds Ctrl+Shift+Tab to its Previous Tab command.
                request("POST", session + "/keys", {"value": ["\ue009", "\ue008", "\ue004", "\ue000"]})
                tree = wait_for("the first tab selected at the fixture", lambda: verify_tab_selection(folder_source(), fixture.name))
                alpha_tab = next(tab for tab in visible_tabs(tree) if tab.get("Name") == "Alpha")
                pane = next(element for element in tree.iter() if element.get("AutomationId") == "RootGridZoom"
                            and element.get("IsOffscreen") == "False")
                tx, ty, tw, th = element_bounds(alpha_tab)
                px, py, pw, ph = element_bounds(pane)
                if min(tw, th, pw, ph) <= 0:
                    raise RuntimeError("The tab or the drop target does not have a visible rectangle")
                app_pid = int(alpha_tab.attrib["ProcessId"])
                app_elevated = process_is_elevated(app_pid)
                runner_elevated = process_is_elevated(os.getpid())
                print(f"Tab drag process elevation: Files={app_elevated}, driver script={runner_elevated}", flush=True)
                if app_elevated:
                    raise RuntimeError("Files disables tab drag and drop when it runs as administrator")
                drag_pointer((tx + tw // 2, ty + th // 2), (px + round(pw * 0.9), py + ph // 2))

                def tab_drop_source():
                    tree = split_source(secondary_opened=True)
                    return tree if tree is not None and len(visible_tabs(tree)) == 1 else None

                tree = wait_for("tab drop into the right pane with the source tab closed", tab_drop_source)
                capture_layout(tree, "UI-06-tab-drop", "dual-pane")

            if scope == "tab-drop":
                capture_tab_drop()
                return

            def select_file(file):
                row = wait_for(f"the visible row for {file.name}", lambda: element_route(
                    "xpath", f"//*[@AutomationId='ItemName' and (@Name='{file.name}' or @Name='{file.stem}') and @IsOffscreen='False']"))
                request("POST", row + "/click", {})

            if scope == "rename":
                before = transfer_fixture_manifest(fixture)
                select_file(fixture / "preview.txt")
                request("POST", session + "/keys", {"value": ["\ue009", "a", "\ue000"]})
                tree = read_tree()
                selected_names = {element.get("Name", "") for row in tree.iter() if row.get("IsSelected") == "True"
                                  for element in row.iter() if element.get("AutomationId") == "ItemName"
                                  and element.get("Name", "").casefold() in normalized_names}
                if len(selected_names) < 2:
                    raise RuntimeError("Bulk rename requires multiple visibly selected fixture entries")
                record["bulkRename"] = {"state": "selected", "selectedNames": sorted(selected_names), "sourceBefore": before}
                report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
                request("POST", session + "/keys", {"value": ["\ue032"]})  # F2 on multiple selected items

                def rename_source(enabled, invalid=False):
                    tree = read_tree()
                    return tree if bulk_rename_controls(tree, enabled=enabled, invalid=invalid) else None

                tree = wait_for("the empty bulk rename dialog with Rename disabled", lambda: rename_source(False))
                capture_layout(tree, "UI-12-empty", "bulk-rename")

                def set_name(name):
                    set_editor_text("FileNameBox", name)

                set_name("invalid/name")
                tree = wait_for("the invalid name warning with Rename disabled", lambda: rename_source(False, True))
                capture_layout(tree, "UI-12-invalid", "bulk-rename")
                if transfer_fixture_manifest(fixture) != before:
                    raise RuntimeError("An invalid rename input changed the fixture")
                set_name("RenamedReference")
                tree = wait_for("a valid bulk name with Rename enabled", lambda: rename_source(True))
                capture_layout(tree, "UI-12-valid", "bulk-rename")
                if transfer_fixture_manifest(fixture) != before:
                    raise RuntimeError("Editing the valid name changed files before confirmation")
                request("POST", element_route("accessibility id", "SecondaryButton") + "/click", {})

                def returned_source():
                    tree = folder_source()
                    return tree if tree is not None and not any(element.get("AutomationId") == "FileNameBox"
                        and element.get("IsOffscreen") == "False" for element in tree.iter()) else None

                tree = wait_for("the unchanged folder after cancelling bulk rename", returned_source)
                after = transfer_fixture_manifest(fixture)
                if after != before:
                    raise RuntimeError("Cancelling bulk rename changed file names or contents")
                capture_layout(tree, "UI-12-cancelled", "bulk-rename")
                record["bulkRename"].update(state="cancelled-without-mutation", sourceAfter=after,
                    emptyNameDisabled=True, invalidNameDisabled=True, invalidNameWarning=True,
                    validNameEnabled=True, sourcePreserved=True)
                report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
                return

            if scope == "operation-progress":
                source = fixture / "TransferCancellation"
                destination = fixture / "Workshop"
                copied = destination / source.name
                if source.exists() or copied.exists():
                    raise RuntimeError("Refusing to reuse a transfer cancellation fixture")
                source.mkdir()
                for index in range(24000):
                    (source / f"item-{index:05d}.bin").write_bytes(index.to_bytes(4, "little") * 256)
                before = transfer_fixture_manifest(source)
                record["activeCopy"] = {"state": "prepared", "source": before, "destination": destination.name}
                report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
                select_file(source)
                request("POST", session + "/keys", {"value": ["\ue009", "c", "\ue000"]})
                # Navigate through the visible folder row while preserving the file clipboard.
                select_file(destination)
                request("POST", session + "/keys", {"value": ["\ue007"]})

                def at_destination():
                    route = element_route("accessibility id", "CurrentPathGet")
                    return request("GET", route + "/text")["value"].rstrip("\\").casefold() == str(destination).rstrip("\\").casefold()

                wait_for("the active copy destination", at_destination)
                request("POST", session + "/keys", {"value": ["\ue009", "v", "\ue000"]})
                button = wait_for("the Status Center button", lambda: element_route(
                    "xpath", "//Button[@AutomationId='ShowStatusCenterButton' and @IsOffscreen='False']"))
                request("POST", button + "/click", {})

                def active_source():
                    tree = read_tree()
                    card = operation_copy_card(tree, destination.name)
                    count = len(list(copied.glob("*.bin"))) if copied.exists() else 0
                    return (tree, card, count) if card is not None and 0 < count < before["files"] else None

                tree, card, count = wait_for("a copying card with partial data and a cancel control", active_source)
                record["activeCopy"].update(state="observed-active", copiedFilesBeforeCancel=count,
                    visibleControls=[dict(element.attrib) for element in card.iter() if element.get("IsOffscreen") == "False"])
                capture_layout(tree, "UI-10-copy-active", "status-center")
                button = element_route("xpath", "//Button[@AutomationId='MoreOptionsButton' and @IsOffscreen='False']")
                request("POST", button + "/click", {})
                tree = read_tree()
                capture_layout(tree, "UI-10-copy-cancel-menu", "status-center")
                button = wait_for("the enabled cancel command", lambda: element_route(
                    "xpath", "//*[@AutomationId='CancelItemButton' and @IsEnabled='True' and @IsOffscreen='False']"))
                cancel_started = time.monotonic()
                request("POST", button + "/click", {})

                def cancelled_source():
                    tree = read_tree()
                    return tree if operation_copy_card(tree, destination.name, cancelled=True) is not None else None

                tree = wait_for("the terminal cancelled copy card", cancelled_source)
                record["activeCopy"]["cancelToTerminalSeconds"] = time.monotonic() - cancel_started
                capture_layout(tree, "UI-10-copy-cancelled", "status-center")
                after = transfer_fixture_manifest(source)
                if after != before:
                    raise RuntimeError("Cancelling the copy changed the source manifest")
                if not copied.is_dir():
                    raise RuntimeError("No partial destination remains to verify the cancellation")
                partial = transfer_fixture_manifest(copied)
                if not 0 < partial["files"] < before["files"]:
                    raise RuntimeError("The copy did not stop before completing all files")
                for _ in range(3):
                    time.sleep(.5)
                    if transfer_fixture_manifest(copied) != partial:
                        raise RuntimeError("The destination continued changing after the cancelled terminal card")
                record["activeCopy"].update(state="cancelled", sourceAfter=after, partialDestination=partial,
                                             sourcePreserved=True, destinationStable=True)
                report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
                return

            if scope == "operation-center":
                source = fixture / "preview.txt"
                destination = fixture / "Workshop"
                copied = destination / source.name
                payload_hash = hashlib.sha256(source.read_bytes()).hexdigest()
                if copied.exists():
                    raise RuntimeError("The copy destination is not empty")
                select_file(source)
                request("POST", session + "/keys", {"value": ["\ue009", "c", "\ue000"]})
                # Navigate through the visible folder row while preserving the file clipboard.
                select_file(destination)
                request("POST", session + "/keys", {"value": ["\ue007"]})

                def is_at_destination():
                    route = element_route("accessibility id", "CurrentPathGet")
                    current = request("GET", route + "/text")["value"]
                    return current.rstrip("\\").casefold() == str(destination).rstrip("\\").casefold()

                wait_for("the copy destination folder", is_at_destination)
                request("POST", session + "/keys", {"value": ["\ue009", "v", "\ue000"]})
                wait_for("the copied fixture bytes", lambda: copied.is_file() and
                         hashlib.sha256(copied.read_bytes()).hexdigest() == payload_hash)
                button = wait_for("the Status Center button", lambda: element_route(
                    "xpath", "//Button[@AutomationId='ShowStatusCenterButton' and @IsOffscreen='False']"))
                request("POST", button + "/click", {})

                def completed_card_source():
                    tree = read_tree()
                    card = completed_copy_card(tree, destination.name)
                    return (tree, card) if card else None

                tree, card = wait_for("the completed copy in Status Center", completed_card_source)
                record["completedCopy"] = {"destination": destination.name, "cardTitle": card,
                                           "copiedSHA256": payload_hash}
                capture_layout(tree, "UI-10-copy-complete", "status-center")
                button = element_route("xpath", "//Button[@AutomationId='CloseAllItemsButton' and @IsEnabled='True' and @IsOffscreen='False']")
                request("POST", button + "/click", {})

                def cleared_source():
                    tree = read_tree()
                    buttons = [element for element in tree.iter() if element.get("AutomationId") == "CloseAllItemsButton"
                               and element.get("IsOffscreen") == "False"]
                    if any(element.get("IsEnabled") == "False" for element in buttons) and not completed_copy_card(tree, destination.name):
                        return tree
                    return None

                tree = wait_for("the cleared Status Center", cleared_source)
                if any(hashlib.sha256(file.read_bytes()).hexdigest() != payload_hash for file in (source, copied)):
                    raise RuntimeError("Clearing a completed copy changed the fixture bytes")
                capture_layout(tree, "UI-10-cleared", "status-center")
                return

            def open_properties(file):
                select_file(file)
                button = wait_for("the enabled Properties button", lambda: element_route(
                    "xpath", "//Button[@AutomationId='InnerNavigationToolbarPropertiesButton' and @IsEnabled='True' and @IsOffscreen='False']"))
                request("POST", button + "/click", {})

                def general_properties_source():
                    for handle in request("GET", session + "/window_handles")["value"]:
                        request("POST", session + "/window", {"name": handle})
                        tree = read_tree()
                        visible = [item for item in tree.iter() if item.get("IsOffscreen") == "False"]
                        title = any(item.get("AutomationId") == "TitlebarFileNameTextBlock"
                                    and item.get("Name") == "Properties" for item in visible)
                        if not title or not any(item.get("AutomationId") == "ItemFileName" for item in visible):
                            continue
                        name_field = element_route("accessibility id", "ItemFileName")
                        name = request("GET", name_field + "/text")["value"]
                        if name in {file.name, file.stem}:
                            return tree
                    return None

                return wait_for(f"the Properties window for {file.name}", general_properties_source)

            def click_properties_item(name):
                item = wait_for(f"the visible {name} control", lambda: element_route(
                    "xpath", f"//*[@Name='{name}' and @IsOffscreen='False']"))
                request("POST", item + "/click", {})

            if scope in {"security", "advanced-security"}:
                browser_handle = request("GET", session + "/window_handle")["value"]
                open_properties(fixture / "preview.txt")
                click_properties_item("Security")

                def security_source():
                    tree = read_tree()
                    visible = {item.get("Name") for item in tree.iter() if item.get("IsOffscreen") == "False"}
                    return tree if {"Group or user names", "Advanced permissions"} <= visible else None

                capture_layout(wait_for("the Properties access-control list", security_source), "UI-09-security", "properties")
                if scope == "advanced-security":
                    expected = json.loads((output / "acl-reference.json").read_text(encoding="utf-8-sig"))
                    advanced = wait_for("the enabled advanced permissions button", lambda: element_route(
                        "xpath", "//*[@AutomationId='OpenSecurityAdvancedPageButton' and @IsEnabled='True' and @IsOffscreen='False']"))
                    request("POST", advanced + "/click", {})

                    def advanced_security_source():
                        tree = read_tree()
                        return tree if advanced_security_matches(tree, expected) else None

                    capture_layout(wait_for("the expected owner and permission entry", advanced_security_source),
                                   "UI-09-advanced-security", "properties")
                    return
                click_properties_item("Cancel")
                request("POST", session + "/window", {"name": browser_handle})
                signed = json.loads((output / "signed-reference.json").read_text(encoding="utf-8-sig"))
                sample = fixture / "signature-sample.exe"
                if (not signed["signer"] or signed["name"] != sample.name
                        or hashlib.sha256(sample.read_bytes()).hexdigest() != signed["sha256"]):
                    raise RuntimeError("The signed Properties fixture did not match its recorded hash")
                open_properties(sample)
                click_properties_item("Signatures")

                def signatures_source():
                    tree = read_tree()
                    match = any(item.get("AutomationId") == "DigitalSignatureIssuedToValue"
                                and item.get("IsOffscreen") == "False"
                                and item.get("Name", "").casefold() == signed["signer"].casefold()
                                for item in tree.iter())
                    return tree if match else None

                capture_layout(wait_for("the Properties signer from the runner fixture", signatures_source),
                               "UI-09-signatures", "properties")
                return

            if scope == "properties":
                file = fixture / "preview.txt"
                tree = open_properties(file)
                capture_layout(tree, "UI-09-general", "properties")
                click_properties_item("Hashes")
                expected = hashlib.sha256(file.read_bytes()).hexdigest()

                def hashes_source():
                    tree = read_tree()
                    visible = [item for item in tree.iter() if item.get("IsOffscreen") == "False"]
                    if any(item.get("AutomationId") == "HashValueText" and item.get("Name", "").casefold() == expected
                           for item in visible):
                        return tree
                    return None

                tree = wait_for("the fixture SHA-256 in the Properties window", hashes_source)
                capture_layout(tree, "UI-09-hashes", "properties")
                return

            def info_pane_source(name, expected_text):
                tree = read_tree()
                for panel in tree.iter():
                    if panel.get("Name") != name or panel.get("IsOffscreen") != "False":
                        continue
                    texts = {element.get("Name", "").strip() for element in panel.iter()
                             if element.get("IsOffscreen") == "False"}
                    if expected_text in texts:
                        return tree
                return None

            preview_file = fixture / "preview.txt"
            preview_row = wait_for("the preview fixture row", lambda: element_route(
                "xpath", "//*[@AutomationId='ItemName' and @Name='preview.txt' and @IsOffscreen='False']"))
            request("POST", preview_row + "/click", {})
            info_button = "//Button[@AutomationId='PreviewPane' and @IsOffscreen='False']"
            request("POST", element_route("xpath", info_button) + "/click", {})
            for tab, panel_name, expected_text in (
                ("Details", "File details", preview_file.name),
                ("Preview", "File preview", preview_file.read_text(encoding="utf-8").strip()),
            ):
                tab_button = wait_for(f"the {tab} tab in the info pane", lambda: element_route(
                    "xpath", f"//RadioButton[@Name='{tab}' and @IsOffscreen='False']"))
                request("POST", tab_button + "/click", {})
                tree = wait_for(f"{panel_name} showing the selected fixture", lambda: info_pane_source(panel_name, expected_text))
                capture_layout(tree, f"UI-08-{tab.lower()}", "info-pane")
            request("POST", element_route("xpath", info_button) + "/click", {})

            send_control_shift("4")
            capture_layout(wait_for("the fixture grid", grid_source), "UI-04", "grid")
            send_control_shift("5")
            wait_for("the fixture column browser", columns_source)

            def click_column_alpha():
                if expanded_columns_source() is not None:
                    return True
                alpha = element_route("xpath", "//*[@AutomationId='ColumnHost']"
                                      "//*[@AutomationId='ItemName' and @Name='Alpha' and @IsOffscreen='False']")
                request("POST", alpha + "/click", {})
                return True

            wait_for("a successful click on visible Alpha in the column browser", click_column_alpha)
            if expanded_columns_source() is None:
                request("POST", session + "/keys", {"value": ["\ue007"]})
            tree = wait_for("Alpha and its child in adjacent columns", expanded_columns_source)
            capture_layout(tree, "UI-05", "columns")

            send_control_shift("1")
            open_path(fixture)
            wait_for("the fixture in Details before splitting", folder_source)
            send_control_shift("s")
            wait_for("two panes with the fixture folder", split_source)
            def open_alpha_in_secondary():
                alpha = wait_for("Alpha in the second pane", lambda: element_route(
                    "xpath", "(//*[@AutomationId='RootGridZoom' and @IsOffscreen='False'])[2]"
                             "//*[@AutomationId='ItemName' and @Name='Alpha']"))
                request("POST", alpha + "/click", {})
                request("POST", session + "/keys", {"value": ["\ue007"]})

            open_alpha_in_secondary()
            tree = wait_for("left fixture and right Alpha folder", lambda: split_source(secondary_opened=True))
            capture_layout(tree, "UI-06", "dual-pane")

            def search_source():
                tree = read_tree()
                visible = [element for element in tree.iter() if element.get("IsOffscreen") == "False"]
                heading = any(element.get("Name", "").startswith("Search results for")
                              and "column-note" in element.get("Name", "") for element in visible)
                names = [element.get("Name", "").casefold() for element in visible
                         if element.get("AutomationId") == "ItemName"]
                paths = [element.get("Name", "").casefold() for element in visible
                         if element.get("AutomationId") == "ItemPathTextBlock"]
                expected_path = str(fixture / "Alpha" / "column-note.txt").casefold()
                if heading and names in (["column-note.txt"], ["column-note"]) and paths == [expected_path]:
                    return tree
                return None

            send_control_shift("s")
            open_path(fixture)
            wait_for("the fixture before search", folder_source)
            submit_omnibar("f", "column-note")
            tree = wait_for("the single matching file in a child folder", search_source)
            capture_layout(tree, "UI-07", "search")

            back = wait_for("the search page's Back button", lambda: element_route(
                "xpath", "//Button[@AutomationId='Back' and @IsEnabled='True' and @IsOffscreen='False']"))
            request("POST", back + "/click", {})
            wait_for("the first tab back at the fixture", folder_source)
            capture_tab_drop()

            send_control_shift("s")
            open_path(fixture)
            wait_for("the fixture before top and bottom split", folder_source)
            request("POST", session + "/keys", {"value": ["\ue00a", "\ue008", "h", "\ue000"]})
            wait_for("two stacked panes with the fixture folder", lambda: split_source(stacked=True))
            open_alpha_in_secondary()
            tree = wait_for("top fixture and bottom Alpha folder", lambda: split_source(secondary_opened=True, stacked=True))
            capture_layout(tree, "UI-06-stacked", "dual-pane")
    except Exception as error:
        (output / "capture-error.txt").write_text(str(error) + "\n", encoding="utf-8")
        diagnostic = {"sourceRefreshedAfterFailure": False, "sourceAttemptUnixSeconds": time.time()}
        if session is not None:
            try:
                refreshed = request("GET", session + "/source")["value"]
                if not isinstance(refreshed, str):
                    raise ValueError("Expected an XML source string")
                last_source = refreshed
                diagnostic["sourceRefreshedAfterFailure"] = True
            except (URLError, TimeoutError, RuntimeError, ValueError, KeyError) as diagnostic_error:
                diagnostic["sourceRefreshError"] = str(diagnostic_error)
        (output / "failure-diagnostics.json").write_text(json.dumps(diagnostic, indent=2) + "\n", encoding="utf-8")
        if last_source is not None:
            try:
                ET.ElementTree(ET.fromstring(last_source)).write(
                    output / "last-window.xml", encoding="utf-8", xml_declaration=True
                )
            except ET.ParseError:
                (output / "last-window.txt").write_text(last_source, encoding="utf-8")
        if session is not None:
            try:
                screenshot("last-window.png")
            except (URLError, TimeoutError, RuntimeError, ValueError) as diagnostic_error:
                print(f"WinAppDriver error screenshot unavailable: {diagnostic_error}")
        raise
    finally:
        if session is not None:
            try:
                request("DELETE", session)
            except (URLError, TimeoutError, RuntimeError) as error:
                print(f"WinAppDriver session cleanup failed: {error}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--window-handle", required=True)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--scope", choices=("all", "tab-drop", "properties", "security", "advanced-security",
                                            "operation-center", "operation-progress", "rename"), default="all")
    arguments = parser.parse_args()
    if arguments.scope != "all" and arguments.fixture is None:
        parser.error("a specific --scope requires --fixture")
    capture(arguments.output, os.environ["FILES_WINDOWS_APP_ID"], arguments.window_handle, arguments.fixture, arguments.scope)
