package outbound

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"strconv"

	"github.com/emersion/go-sasl"
	"github.com/emersion/go-smtp"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
)

type Message struct {
	From string
	To   string
	Data []byte
}

type SMTPClient interface {
	Auth(sasl.Client) error
	Mail(string, *smtp.MailOptions) error
	Rcpt(string, *smtp.RcptOptions) error
	Data() (io.WriteCloser, error)
	Quit() error
	Close() error
}

type DialFunc func(context.Context, config.SMTPConfig) (SMTPClient, error)

type Relay struct {
	Config config.SMTPConfig
	Dial   DialFunc
}

func (r Relay) Send(ctx context.Context, message Message) error {
	dial := r.Dial
	if dial == nil {
		dial = DialStartTLS
	}

	client, err := dial(ctx, r.Config)
	if err != nil {
		return err
	}
	defer client.Close()

	if err := client.Auth(sasl.NewPlainClient("", r.Config.Username, r.Config.Password)); err != nil {
		return err
	}
	if err := client.Mail(message.From, &smtp.MailOptions{Size: int64(len(message.Data))}); err != nil {
		return err
	}
	if err := client.Rcpt(message.To, nil); err != nil {
		return err
	}

	w, err := client.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(message.Data); err != nil {
		w.Close()
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return client.Quit()
}

func DialStartTLS(ctx context.Context, cfg config.SMTPConfig) (SMTPClient, error) {
	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))
	dialer := net.Dialer{Timeout: cfg.Timeout}
	conn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}

	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS12,
		ServerName: cfg.Host,
	}
	client, err := smtp.NewClientStartTLS(conn, tlsConfig)
	if err != nil {
		conn.Close()
		return nil, err
	}
	client.CommandTimeout = cfg.Timeout
	client.SubmissionTimeout = cfg.Timeout
	return realClient{Client: client}, nil
}

type realClient struct {
	*smtp.Client
}

func (c realClient) Data() (io.WriteCloser, error) {
	return c.Client.Data()
}

func WriteAll(w io.Writer, data []byte) error {
	n, err := w.Write(data)
	if err != nil {
		return err
	}
	if n != len(data) {
		return fmt.Errorf("short write: wrote %d of %d bytes", n, len(data))
	}
	return nil
}
