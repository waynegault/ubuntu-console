"""Minimal bleak stubs for the subset the Mi Scale collector uses.

Grounded against bleak 3.0.2, whose wheel ships py.typed: every signature below
is read from the package's own inline annotations.  Only the symbols reached
from the call site are declared.
"""

from types import TracebackType
from typing import Any, Callable

class BLEDevice:
    address: str
    name: str | None

class BleakClient:
    def __init__(self, address_or_ble_device: BLEDevice | str, **kwargs: Any) -> None: ...
    @property
    def is_connected(self) -> bool: ...
    async def read_gatt_char(
        self, char_specifier: Any, *, use_cached: bool = ..., **kwargs: Any
    ) -> bytearray: ...
    async def start_notify(
        self, char_specifier: Any, callback: Callable[..., Any], **kwargs: Any
    ) -> None: ...
    async def stop_notify(self, characteristic: Any) -> None: ...
    async def __aenter__(self) -> BleakClient: ...
    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: TracebackType | None,
    ) -> None: ...

class BleakScanner:
    @classmethod
    async def discover(
        cls, timeout: float = ..., *, return_adv: bool = ..., **kwargs: Any
    ) -> list[BLEDevice]: ...
