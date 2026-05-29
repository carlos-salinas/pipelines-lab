#!/bin/bash

# Script to extract Kueue version from go.mod file
# Usage: ./scripts/get-kueue-version.sh

set -e

# Check if go.mod exists
if [ ! -f "go.mod" ]; then
    echo "Error: go.mod file not found" >&2
    exit 1
fi

# Extract Kueue version from go.mod
KUEUE_VERSION=$(grep 'sigs.k8s.io/kueue' go.mod | awk '{print $2}')

if [ -z "$KUEUE_VERSION" ]; then
    echo "Error: Could not find sigs.k8s.io/kueue in go.mod" >&2
    exit 1
fi

echo "$KUEUE_VERSION"
