package inbound

import (
	"context"
	"errors"

	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/metrics"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/outbound"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/pgpmime"
)

type Message struct {
	From  string
	Match config.Match
	Data  []byte
}

type Processor interface {
	Process(context.Context, Message) error
}

type Builder interface {
	Build(raw []byte, from string, match config.Match) ([]byte, error)
}

type Relayer interface {
	Send(context.Context, outbound.Message) error
}

type GatewayProcessor struct {
	Builder Builder
	Relayer Relayer
	Metrics *metrics.Recorder
}

func (p GatewayProcessor) Process(ctx context.Context, message Message) error {
	encrypted, err := p.Builder.Build(message.Data, message.From, message.Match)
	if err != nil {
		reason := metrics.ReasonEncryptionError
		if errors.Is(err, pgpmime.ErrMalformed) {
			reason = metrics.ReasonMalformed
		}
		p.Metrics.IncRefused(reason)
		return Permanent(reason, err)
	}
	p.Metrics.IncEncrypted()

	if err := p.Relayer.Send(ctx, outbound.Message{
		From: message.From,
		To:   message.Match.RelayTo,
		Data: encrypted,
	}); err != nil {
		p.Metrics.IncRelayFailed()
		return Temporary("relay_failed", err)
	}
	p.Metrics.IncRelayed()
	return nil
}
