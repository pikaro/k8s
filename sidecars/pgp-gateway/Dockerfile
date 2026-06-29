FROM golang:1.24-alpine AS build

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/pgp-gateway ./cmd/pgp-gateway

FROM alpine:3.22

RUN apk add --no-cache ca-certificates

COPY --from=build /out/pgp-gateway /usr/local/bin/pgp-gateway

USER 65532:65532
EXPOSE 2525 9090
ENTRYPOINT ["/usr/local/bin/pgp-gateway"]
