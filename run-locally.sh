#!/bin/bash

set -e

./build.sh
solo5-virtio-run ./mvgce.virtio -n tap100 -- --hostname mvgce.bacarella.com --ipv4-only=true
