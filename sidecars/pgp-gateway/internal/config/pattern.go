package config

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

var (
	ErrNoKey        = errors.New("no matching encryption key")
	ErrMultipleKeys = errors.New("multiple matching encryption keys")
)

type Pattern struct {
	raw string
	re  *regexp.Regexp
}

func ParsePattern(raw string) (Pattern, error) {
	raw = strings.ToLower(strings.TrimSpace(raw))
	if raw == "" {
		return Pattern{}, fmt.Errorf("empty address pattern")
	}
	if strings.Count(raw, "@") != 1 {
		return Pattern{}, fmt.Errorf("invalid address pattern %q", raw)
	}

	var pattern strings.Builder
	pattern.WriteString("^")
	for _, r := range raw {
		switch r {
		case '*':
			pattern.WriteString(`.*`)
		default:
			pattern.WriteString(regexp.QuoteMeta(string(r)))
		}
	}
	pattern.WriteString("$")

	re, err := regexp.Compile(pattern.String())
	if err != nil {
		return Pattern{}, fmt.Errorf("compile address pattern %q: %w", raw, err)
	}
	return Pattern{raw: raw, re: re}, nil
}

func (p Pattern) Match(address string) bool {
	return p.re.MatchString(strings.ToLower(strings.TrimSpace(address)))
}

func (p Pattern) String() string {
	return p.raw
}
