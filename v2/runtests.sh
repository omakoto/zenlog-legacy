#!/bin/bash

set -

for n in tests/*.t ; do
  perl $n
done
