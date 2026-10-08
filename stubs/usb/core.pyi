"""Minimal PyUSB stubs for the subset the NAS BT bridge uses.

PyUSB 1.3.1 ships no annotations at all (no py.typed), so these signatures were
read from the wheel's source.  Where the package gives no annotation the return
type is Any rather than a guessed concrete type - a guess would hide errors.
"""

from typing import Any

class USBError(OSError): ...
class USBTimeoutError(USBError): ...

class Endpoint:
    bEndpointAddress: int
    bmAttributes: int
    def read(self, size_or_buffer: Any, timeout: int | None = ...) -> Any: ...

class Interface:
    bInterfaceNumber: int
    def endpoints(self) -> tuple[Endpoint, ...]: ...

class Configuration:
    def __getitem__(self, index: tuple[int, int]) -> Interface: ...

class Device:
    bus: int | None
    address: int | None
    def get_active_configuration(self) -> Configuration: ...
    def set_interface_altsetting(
        self, interface: Any = ..., alternate_setting: Any = ...
    ) -> None: ...
    def ctrl_transfer(
        self,
        bmRequestType: int,
        bRequest: int,
        wValue: int = ...,
        wIndex: int = ...,
        data_or_wLength: Any = ...,
        timeout: int | None = ...,
    ) -> Any: ...
    def is_kernel_driver_active(self, interface: Any) -> bool: ...
    def detach_kernel_driver(self, interface: Any) -> None: ...
    def attach_kernel_driver(self, interface: Any) -> None: ...

def find(
    find_all: bool = ...,
    backend: Any = ...,
    custom_match: Any = ...,
    **args: Any,
) -> Device | None: ...
