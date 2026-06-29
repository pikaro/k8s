package config

import (
	"fmt"
	"net/mail"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	pgp "github.com/ProtonMail/gopenpgp/v3/crypto"
	"gopkg.in/yaml.v3"
)

const (
	DefaultListenAddr      = "127.0.0.1:2525"
	DefaultMetricsAddr     = ":9090"
	DefaultOuterSubject    = "Encrypted message"
	DefaultMaxMessageBytes = int64(25 * 1024 * 1024)
	DefaultSMTPHost        = "mail.smtp2go.com"
	DefaultSMTPPort        = 587
	DefaultSMTPTimeout     = 30 * time.Second
)

type Env map[string]string

type Config struct {
	ListenAddr      string
	MetricsAddr     string
	KeyRulesFile    string
	OuterSubject    string
	MaxMessageBytes int64
	SMTP            SMTPConfig
	Rules           Rules
}

type SMTPConfig struct {
	Host     string
	Port     int
	Username string
	Password string
	Timeout  time.Duration
}

func LoadFromEnv(env Env) (*Config, error) {
	cfg := &Config{
		ListenAddr:      get(env, "LISTEN_ADDR", DefaultListenAddr),
		MetricsAddr:     get(env, "METRICS_ADDR", DefaultMetricsAddr),
		KeyRulesFile:    strings.TrimSpace(env["PGP_KEY_RULES_FILE"]),
		OuterSubject:    get(env, "OUTER_SUBJECT", DefaultOuterSubject),
		MaxMessageBytes: DefaultMaxMessageBytes,
		SMTP: SMTPConfig{
			Host:     get(env, "SMTP_HOST", DefaultSMTPHost),
			Port:     DefaultSMTPPort,
			Username: strings.TrimSpace(env["SMTP_USERNAME"]),
			Password: env["SMTP_PASSWORD"],
			Timeout:  DefaultSMTPTimeout,
		},
	}

	if v := strings.TrimSpace(env["MAX_MESSAGE_BYTES"]); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			return nil, fmt.Errorf("MAX_MESSAGE_BYTES must be a positive integer")
		}
		cfg.MaxMessageBytes = n
	}

	if v := strings.TrimSpace(env["SMTP_PORT"]); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 || n > 65535 {
			return nil, fmt.Errorf("SMTP_PORT must be a valid TCP port")
		}
		cfg.SMTP.Port = n
	}

	if v := strings.TrimSpace(env["SMTP_TIMEOUT"]); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			return nil, fmt.Errorf("SMTP_TIMEOUT must be a positive duration")
		}
		cfg.SMTP.Timeout = d
	}

	if cfg.KeyRulesFile == "" {
		return nil, fmt.Errorf("PGP_KEY_RULES_FILE is required")
	}
	if cfg.SMTP.Username == "" {
		return nil, fmt.Errorf("SMTP_USERNAME is required")
	}
	if cfg.SMTP.Password == "" {
		return nil, fmt.Errorf("SMTP_PASSWORD is required")
	}
	if cfg.OuterSubject == "" {
		return nil, fmt.Errorf("OUTER_SUBJECT must not be empty")
	}

	rules, err := LoadRules(cfg.KeyRulesFile)
	if err != nil {
		return nil, err
	}
	cfg.Rules = rules
	return cfg, nil
}

func OS() Env {
	env := make(Env)
	for _, kv := range os.Environ() {
		k, v, ok := strings.Cut(kv, "=")
		if ok {
			env[k] = v
		}
	}
	return env
}

type RuleFile struct {
	Rules []RuleSpec `yaml:"rules"`
}

type RuleSpec struct {
	Match       []string `yaml:"match"`
	KeyFile     string   `yaml:"keyFile"`
	Fingerprint string   `yaml:"fingerprint"`
	RelayTo     string   `yaml:"relayTo"`
}

type Rule struct {
	Match       []Pattern
	KeyFile     string
	Fingerprint string
	RelayTo     string
	Key         *pgp.Key
}

type Rules []Rule

type Match struct {
	Rule      Rule
	Recipient string
	RelayTo   string
}

