"""Qt binding compatibility helpers for the live plotter UIs."""

from __future__ import annotations

import os
import sys
from typing import Any, Callable


def _load_pyqt5():
    from PyQt5 import QtCore, QtGui, QtWidgets

    os.environ["PYQTGRAPH_QT_LIB"] = "PyQt5"
    import pyqtgraph as pg

    return "PyQt5", QtCore, QtGui, QtWidgets, pg


def _load_pyside6():
    from PySide6 import QtCore, QtGui, QtWidgets

    os.environ["PYQTGRAPH_QT_LIB"] = "PySide6"
    import pyqtgraph as pg

    return "PySide6", QtCore, QtGui, QtWidgets, pg


def _binding_loaders() -> tuple[Callable[[], tuple[str, Any, Any, Any, Any]], ...]:
    if sys.platform == "win32":
        return (_load_pyside6, _load_pyqt5)
    return (_load_pyqt5, _load_pyside6)


_errors: list[str] = []
for _loader in _binding_loaders():
    try:
        QT_API, QtCore, QtGui, QtWidgets, pg = _loader()
        break
    except ImportError as exc:
        _errors.append(f"{_loader.__name__[6:]}: {exc}")
else:
    detail = "; ".join(_errors) if _errors else "no Qt binding import succeeded"
    raise ImportError(
        "pyqtgraph and a supported Qt binding are required. "
        "Install PySide6 on Windows or PyQt5 on macOS/Linux. "
        f"Import attempts: {detail}"
    )


def exec_dialog(dialog: Any) -> int:
    """Run a modal dialog across PyQt5 and PySide6."""
    exec_fn = getattr(dialog, "exec", None)
    if callable(exec_fn):
        return int(exec_fn())
    return int(dialog.exec_())


def exec_app(app: Any) -> int:
    """Run the Qt event loop across PyQt5 and PySide6."""
    exec_fn = getattr(app, "exec", None)
    if callable(exec_fn):
        return int(exec_fn())
    return int(app.exec_())
