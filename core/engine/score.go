package engine

import (
	"math"
	"sort"
)

type Metrics struct {
	Attempts    int     `json:"attempts"`
	Successes   int     `json:"successes"`
	FailureRate float64 `json:"failureRate"`
	MedianMS    float64 `json:"medianMS"`
	P95MS       float64 `json:"p95MS"`
	JitterMS    float64 `json:"jitterMS"`
	Score       float64 `json:"score"`
	Confidence  float64 `json:"confidence"`
}

// Values <= 0 represent failed probes, never zero-millisecond successes.
func Summarize(samples []float64) Metrics {
	m := Metrics{Attempts: len(samples)}
	valid := []float64{}
	for _, v := range samples {
		if v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0) {
			valid = append(valid, v)
		}
	}
	m.Successes = len(valid)
	if m.Attempts == 0 {
		return m
	}
	p := float64(m.Successes) / float64(m.Attempts)
	m.FailureRate = 1 - p
	if len(valid) == 0 {
		return m
	}
	sort.Float64s(valid)
	m.MedianMS = percentile(valid, .5)
	m.P95MS = percentile(valid, .95)
	deviations := make([]float64, len(valid))
	for i, v := range valid {
		deviations[i] = math.Abs(v - m.MedianMS)
	}
	sort.Float64s(deviations)
	m.JitterMS = 1.4826 * percentile(deviations, .5) // robust standard deviation (MAD)
	// Wilson 95% lower bound: uncertainty is visible rather than treating one
	// successful sample as strong evidence of long-term reliability.
	n := float64(m.Attempts)
	z := 1.96
	m.Confidence = (p + z*z/(2*n) - z*math.Sqrt(p*(1-p)/n+z*z/(4*n*n))) / (1 + z*z/n)
	latency := math.Exp(-m.MedianMS / 250)
	tail := math.Exp(-m.P95MS / 450)
	jitter := math.Exp(-m.JitterMS / 80)
	m.Score = 100 * math.Pow(p, 3) * (.50*latency + .30*tail + .20*jitter) * (.70 + .30*m.Confidence)
	m.Score = math.Round(m.Score*10) / 10
	return m
}

func percentile(sorted []float64, q float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	x := float64(len(sorted)-1) * q
	low := int(x)
	high := int(math.Ceil(x))
	return sorted[low] + (sorted[high]-sorted[low])*(x-float64(low))
}
