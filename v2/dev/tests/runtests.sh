#!/bin/bash

set -e

export ZENLOG_TEST=1
cd "$(dirname "$0")"

for n in *.t ; do
  perl -w $n
done