func LoadRules(path string) (Rules, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read key rules: %w", err)
	}
	var file RuleFile
	if err := yaml.Unmarshal(data, &file); err != nil {
		return nil, fmt.Errorf("parse key rules: %w", err)
	}
	if len(file.Rules) == 0 {
		return nil, fmt.Errorf("key rules must contain at least one rule")
	}

	base := filepath.Dir(path)
	rules := make(Rules, 0, len(file.Rules))
	for i, spec := range file.Rules {
		rule, err := loadRule(base, spec)
		if err != nil {
			return nil, fmt.Errorf("rule %d: %w", i, err)
		}
		rules = append(rules, rule)
	}
	return rules, nil
}

func (rules Rules) MatchRecipient(address string) (Match, error) {
	normalized, err := normalizeAddress(address)
	if err != nil {
		return Match{}, err
	}

	var matches []Rule
	for _, rule := range rules {
		for _, pattern := range rule.Match {
			if pattern.Match(normalized) {
				matches = append(matches, rule)
				break
			}
		}
	}
	if len(matches) == 0 {
		return Match{}, ErrNoKey
	}
	if len(matches) > 1 {
		return Match{}, ErrMultipleKeys
	}

	relayTo := matches[0].RelayTo
	if relayTo == "" {
		relayTo = normalized
	}
	return Match{Rule: matches[0], Recipient: normalized, RelayTo: relayTo}, nil
}

func loadRule(base string, spec RuleSpec) (Rule, error) {
	if len(spec.Match) == 0 {
		return Rule{}, fmt.Errorf("match must contain at least one address pattern")
	}
	if strings.TrimSpace(spec.KeyFile) == "" {
		return Rule{}, fmt.Errorf("keyFile is required")
	}
	if strings.TrimSpace(spec.Fingerprint) == "" {
		return Rule{}, fmt.Errorf("fingerprint is required")
	}

	patterns := make([]Pattern, 0, len(spec.Match))
	for _, raw := range spec.Match {
		pattern, err := ParsePattern(raw)
		if err != nil {
			return Rule{}, err
		}
		patterns = append(patterns, pattern)
	}

	keyFile := spec.KeyFile
	if !filepath.IsAbs(keyFile) {
		keyFile = filepath.Join(base, keyFile)
	}
	keyData, err := os.ReadFile(keyFile)
	if err != nil {
		return Rule{}, fmt.Errorf("read public key: %w", err)
	}
	key, err := pgp.NewKeyFromArmored(string(keyData))
	if err != nil {
		return Rule{}, fmt.Errorf("parse public key: %w", err)
	}

	expected := normalizeFingerprint(spec.Fingerprint)
	actual := normalizeFingerprint(key.GetFingerprint())
	if expected != actual {
		return Rule{}, fmt.Errorf("fingerprint mismatch: expected %s, got %s", expected, actual)
	}
	if !key.CanEncrypt(time.Now().Unix()) {
		return Rule{}, fmt.Errorf("public key cannot encrypt at current time")
	}

	relayTo := strings.TrimSpace(spec.RelayTo)
	if relayTo != "" {
		var err error
		relayTo, err = normalizeAddress(relayTo)
		if err != nil {
			return Rule{}, fmt.Errorf("relayTo: %w", err)
		}
	}

	return Rule{
		Match:       patterns,
		KeyFile:     keyFile,
		Fingerprint: actual,
		RelayTo:     relayTo,
		Key:         key,
	}, nil
}

func normalizeAddress(address string) (string, error) {
	parsed, err := mail.ParseAddress(strings.TrimSpace(address))
	if err != nil {
		return "", fmt.Errorf("invalid email address %q", address)
	}
	return strings.ToLower(parsed.Address), nil
}

func normalizeFingerprint(value string) string {
	value = strings.ReplaceAll(value, " ", "")
	value = strings.ReplaceAll(value, ":", "")
	return strings.ToLower(value)
}

func get(env Env, key, fallback string) string {
	if value := strings.TrimSpace(env[key]); value != "" {
		return value
	}
	return fallback
}
