package inbound

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/outbound"
)

func TestGatewayProcessorEncryptsBeforeRelayAndRequiresRelaySuccess(t *testing.T) {
	builder := &fakeBuilder{}
	relayer := &fakeRelayer{}
	processor := GatewayProcessor{
		Builder: builder,
		Relayer: relayer,
	}

	err := processor.Process(context.Background(), Message{
		From: "app@example.com",
		Match: config.Match{
			RelayTo: "main@example.com",
		},
		Data: []byte("plain"),
	})
	if err != nil {
		t.Fatalf("Process returned error: %v", err)
	}

	if !reflect.DeepEqual(builder.calls, []string{"build"}) {
		t.Fatalf("builder calls = %#v", builder.calls)
	}
	if !reflect.DeepEqual(relayer.calls, []string{"send"}) {
		t.Fatalf("relayer calls = %#v", relayer.calls)
	}
	if string(relayer.message.Data) != "encrypted" {
		t.Fatalf("relayed data = %q", string(relayer.message.Data))
	}
}

func TestGatewayProcessorRelayFailureIsTemporary(t *testing.T) {
	processor := GatewayProcessor{
		Builder: &fakeBuilder{},
		Relayer: &fakeRelayer{err: errors.New("smarthost refused message")},
	}

	err := processor.Process(context.Background(), Message{
		From: "app@example.com",
		Match: config.Match{
			RelayTo: "main@example.com",
		},
		Data: []byte("plain"),
	})
	var deliveryErr *DeliveryError
	if !errors.As(err, &deliveryErr) || deliveryErr.Kind != ErrorTemporary {
		t.Fatalf("Process error = %v, want temporary delivery error", err)
	}
}

type fakeBuilder struct {
	calls []string
	err   error
}

func (b *fakeBuilder) Build([]byte, string, config.Match) ([]byte, error) {
	b.calls = append(b.calls, "build")
	if b.err != nil {
		return nil, b.err
	}
	return []byte("encrypted"), nil
}

type fakeRelayer struct {
	calls   []string
	message outbound.Message
	err     error
}

func (r *fakeRelayer) Send(_ context.Context, message outbound.Message) error {
	r.calls = append(r.calls, "send")
	r.message = message
	return r.err
}
