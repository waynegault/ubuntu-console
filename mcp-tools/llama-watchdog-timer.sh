#!/bin/bash
# Handler for llama-watchdog-timer MCP tool
ACTION="$1"
systemctl --user "$ACTION" llama-watchdog.timer

# end of file
