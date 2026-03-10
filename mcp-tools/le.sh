#!/bin/bash
# Handler for le MCP tool
journalctl --user -u openclaw-gateway.service --no-pager -n 60 --output=cat 2>&1 | tail -40

# end of file
