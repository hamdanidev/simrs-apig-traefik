#!/bin/sh
set -eu

rm -rf /rendered/*

find /templates -type f \( -name '*.yml' -o -name '*.yaml' \) | while read -r src; do
  rel="${src#/templates/}"
  out="/rendered/$(printf '%s' "$rel" | tr '/\\' '__')"
  envsubst < "$src" > "$out"
done
