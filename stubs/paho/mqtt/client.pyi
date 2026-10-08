"""Minimal paho-mqtt stubs for the subset the NAS collectors use.

Grounded against paho-mqtt 2.1.0, whose wheel ships py.typed: every signature
below is read from the package's own inline annotations.  Only the symbols
reached from nas/ call sites are declared - a real package has far more surface
than the call sites touch, and inventing the rest would be a stub that hides
errors.
"""

import enum
from typing import Any, Callable

class CallbackAPIVersion(enum.Enum):
    # Enum members are declared in value form, not as annotations: `VERSION2: int`
    # would type `CallbackAPIVersion.VERSION2` as int and break every call passing it.
    VERSION1 = 1
    VERSION2 = 2

class MQTTMessage:
    topic: str
    payload: bytes

class Client:
    # The callback's signature depends on callback_api_version, so the concrete type
    # is not knowable from here; Callable[..., None] is permissive by design.
    on_connect: Callable[..., None] | None
    on_message: Callable[..., None] | None
    def __init__(
        self,
        callback_api_version: CallbackAPIVersion = ...,
        client_id: str | None = ...,
        clean_session: bool | None = ...,
    ) -> None: ...
    def connect(
        self,
        host: str,
        port: int = ...,
        keepalive: int = ...,
    ) -> Any: ...
    def publish(
        self,
        topic: str,
        payload: Any = ...,
        qos: int = ...,
        retain: bool = ...,
    ) -> Any: ...
    def subscribe(self, topic: Any, qos: int = ...) -> Any: ...
    def will_set(
        self,
        topic: str,
        payload: Any = ...,
        qos: int = ...,
        retain: bool = ...,
    ) -> None: ...
    def disconnect(self) -> Any: ...
    def loop_start(self) -> Any: ...
    def loop_stop(self) -> Any: ...
