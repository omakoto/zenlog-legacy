#!/bin/bash

set -e

medir="${0%/*}"

cd "$medir"

for file in */*-test.{sh,rb} ; do
  echo "Running $file"
  "$file"
done
