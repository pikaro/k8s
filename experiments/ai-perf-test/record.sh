#!/bin/bash

sox -V3 -d -t wavpcm -b 16 -r 16000 -c 1 recording.wav </dev/tty
kubectl -n ai-perf-test delete configmap ai-perf-input --ignore-not-found
kubectl -n ai-perf-test create configmap ai-perf-input \
    --from-file=input.wav=recording.wav
