# -*- mode: python ; coding: utf-8 -*-
from pathlib import Path
import sys
from PyInstaller.utils.hooks import collect_data_files

root = Path(SPECPATH)
datas = collect_data_files("reportlab") + collect_data_files("certifi")

# Keep the spec portable.  Some Python distributions need OpenSSL DLLs to be
# listed explicitly, but they must be discovered from the active interpreter
# rather than from a developer's local runtime path.
dll_dir = Path(sys.base_prefix) / "DLLs"
openssl_dlls = []
for pattern in ("libcrypto-*.dll", "libssl-*.dll"):
    openssl_dlls.extend((str(path), ".") for path in dll_dir.glob(pattern))


a = Analysis(
    [str(root / "run.py")],
    pathex=[str(root)],
    binaries=openssl_dlls,
    datas=datas,
    hiddenimports=["PIL._tkinter_finder"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    name="SitePhotoReport",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    exclude_binaries=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="SitePhotoReport",
)
