FROM busybox AS bb

FROM quay.io/jetstack/cert-manager-controller:v1.19.1

COPY --from=bb /bin/busybox /bin/busybox

ENTRYPOINT ["/bin/busybox"]
