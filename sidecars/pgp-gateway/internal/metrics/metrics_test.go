package metrics

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func TestRecorderCounters(t *testing.T) {
	reg := prometheus.NewRegistry()
	rec := New(reg)

	rec.IncReceived()
	rec.IncEncrypted()
	rec.IncRefused(ReasonNoKey)
	rec.IncRelayed()
	rec.IncRelayFailed()

	got := gather(t, reg)
	assertCounter(t, got, "pgp_gateway_messages_received_total", nil, 1)
	assertCounter(t, got, "pgp_gateway_messages_encrypted_total", nil, 1)
	assertCounter(t, got, "pgp_gateway_messages_relayed_total", nil, 1)
	assertCounter(t, got, "pgp_gateway_messages_relay_failed_total", nil, 1)
	assertCounter(t, got, "pgp_gateway_messages_refused_total", map[string]string{"reason": ReasonNoKey}, 1)
	assertCounter(t, got, "pgp_gateway_messages_refused_total", map[string]string{"reason": ReasonMultipleKeys}, 0)
}

func gather(t *testing.T, reg *prometheus.Registry) map[string]*dto.MetricFamily {
	t.Helper()
	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather metrics: %v", err)
	}
	got := make(map[string]*dto.MetricFamily, len(families))
	for _, family := range families {
		got[family.GetName()] = family
	}
	return got
}

func assertCounter(t *testing.T, got map[string]*dto.MetricFamily, name string, labels map[string]string, value float64) {
	t.Helper()
	family := got[name]
	if family == nil {
		t.Fatalf("metric %s not found", name)
	}
	for _, metric := range family.Metric {
		if labelsMatch(metric, labels) {
			if metric.Counter == nil {
				t.Fatalf("metric %s is not a counter", name)
			}
			if metric.Counter.GetValue() != value {
				t.Fatalf("%s%v = %v, want %v", name, labels, metric.Counter.GetValue(), value)
			}
			return
		}
	}
	t.Fatalf("metric %s with labels %v not found", name, labels)
}

func labelsMatch(metric *dto.Metric, want map[string]string) bool {
	got := make(map[string]string, len(metric.Label))
	for _, label := range metric.Label {
		got[label.GetName()] = label.GetValue()
	}
	if len(got) != len(want) {
		return false
	}
	for key, value := range want {
		if got[key] != value {
			return false
		}
	}
	return true
}
