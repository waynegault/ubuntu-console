#!/bin/bash
# Handler for oc-model-use MCP tool

MODEL_ID="$1"
# Call the tactical-console command to start the model
/home/wayne/ubuntu-console/bin/tac_hostmetrics.sh --start-model "$MODEL_ID"

# end of file
