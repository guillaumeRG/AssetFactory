"""Blender smoke test for AssetFactory's vendored StableGen integration.

Run by ``setup-asset-factory.ps1 multiview doctor`` with an isolated
BLENDER_USER_SCRIPTS directory containing the vendored add-on.
"""
from __future__ import annotations

import importlib
import traceback

import addon_utils  # type: ignore
import bpy  # type: ignore


def main() -> None:
    enable_errors: list[BaseException] = []

    def capture_error(exc: BaseException) -> None:
        enable_errors.append(exc)
        traceback.print_exception(type(exc), exc, exc.__traceback__)

    module = addon_utils.enable(
        "stablegen",
        default_set=True,
        persistent=False,
        handle_error=capture_error,
    )
    if module is None:
        if enable_errors:
            raise RuntimeError(
                "StableGen activation failed: " + repr(enable_errors[-1])
            ) from enable_errors[-1]
        raise RuntimeError(
            "StableGen activation failed: addon_utils.enable() returned None."
        )

    package = str(module.__name__)
    core = importlib.import_module(f"{package}.core")
    getter = getattr(core, "get_addon_prefs", None)
    prefs = getter() if callable(getter) else None
    if prefs is None:
        addon_pkg = str(getattr(core, "ADDON_PKG", package))
        wrapper = bpy.context.preferences.addons.get(addon_pkg)
        prefs = wrapper.preferences if wrapper is not None else None
    if prefs is None:
        raise RuntimeError(
            f"StableGen enabled as {package!r}, but its preferences are unavailable."
        )

    print(
        "[AF/MULTIVIEW/SMOKE] OK "
        f"package={package} preferences={type(prefs).__name__}",
        flush=True,
    )


if __name__ == "__main__":
    main()
