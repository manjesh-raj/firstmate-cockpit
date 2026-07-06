"""py2app build config for Firstmate.app.

Build:  .venv/bin/python setup.py py2app
Dev:    .venv/bin/python setup.py py2app -A   (alias mode - fast, runs from source)

Produces dist/Firstmate.app.
"""

from setuptools import setup

APP = ["desktop.py"]

OPTIONS = {
    "argv_emulation": False,
    # Only force-include packages that carry non-.py data we need unzipped:
    #   backend  -> static/index.html served by FastAPI
    #   webview  -> pywebview's JS bridge / platform assets
    # modulegraph auto-discovers the rest (fastapi, uvicorn, pydantic, …) from
    # imports, so listing them here only risks name-resolution failures.
    "packages": [
        "backend",
        "webview",
        # anyio loads its event-loop backend dynamically (anyio._backends._asyncio)
        # via importlib, which py2app's static analysis can't see. Force the whole
        # package in, or every threadpool-run (sync) endpoint 500s at runtime.
        "anyio",
    ],
    # uvicorn resolves several implementations dynamically; name them so py2app
    # doesn't tree-shake them away.
    "includes": [
        "uvicorn.logging",
        "uvicorn.loops.asyncio",
        "uvicorn.protocols.http.h11_impl",
        "uvicorn.protocols.websockets.websockets_impl",
        "uvicorn.lifespan.on",
        "anyio._backends._asyncio",
        "annotated_types",
    ],
    "excludes": ["tkinter", "PyInstaller", "py2app", "setuptools", "pip"],
    "iconfile": "assets/icon.icns",
    "plist": {
        "CFBundleName": "Firstmate",
        "CFBundleDisplayName": "Firstmate Cockpit",
        "CFBundleIdentifier": "com.manjesh.firstmate-cockpit",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "0.1.0",
        "LSMinimumSystemVersion": "11.0",
        "NSHighResolutionCapable": True,
        # It's a normal windowed app (not a background agent).
        "LSUIElement": False,
    },
}

setup(
    app=APP,
    name="Firstmate",
    options={"py2app": OPTIONS},
)
