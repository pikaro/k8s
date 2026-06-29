package outbound

import (
	"bytes"
	"context"
	"io"
	"reflect"
	"testing"

	"github.com/emersion/go-sasl"
	"github.com/emersion/go-smtp"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
)

func TestRelaySendsAfterAuth(t *testing.T) {
	client := &fakeClient{}
	relay := Relay{
		Config: config.SMTPConfig{
			Host:     "mail.smtp2go.com",
			Port:     587,
			Username: "user",
			Password: "pass",
		},
		Dial: func(context.Context, config.SMTPConfig) (SMTPClient, error) {
			return client, nil
		},
	}

	err := relay.Send(context.Background(), Message{
		From: "app@example.com",
		To:   "main@example.com",
		Data: []byte("From: app@example.com\r\n\r\nbody\r\n"),
	})
	if err != nil {
		t.Fatalf("Send returned error: %v", err)
	}

	want := []string{"auth", "mail:app@example.com", "rcpt:main@example.com", "data", "close-data", "quit", "close"}
	if !reflect.DeepEqual(client.calls, want) {
		t.Fatalf("calls = %#v, want %#v", client.calls, want)
	}
	if got := client.data.String(); got != "From: app@example.com\r\n\r\nbody\r\n" {
		t.Fatalf("data = %q", got)
	}
	if client.mailSize != int64(client.data.Len()) {
		t.Fatalf("mail size = %d, data len = %d", client.mailSize, client.data.Len())
	}
}

type fakeClient struct {
	calls    []string
	data     bytes.Buffer
	mailSize int64
}

func (c *fakeClient) Auth(sasl.Client) error {
	c.calls = append(c.calls, "auth")
	return nil
}

func (c *fakeClient) Mail(from string, opts *smtp.MailOptions) error {
	c.calls = append(c.calls, "mail:"+from)
	if opts != nil {
		c.mailSize = opts.Size
	}
	return nil
}

func (c *fakeClient) Rcpt(to string, _ *smtp.RcptOptions) error {
	c.calls = append(c.calls, "rcpt:"+to)
	return nil
}

func (c *fakeClient) Data() (io.WriteCloser, error) {
	c.calls = append(c.calls, "data")
	return fakeDataWriter{client: c}, nil
}

func (c *fakeClient) Quit() error {
	c.calls = append(c.calls, "quit")
	return nil
}

func (c *fakeClient) Close() error {
	c.calls = append(c.calls, "close")
	return nil
}

type fakeDataWriter struct {
	client *fakeClient
}

func (w fakeDataWriter) Write(p []byte) (int, error) {
	return w.client.data.Write(p)
}

func (w fakeDataWriter) Close() error {
	w.client.calls = append(w.client.calls, "close-data")
	return nil
}
