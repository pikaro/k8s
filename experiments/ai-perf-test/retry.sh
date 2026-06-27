#!/bin/bash

kubectl -n ai-perf-test delete job ai-perf-client --ignore-not-found
kubectl -n ai-perf-test delete pod ai-perf-results-reader --ignore-not-found
kubectl apply -k .
kubectl -n ai-perf-test logs -f job/ai-perf-client
kubectl -n ai-perf-test wait --for=condition=Ready pod/ai-perf-results-reader --timeout=120s
kubectl -n ai-perf-test cp ai-perf-results-reader:/results ./tmp/ai-perf-test-results
# shellcheck disable=SC2012
ls -1tr tmp/ai-perf-test-results/ | tail -n 1 | xargs -I {} play tmp/ai-perf-test-results/{}/response.wav
