"""E2E Test Helpers: assertions, mock_procfs, mock_hardware, mock_server."""

from .assertions import (
    assert_clean_shell_export,
    assert_no_resource_warnings,
    assert_referential_integrity,
    assert_valid_pydantic,
    assert_validation_error,
)
from .mock_hardware import (
    ASUS_SPARK_PROFILE,
    DELL_XPS_PROFILE,
    MockHardwareEmulator,
    emulate_asus_spark,
    emulate_dell_xps,
)
from .mock_procfs import VirtualProcfs
from .mock_server import HermeticHTTPServer, RecordedRequest

__all__ = [
    "ASUS_SPARK_PROFILE",
    "DELL_XPS_PROFILE",
    "HermeticHTTPServer",
    "MockHardwareEmulator",
    "RecordedRequest",
    "VirtualProcfs",
    "assert_clean_shell_export",
    "assert_no_resource_warnings",
    "assert_referential_integrity",
    "assert_valid_pydantic",
    "assert_validation_error",
    "emulate_asus_spark",
    "emulate_dell_xps",
]
