package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/inbound"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/metrics"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/outbound"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/pgpmime"
)

func main() {
	logger := log.New(os.Stdout, "pgp-gateway ", log.LstdFlags|log.LUTC)
	cfg, err := config.LoadFromEnv(config.OS())
	if err != nil {
		logger.Fatalf("configuration error: %v", err)
	}

	recorder := metrics.New(nil)
	relayer := outbound.Relay{Config: cfg.SMTP}
	processor := inbound.GatewayProcessor{
		Builder: pgpmime.Builder{OuterSubject: cfg.OuterSubject},
		Relayer: relayer,
		Metrics: recorder,
	}

	smtpServer := inbound.NewServer(cfg.ListenAddr, inbound.ServerConfig{
		Domain:          "pgp-gateway.local",
		MaxMessageBytes: cfg.MaxMessageBytes,
		Rules:           cfg.Rules,
		Processor:       processor,
		Metrics:         recorder,
	})
	metricsServer := &http.Server{
		Addr:    cfg.MetricsAddr,
		Handler: metrics.Handler(nil),
	}

	errCh := make(chan error, 2)
	go func() {
		logger.Printf("starting SMTP listener on %s", cfg.ListenAddr)
		if err := smtpServer.ListenAndServe(); err != nil {
			errCh <- err
		}
	}()
	go func() {
		logger.Printf("starting metrics listener on %s", cfg.MetricsAddr)
		if err := metricsServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-signals:
		logger.Printf("received %s, shutting down", sig)
	case err := <-errCh:
		logger.Printf("server error: %v", err)
	}

	_ = smtpServer.Close()
	_ = metricsServer.Shutdown(context.Background())
}
