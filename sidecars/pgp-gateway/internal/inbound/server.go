package inbound

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/emersion/go-smtp"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/metrics"
)

type ServerConfig struct {
	Domain          string
	MaxMessageBytes int64
	Rules           config.Rules
	Processor       Processor
	Metrics         *metrics.Recorder
}

func NewServer(addr string, cfg ServerConfig) *smtp.Server {
	s := smtp.NewServer(&backend{cfg: cfg})
	s.Addr = addr
	s.Domain = cfg.Domain
	if s.Domain == "" {
		s.Domain = "pgp-gateway.local"
	}
	s.MaxRecipients = 1
	s.MaxMessageBytes = cfg.MaxMessageBytes
	s.ReadTimeout = 30 * time.Second
	s.WriteTimeout = 30 * time.Second
	s.AllowInsecureAuth = true
	return s
}

type backend struct {
	cfg ServerConfig
}

func (b *backend) NewSession(*smtp.Conn) (smtp.Session, error) {
	return &session{cfg: b.cfg}, nil
}

type session struct {
	cfg   ServerConfig
	from  string
	match config.Match
	rcpts int
}

func (s *session) Mail(from string, _ *smtp.MailOptions) error {
	if from == "" {
		s.cfg.Metrics.IncRefused(metrics.ReasonPolicy)
		return smtpError(550, smtp.EnhancedCode{5, 1, 7}, "empty sender refused")
	}
	s.from = from
	s.match = config.Match{}
	s.rcpts = 0
	return nil
}

func (s *session) Rcpt(to string, _ *smtp.RcptOptions) error {
	if s.from == "" {
		s.cfg.Metrics.IncRefused(metrics.ReasonPolicy)
		return smtpError(503, smtp.EnhancedCode{5, 5, 1}, "MAIL required before RCPT")
	}
	if s.rcpts >= 1 {
		s.cfg.Metrics.IncRefused(metrics.ReasonPolicy)
		return smtpError(550, smtp.EnhancedCode{5, 5, 3}, "only one recipient is accepted")
	}

	match, err := s.cfg.Rules.MatchRecipient(to)
	if err != nil {
		switch {
		case errors.Is(err, config.ErrNoKey):
			s.cfg.Metrics.IncRefused(metrics.ReasonNoKey)
			return smtpError(550, smtp.EnhancedCode{5, 7, 1}, "no encryption key for recipient")
		case errors.Is(err, config.ErrMultipleKeys):
			s.cfg.Metrics.IncRefused(metrics.ReasonMultipleKeys)
			return smtpError(550, smtp.EnhancedCode{5, 7, 1}, "multiple encryption keys match recipient")
		default:
			s.cfg.Metrics.IncRefused(metrics.ReasonPolicy)
			return smtpError(550, smtp.EnhancedCode{5, 1, 3}, "invalid recipient")
		}
	}
	s.match = match
	s.rcpts = 1
	return nil
}

func (s *session) Data(r io.Reader) error {
	if s.from == "" || s.rcpts != 1 {
		s.cfg.Metrics.IncRefused(metrics.ReasonPolicy)
		return smtpError(503, smtp.EnhancedCode{5, 5, 1}, "MAIL and RCPT required before DATA")
	}
	if s.cfg.Processor == nil {
		s.cfg.Metrics.IncRefused(metrics.ReasonPolicy)
		return smtpError(451, smtp.EnhancedCode{4, 3, 0}, "delivery processor unavailable")
	}

	data, err := readMessage(r, s.cfg.MaxMessageBytes)
	if err != nil {
		s.cfg.Metrics.IncRefused(metrics.ReasonOversize)
		return smtpError(552, smtp.EnhancedCode{5, 3, 4}, "maximum message size exceeded")
	}
	s.cfg.Metrics.IncReceived()

	err = s.cfg.Processor.Process(context.Background(), Message{
		From:  s.from,
		Match: s.match,
		Data:  data,
	})
	if err == nil {
		return nil
	}

	var deliveryErr *DeliveryError
	if errors.As(err, &deliveryErr) {
		if deliveryErr.Kind == ErrorTemporary {
			return smtpError(451, smtp.EnhancedCode{4, 4, 0}, "temporary relay failure")
		}
		return smtpError(550, smtp.EnhancedCode{5, 6, 0}, "message refused")
	}
	return smtpError(451, smtp.EnhancedCode{4, 3, 0}, "temporary processing failure")
}

func (s *session) Reset() {
	s.from = ""
	s.match = config.Match{}
	s.rcpts = 0
}

func (s *session) Logout() error {
	return nil
}

func readMessage(r io.Reader, max int64) ([]byte, error) {
	if max <= 0 {
		max = config.DefaultMaxMessageBytes
	}
	data, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("message too large")
	}
	return data, nil
}

func smtpError(code int, enhanced smtp.EnhancedCode, message string) *smtp.SMTPError {
	return &smtp.SMTPError{
		Code:         code,
		EnhancedCode: enhanced,
		Message:      message,
	}
}
