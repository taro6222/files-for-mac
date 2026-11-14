#!/usr/bin/env python3
"""Capture the pinned Windows Files Home page through WinAppDriver."""

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


def capture(output, app_id):
    wait_for("WinAppDriver", lambda: request("GET", "/status"))
    result = request("POST", "/session", {"desiredCapabilities": {"app": app_id, "deviceName": "WindowsPC"}})
    session_id = result.get("sessionId") or result["value"]["sessionId"]
    session = f"/session/{session_id}"
    output.mkdir(parents=True, exist_ok=True)
    last_source = None

    def screenshot(filename):
        png = base64.b64decode(request("GET", session + "/screenshot")["value"], validate=True)
        if not png.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("WinAppDriver did not return a PNG")
        (output / filename).write_bytes(png)
        return hashlib.sha256(png).hexdigest()

    try:
        def home_source():
            nonlocal last_source
            for handle in request("GET", session + "/window_handles")["value"]:
                request("POST", session + "/window", {"name": handle})
                xml = request("GET", session + "/source")["value"]
                last_source = xml
                elements = list(ET.fromstring(xml).iter())
                if any(element.get("Name") == "Disclaimer" for element in elements):
                    button = request("POST", session + "/element", {"using": "name", "value": "Accept"})["value"]
                    identifier = button.get("ELEMENT") or button["element-6066-11e4-a52e-4f735466cecf"]
                    request("POST", f"{session}/element/{identifier}/click", {})
                    continue
                names = {element.get("Name", "").casefold() for element in elements}
                if {"drives", "network locations"} <= names:
                    return xml
            return None

        wait_for("Files Home accessibility elements", home_source)
        request("POST", session + "/window/maximize", {})
        xml = wait_for("maximized Files Home", home_source)
        screenshot_sha = screenshot("UI-01_home.png")
        (output / "UI-01_home.xml").write_text(xml, encoding="utf-8")
        record = {
            "upstreamSHA": os.environ["UPSTREAM_SHA"],
            "packageSHA256": os.environ["FILES_WINDOWS_PACKAGE_SHA"],
            "appID": app_id,
            "windows": platform.version(),
            "architecture": platform.machine(),
            "screen": "UI-01 Home, initial runner defaults",
            "screenshotSHA256": screenshot_sha,
        }
        (output / "capture.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    except Exception as error:
        (output / "capture-error.txt").write_text(str(error) + "\n", encoding="utf-8")
        if last_source is not None:
            (output / "last-window.xml").write_text(last_source, encoding="utf-8")
        try:
            screenshot("last-window.png")
        except (URLError, TimeoutError, RuntimeError, ValueError) as diagnostic_error:
            print(f"WinAppDriver error screenshot unavailable: {diagnostic_error}")
        raise
    finally:
        try:
            request("DELETE", session)
        except (URLError, TimeoutError, RuntimeError) as error:
            print(f"WinAppDriver session cleanup failed: {error}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()
    capture(arguments.output, os.environ["FILES_WINDOWS_APP_ID"])
