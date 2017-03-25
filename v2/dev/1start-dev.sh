#!/bin/bash

set -e

cd $(dirname "$0")/..

cp -pr tests zenlog* Zenlog* dev
