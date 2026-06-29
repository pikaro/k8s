package metrics

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	ReasonNoKey           = "no_key"
	ReasonMultipleKeys    = "multiple_keys"
	ReasonPolicy          = "policy"
	ReasonMalformed       = "malformed"
	ReasonOversize        = "oversize"
	ReasonEncryptionError = "encryption_error"
)

type Recorder struct {
	received    prometheus.Counter
	encrypted   prometheus.Counter
	refused     *prometheus.CounterVec
	relayed     prometheus.Counter
	relayFailed prometheus.Counter
}

func New(reg prometheus.Registerer) *Recorder {
	if reg == nil {
		reg = prometheus.DefaultRegisterer
	}

	r := &Recorder{
		received: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "pgp_gateway_messages_received_total",
			Help: "Messages accepted from Maddy after DATA.",
		}),
		encrypted: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "pgp_gateway_messages_encrypted_total",
			Help: "Messages successfully encrypted as PGP/MIME.",
		}),
		refused: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "pgp_gateway_messages_refused_total",
			Help: "Messages refused before relaying, by reason.",
		}, []string{"reason"}),
		relayed: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "pgp_gateway_messages_relayed_total",
			Help: "Encrypted messages accepted by the upstream SMTP relay.",
		}),
		relayFailed: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "pgp_gateway_messages_relay_failed_total",
			Help: "Encrypted messages rejected by or not delivered to the upstream SMTP relay.",
		}),
	}

	reg.MustRegister(r.received, r.encrypted, r.refused, r.relayed, r.relayFailed)
	for _, reason := range []string{
		ReasonNoKey,
		ReasonMultipleKeys,
		ReasonPolicy,
		ReasonMalformed,
		ReasonOversize,
		ReasonEncryptionError,
	} {
		r.refused.WithLabelValues(reason)
	}
	return r
}

func (r *Recorder) IncReceived() {
	if r != nil {
		r.received.Inc()
	}
}

func (r *Recorder) IncEncrypted() {
	if r != nil {
		r.encrypted.Inc()
	}
}

func (r *Recorder) IncRefused(reason string) {
	if r != nil {
		r.refused.WithLabelValues(reason).Inc()
	}
}

func (r *Recorder) IncRelayed() {
	if r != nil {
		r.relayed.Inc()
	}
}

func (r *Recorder) IncRelayFailed() {
	if r != nil {
		r.relayFailed.Inc()
	}
}

func Handler(reg *prometheus.Registry) http.Handler {
	if reg == nil {
		return promhttp.Handler()
	}
	return promhttp.HandlerFor(reg, promhttp.HandlerOpts{})
}
