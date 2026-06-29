package config

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/pikaro/k8s/sidecars/pgp-gateway/internal/testkeys"
)

func TestLoadFromEnvDefaultsAndWildcardRules(t *testing.T) {
	dir := t.TempDir()
	keys := writeKeyRules(t, dir, "main@example.com", []string{"main@example.com", "*@example.com"}, "")

	cfg, err := LoadFromEnv(Env{
		"PGP_KEY_RULES_FILE": keys,
		"SMTP_USERNAME":      "smtp-user",
		"SMTP_PASSWORD":      "smtp-pass",
	})
	if err != nil {
		t.Fatalf("LoadFromEnv returned error: %v", err)
	}

	if cfg.ListenAddr != DefaultListenAddr {
		t.Fatalf("ListenAddr = %q, want %q", cfg.ListenAddr, DefaultListenAddr)
	}
	if cfg.MaxMessageBytes != DefaultMaxMessageBytes {
		t.Fatalf("MaxMessageBytes = %d, want %d", cfg.MaxMessageBytes, DefaultMaxMessageBytes)
	}

	match, err := cfg.Rules.MatchRecipient("Alias@Example.com")
	if err != nil {
		t.Fatalf("MatchRecipient returned error: %v", err)
	}
	if match.Recipient != "alias@example.com" {
		t.Fatalf("Recipient = %q", match.Recipient)
	}
	if match.RelayTo != "alias@example.com" {
		t.Fatalf("RelayTo = %q", match.RelayTo)
	}
	if match.Rule.Key == nil {
		t.Fatalf("matched rule has nil key")
	}
}

func TestLoadRulesRejectsFingerprintMismatch(t *testing.T) {
	dir := t.TempDir()
	key, err := testkeys.Generate("Main", "main@example.com")
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.asc"), []byte(key.PublicArmored), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	rules := `rules:
  - match: ["*@example.com"]
    keyFile: main.asc
    fingerprint: "0000000000000000000000000000000000000000"
`
	path := filepath.Join(dir, "keys.yaml")
	if err := os.WriteFile(path, []byte(rules), 0o600); err != nil {
		t.Fatalf("write rules: %v", err)
	}

	if _, err := LoadRules(path); err == nil {
		t.Fatalf("LoadRules succeeded with mismatched fingerprint")
	}
}

func TestRulesRequireExactlyOneMatch(t *testing.T) {
	dir := t.TempDir()
	key, err := testkeys.Generate("Main", "main@example.com")
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.asc"), []byte(key.PublicArmored), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	rulesYAML := `rules:
  - match: ["*@example.com"]
    keyFile: main.asc
    fingerprint: "` + key.Fingerprint + `"
  - match: ["alias@example.com"]
    keyFile: main.asc
    fingerprint: "` + key.Fingerprint + `"
`
	path := filepath.Join(dir, "keys.yaml")
	if err := os.WriteFile(path, []byte(rulesYAML), 0o600); err != nil {
		t.Fatalf("write rules: %v", err)
	}
	rules, err := LoadRules(path)
	if err != nil {
		t.Fatalf("LoadRules returned error: %v", err)
	}

	if _, err := rules.MatchRecipient("nobody@elsewhere.test"); !errors.Is(err, ErrNoKey) {
		t.Fatalf("no match error = %v, want ErrNoKey", err)
	}
	if _, err := rules.MatchRecipient("alias@example.com"); !errors.Is(err, ErrMultipleKeys) {
		t.Fatalf("multiple match error = %v, want ErrMultipleKeys", err)
	}
}

func writeKeyRules(t *testing.T, dir, email string, matches []string, relayTo string) string {
	t.Helper()
	key, err := testkeys.Generate("Main", email)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.asc"), []byte(key.PublicArmored), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}

	rules := "rules:\n  - match:\n"
	for _, match := range matches {
		rules += "      - " + quote(match) + "\n"
	}
	rules += "    keyFile: main.asc\n"
	rules += "    fingerprint: " + quote(key.Fingerprint) + "\n"
	if relayTo != "" {
		rules += "    relayTo: " + quote(relayTo) + "\n"
	}

	path := filepath.Join(dir, "keys.yaml")
	if err := os.WriteFile(path, []byte(rules), 0o600); err != nil {
		t.Fatalf("write rules: %v", err)
	}
	return path
}

func quote(value string) string {
	return `"` + value + `"`
}
