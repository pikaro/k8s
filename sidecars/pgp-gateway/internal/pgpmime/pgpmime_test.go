package pgpmime

import (
	"bytes"
	"io"
	"mime"
	"mime/multipart"
	"net/mail"
	"strings"
	"testing"
	"time"

	pgp "github.com/ProtonMail/gopenpgp/v3/crypto"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/config"
	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/testkeys"
)

func TestBuildCreatesDecryptablePGPMIME(t *testing.T) {
	keys, err := testkeys.Generate("Main", "main@example.com")
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	publicKey, err := pgp.NewKeyFromArmored(keys.PublicArmored)
	if err != nil {
		t.Fatalf("parse public key: %v", err)
	}

	raw := []byte(strings.ReplaceAll(`From: App <app@example.com>
To: Alias <alias@example.com>
Subject: Secret application subject
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="inner"

--inner
Content-Type: text/plain; charset=utf-8

hello encrypted world
--inner
Content-Type: text/plain
Content-Disposition: attachment; filename="report.txt"

attachment body
--inner--
`, "\n", "\r\n"))

	out, err := (Builder{
		OuterSubject: "Encrypted message",
		Now: func() time.Time {
			return time.Unix(1710000000, 0)
		},
	}).Build(raw, "app@example.com", config.Match{
		Rule:      config.Rule{Key: publicKey},
		Recipient: "alias@example.com",
		RelayTo:   "alias@example.com",
	})
	if err != nil {
		t.Fatalf("Build returned error: %v", err)
	}

	msg, err := mail.ReadMessage(bytes.NewReader(out))
	if err != nil {
		t.Fatalf("read output message: %v", err)
	}
	if got := msg.Header.Get("Subject"); got != "Encrypted message" {
		t.Fatalf("outer Subject = %q", got)
	}
	if strings.Contains(string(out), "Secret application subject") {
		t.Fatalf("outer message leaked original subject")
	}

	mediaType, params, err := mime.ParseMediaType(msg.Header.Get("Content-Type"))
	if err != nil {
		t.Fatalf("parse content type: %v", err)
	}
	if mediaType != "multipart/encrypted" {
		t.Fatalf("media type = %q", mediaType)
	}
	if params["protocol"] != "application/pgp-encrypted" {
		t.Fatalf("protocol = %q", params["protocol"])
	}

	encrypted := readEncryptedPart(t, msg.Body, params["boundary"])
	privateKey, err := pgp.NewKeyFromArmored(keys.PrivateArmored)
	if err != nil {
		t.Fatalf("parse private key: %v", err)
	}
	defer privateKey.ClearPrivateParams()
	dec, err := pgp.PGP().Decryption().DecryptionKey(privateKey).New()
	if err != nil {
		t.Fatalf("create decryptor: %v", err)
	}
	decrypted, err := dec.Decrypt([]byte(encrypted), pgp.Armor)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	plain := decrypted.String()
	for _, want := range []string{
		"Subject: Secret application subject",
		"Content-Type: multipart/mixed",
		"filename=\"report.txt\"",
		"attachment body",
	} {
		if !strings.Contains(plain, want) {
			t.Fatalf("decrypted message missing %q:\n%s", want, plain)
		}
	}
}

func TestBuildRejectsMalformedMessage(t *testing.T) {
	keys, err := testkeys.Generate("Main", "main@example.com")
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	publicKey, err := pgp.NewKeyFromArmored(keys.PublicArmored)
	if err != nil {
		t.Fatalf("parse public key: %v", err)
	}

	_, err = (Builder{}).Build([]byte("not a message"), "app@example.com", config.Match{
		Rule:    config.Rule{Key: publicKey},
		RelayTo: "main@example.com",
	})
	if err == nil {
		t.Fatalf("Build succeeded for malformed message")
	}
}

func readEncryptedPart(t *testing.T, body io.Reader, boundary string) string {
	t.Helper()
	mr := multipart.NewReader(body, boundary)
	for {
		part, err := mr.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("read part: %v", err)
		}
		if strings.HasPrefix(part.Header.Get("Content-Type"), "application/octet-stream") {
			data, err := io.ReadAll(part)
			if err != nil {
				t.Fatalf("read encrypted part: %v", err)
			}
			return string(data)
		}
	}
	t.Fatalf("encrypted part not found")
	return ""
}
