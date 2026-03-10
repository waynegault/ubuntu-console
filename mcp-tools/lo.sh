#!/bin/bash
# Handler for lo MCP tool
journalctl --user -u openclaw-gateway.service --no-pager -n 120 --output=cat 2>&1

# end of file
