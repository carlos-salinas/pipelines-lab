package cel

import (
	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/metrics"
)

var (
	// celEvaluationsTotal tracks the total number of CEL evaluations
	celEvaluationsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "tekton_kueue_cel_evaluations_total",
			Help: "Total number of CEL evaluations",
		},
		[]string{"result"}, // result can be "success" or "failure"
	)

	// celMutationsTotal tracks the total number of CEL mutation operations
	celMutationsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "tekton_kueue_cel_mutations_total",
			Help: "Total number of CEL mutation operations applied to PipelineRuns",
		},
		[]string{"result"}, // result: "success" or "failure"
	)
)

func init() {
	// Register the metrics with controller-runtime's global registry
	metrics.Registry.MustRegister(celEvaluationsTotal)
	metrics.Registry.MustRegister(celMutationsTotal)
}

// RecordEvaluationFailure increments the counter for CEL evaluation failures
func RecordEvaluationFailure() {
	celEvaluationsTotal.WithLabelValues("failure").Inc()
}

// RecordEvaluationSuccess increments the counter for successful CEL evaluations
func RecordEvaluationSuccess() {
	celEvaluationsTotal.WithLabelValues("success").Inc()
}

// RecordMutationFailure increments the counter for CEL mutation failures
func RecordMutationFailure() {
	celMutationsTotal.WithLabelValues("failure").Inc()
}

// RecordMutationSuccess increments the counter for successful CEL mutations
func RecordMutationSuccess() {
	celMutationsTotal.WithLabelValues("success").Inc()
}
