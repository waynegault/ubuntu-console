"""Minimal PyUSB libusb1 backend stub (see usb/core.pyi for provenance)."""

from typing import Any, Callable

def get_backend(find_library: Callable[..., Any] | None = ...) -> Any: ...
