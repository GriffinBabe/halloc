#! /bin/bash

# runs specific make target for each performance test
ls -1 | grep -vE 'bin|tmp|make' | xargs -IXA_TEST -P0 make -C XA_TEST $1