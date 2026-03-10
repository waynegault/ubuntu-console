#!/bin/bash
# Handler for llama-watchdog-service MCP tool
ACTION="$1"
systemctl --user "$ACTION" llama-watchdog.service

# end of file
