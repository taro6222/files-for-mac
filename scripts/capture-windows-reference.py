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


def request(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    command = Request(DRIVER + path, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urlopen(command, timeout=12) as response:
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


def capture(output, app_id, window_handle, fixture=None):
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
        result = request("POST", "/session", {"desiredCapabilities": capabilities})
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

            def path_editor():
                try:
                    return element_route("accessibility id", "PART_TextBox")
                except RuntimeError:
                    request("POST", session + "/keys", {"value": ["\ue009", "l", "\ue000"]})
                    return None

            editor = wait_for("the path editor", path_editor)
            request("POST", editor + "/clear", {})
            request("POST", editor + "/value", {"value": list(str(fixture))})
            if request("GET", editor + "/text")["value"] != str(fixture):
                raise RuntimeError("The path editor did not receive the fixture path")
            request("POST", editor + "/value", {"value": ["\ue007"]})

            def folder_source():
                current = element_route("accessibility id", "CurrentPathGet")
                text = request("GET", current + "/text")["value"]
                if text.rstrip("\\").casefold() != str(fixture).rstrip("\\").casefold():
                    return None
                tree = read_tree()
                names = {element.get("Name", "").casefold() for element in tree.iter()}
                if not all(item.name.casefold() in names or (item.is_file() and item.stem.casefold() in names)
                           for item in fixture.iterdir()):
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

            def select_layout(key):
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
                    if len(blades) == 2 and "alpha" in blades[0] and {"column-note.txt", "column-note"} & blades[1]:
                        return tree
                return None

            def capture_layout(tree, identifier, mode):
                base = f"{identifier}_{mode}"
                tree.write(output / f"{base}.xml", encoding="utf-8", xml_declaration=True)
                record.setdefault("layouts", {})[identifier] = {
                    "mode": mode, "screenshotSHA256": screenshot(f"{base}.png"),
                }
                report.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

            select_layout("4")
            capture_layout(wait_for("the fixture grid", grid_source), "UI-04", "grid")
            select_layout("5")
            wait_for("the fixture column browser", columns_source)
            alpha = wait_for("Alpha in the first column", lambda: element_route(
                "xpath", "//*[@AutomationId='ItemName' and @Name='Alpha']"))
            request("POST", alpha + "/click", {})
            if expanded_columns_source() is None:
                request("POST", session + "/keys", {"value": ["\ue007"]})
            tree = wait_for("Alpha and its child in adjacent columns", expanded_columns_source)
            capture_layout(tree, "UI-05", "columns")
    except Exception as error:
        (output / "capture-error.txt").write_text(str(error) + "\n", encoding="utf-8")
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
    arguments = parser.parse_args()
    capture(arguments.output, os.environ["FILES_WINDOWS_APP_ID"], arguments.window_handle, arguments.fixture)
