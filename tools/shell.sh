#!/bin/bash

if [ "$#" -gt 0 ]; then
    ACTION="$1"
    shift
else
    ACTION="cycle"
fi

if [ "${ACTION}" = "run" ] && [ "${1:-}" = "zfs" ]; then
    shift
    set -- nsenter --mount=/proc/1/ns/mnt -- "$@"
fi

start() {
    kubectl -n kube-system apply -f shell.yaml
}

run() {
    kubectl -n kube-system wait --for=condition=Ready pod/admin-shell >/dev/null
    kubectl -n kube-system exec -it admin-shell -- "$@"
}

stop() {
    kubectl -n kube-system delete -f shell.yaml
}

if [ "${ACTION}" = "cycle" ]; then
    start
    run /bin/bash
    stop
elif [ "${ACTION}" = "start" ]; then
    start
elif [ "${ACTION}" = "run" ]; then
    run "$@"
elif [ "${ACTION}" = "stop" ]; then
    stop
else
    echo "Usage: $0 [start|stop|run <command>]"
    exit 1
fi
