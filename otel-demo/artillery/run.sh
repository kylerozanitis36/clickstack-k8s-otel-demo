#!/bin/sh
# Render the artillery scenario from env and run it once. The Deployment wraps
# this in a restart loop, so a single run is all we do here.
set -e

: "${ARRIVAL_COUNT:=1}"
: "${DURATION:=60}"

envsubst < load-test.template.yaml > load-test.yaml
exec artillery run load-test.yaml
