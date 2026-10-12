#!/bin/sh
# Collectors that hit environment.data.gov.uk run one at a time to stay under the WAF rate limit.
cd "$(dirname "$0")/collect"
for s in "$@"; do PYTHONPATH=.. python3 $s.py > ../../data/log_$s.txt 2>&1; done
