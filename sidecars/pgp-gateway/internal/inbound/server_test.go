package inbound

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/emersion/go-smtp"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/metrics"
	"github.com/prometheus/client_golang/prometheus"
)

func TestSessionRequiresMatchingRecipient(t *testing.T) {
	pattern, err := config.ParsePattern("*@example.com")
	if err != nil {
		t.Fatalf("parse pattern: %v", err)
	}
	s := &session{cfg: ServerConfig{
		Rules: config.Rules{{
			Match: []config.Pattern{pattern},
		}},
		Metrics: metrics.New(prometheus.NewRegistry()),
	}}

	if err := s.Mail("app@example.com", nil); err != nil {
		t.Fatalf("Mail returned error: %v", err)
	}
	if err := s.Rcpt("alias@example.com", nil); err != nil {
		t.Fatalf("Rcpt returned error: %v", err)
	}

	err = s.Rcpt("other@example.com", nil)
	var smtpErr *smtp.SMTPError
	if !errors.As(err, &smtpErr) || smtpErr.Code != 550 {
		t.Fatalf("second Rcpt error = %v, want SMTP 550", err)
	}
}

func TestSessionRejectsRecipientWithoutKey(t *testing.T) {
	pattern, err := config.ParsePattern("*@example.com")
	if err != nil {
		t.Fatalf("parse pattern: %v", err)
	}
	s := &session{cfg: ServerConfig{
		Rules: config.Rules{{
			Match: []config.Pattern{pattern},
		}},
		Metrics: metrics.New(prometheus.NewRegistry()),
	}}

	if err := s.Mail("app@example.com", nil); err != nil {
		t.Fatalf("Mail returned error: %v", err)
	}
	err = s.Rcpt("other@example.net", nil)
	var smtpErr *smtp.SMTPError
	if !errors.As(err, &smtpErr) || smtpErr.Code != 550 {
		t.Fatalf("Rcpt error = %v, want SMTP 550", err)
	}
}

func TestSessionDataReturnsSuccessOnlyAfterProcessorSuccess(t *testing.T) {
	pattern, err := config.ParsePattern("*@example.com")
	if err != nil {
		t.Fatalf("parse pattern: %v", err)
	}
	processor := &fakeProcessor{}
	s := &session{cfg: ServerConfig{
		Rules: config.Rules{{
			Match: []config.Pattern{pattern},
		}},
		Processor: processor,
		Metrics:   metrics.New(prometheus.NewRegistry()),
	}}

	if err := s.Mail("app@example.com", nil); err != nil {
		t.Fatalf("Mail returned error: %v", err)
	}
	if err := s.Rcpt("alias@example.com", nil); err != nil {
		t.Fatalf("Rcpt returned error: %v", err)
	}
	if processor.called {
		t.Fatalf("processor called before DATA")
	}

	err = s.Data(strings.NewReader("From: app@example.com\r\n\r\nbody\r\n"))
	if err != nil {
		t.Fatalf("Data returned error: %v", err)
	}
	if !processor.called {
		t.Fatalf("processor was not called")
	}
	if processor.message.Match.RelayTo != "alias@example.com" {
		t.Fatalf("relay recipient = %q", processor.message.Match.RelayTo)
	}
}

func TestSessionDataRelayFailureIsTemporary(t *testing.T) {
	pattern, err := config.ParsePattern("*@example.com")
	if err != nil {
		t.Fatalf("parse pattern: %v", err)
	}
	s := &session{cfg: ServerConfig{
		Rules: config.Rules{{
			Match: []config.Pattern{pattern},
		}},
		Processor: &fakeProcessor{err: Temporary("relay_failed", errors.New("upstream down"))},
		Metrics:   metrics.New(prometheus.NewRegistry()),
	}}

	if err := s.Mail("app@example.com", nil); err != nil {
		t.Fatalf("Mail returned error: %v", err)
	}
	if err := s.Rcpt("alias@example.com", nil); err != nil {
		t.Fatalf("Rcpt returned error: %v", err)
	}

	err = s.Data(strings.NewReader("From: app@example.com\r\n\r\nbody\r\n"))
	var smtpErr *smtp.SMTPError
	if !errors.As(err, &smtpErr) || smtpErr.Code != 451 {
		t.Fatalf("Data error = %v, want SMTP 451", err)
	}
}

type fakeProcessor struct {
	called  bool
	message Message
	err     error
}

func (p *fakeProcessor) Process(_ context.Context, message Message) error {
	p.called = true
	p.message = message
	return p.err
}
