package pgpmime

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"net/textproto"
	"strings"
	"time"

	pgp "github.com/ProtonMail/gopenpgp/v3/crypto"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
)

var ErrMalformed = errors.New("malformed message")

type Builder struct {
	OuterSubject string
	Now          func() time.Time
}

func (b Builder) Build(raw []byte, from string, match config.Match) ([]byte, error) {
	if len(raw) == 0 {
		return nil, fmt.Errorf("%w: empty message", ErrMalformed)
	}

	inner, original, err := normalizeInner(raw)
	if err != nil {
		return nil, err
	}

	encrypted, err := encrypt(inner, match.Rule.Key)
	if err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	if b.Now != nil {
		now = b.Now().UTC()
	}
	subject := b.OuterSubject
	if strings.TrimSpace(subject) == "" {
		subject = config.DefaultOuterSubject
	}

	fromHeader := original.Header.Get("From")
	if strings.TrimSpace(fromHeader) == "" {
		fromHeader = from
	}
	fromHeader, err = safeAddressHeader(fromHeader)
	if err != nil {
		return nil, fmt.Errorf("%w: invalid From header", ErrMalformed)
	}
	toHeader, err := safeAddressHeader(match.RelayTo)
	if err != nil {
		return nil, fmt.Errorf("invalid relay recipient: %w", err)
	}

	var out bytes.Buffer
	boundary := randomBoundary()
	writeHeader(&out, "From", fromHeader)
	writeHeader(&out, "To", toHeader)
	writeHeader(&out, "Subject", sanitizeHeader(subject))
	writeHeader(&out, "Date", now.Format(time.RFC1123Z))
	writeHeader(&out, "Message-ID", fmt.Sprintf("<%d.%s@pgp-gateway.local>", now.UnixNano(), boundary[:12]))
	writeHeader(&out, "MIME-Version", "1.0")
	writeHeader(&out, "Content-Type", mime.FormatMediaType("multipart/encrypted", map[string]string{
		"protocol": "application/pgp-encrypted",
		"boundary": boundary,
	}))
	out.WriteString("\r\n")

	mw := multipart.NewWriter(&out)
	if err := mw.SetBoundary(boundary); err != nil {
		return nil, err
	}

	versionHeader := textproto.MIMEHeader{}
	versionHeader.Set("Content-Type", "application/pgp-encrypted")
	versionPart, err := mw.CreatePart(versionHeader)
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(versionPart, "Version: 1\r\n"); err != nil {
		return nil, err
	}

	encryptedHeader := textproto.MIMEHeader{}
	encryptedHeader.Set("Content-Type", `application/octet-stream; name="encrypted.asc"`)
	encryptedHeader.Set("Content-Description", "OpenPGP encrypted message")
	encryptedHeader.Set("Content-Disposition", `inline; filename="encrypted.asc"`)
	encryptedHeader.Set("Content-Transfer-Encoding", "7bit")
	encryptedPart, err := mw.CreatePart(encryptedHeader)
	if err != nil {
		return nil, err
	}
	if _, err := io.WriteString(encryptedPart, encrypted); err != nil {
		return nil, err
	}
	if !strings.HasSuffix(encrypted, "\r\n") {
		if _, err := io.WriteString(encryptedPart, "\r\n"); err != nil {
			return nil, err
		}
	}

	if err := mw.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func normalizeInner(raw []byte) ([]byte, *mail.Message, error) {
	msg, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		return nil, nil, fmt.Errorf("%w: %v", ErrMalformed, err)
	}

	if msg.Header.Get("MIME-Version") != "" || msg.Header.Get("Content-Type") != "" {
		return raw, msg, nil
	}

	body, err := io.ReadAll(msg.Body)
	if err != nil {
		return nil, nil, err
	}

	var out bytes.Buffer
	for key, values := range msg.Header {
		for _, value := range values {
			writeHeader(&out, key, sanitizeHeader(value))
		}
	}
	writeHeader(&out, "MIME-Version", "1.0")
	writeHeader(&out, "Content-Type", "text/plain; charset=utf-8")
	out.WriteString("\r\n")
	out.Write(body)
	return out.Bytes(), msg, nil
}

func encrypt(plaintext []byte, key *pgp.Key) (string, error) {
	handle, err := pgp.PGP().Encryption().Recipient(key).New()
	if err != nil {
		return "", err
	}
	message, err := handle.Encrypt(plaintext)
	if err != nil {
		return "", err
	}
	return message.Armor()
}

func safeAddressHeader(value string) (string, error) {
	parsed, err := mail.ParseAddress(strings.TrimSpace(value))
	if err != nil {
		return "", err
	}
	return sanitizeHeader(parsed.String()), nil
}

func sanitizeHeader(value string) string {
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	return strings.TrimSpace(value)
}

func writeHeader(w *bytes.Buffer, key, value string) {
	w.WriteString(key)
	w.WriteString(": ")
	w.WriteString(value)
	w.WriteString("\r\n")
}

func randomBoundary() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return "pgp-gateway-" + hex.EncodeToString(b[:])
}
