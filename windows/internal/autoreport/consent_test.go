package autoreport

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"
)

type consentTransport func(*http.Request) (*http.Response, error)

func (f consentTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestOptOutDuringCollectionDiscardsTheResultAfterAnotherOptIn(t *testing.T) {
	var consent Consent
	first := consent.Replace("FIRST")
	collecting, collected, finished := make(chan struct{}), make(chan struct{}), make(chan bool, 1)
	go func() {
		close(collecting)
		<-collected // a system read that cannot itself be cancelled
		finished <- consent.With(first, func() { t.Error("old report or snapshot must not be saved") })
	}()
	<-collecting
	consent.Replace("")
	second := consent.Replace("SECOND")
	close(collected)
	if <-finished || consent.Valid(first) || !consent.Valid(second) {
		t.Fatal("only the new opt-in may send or persist anything")
	}
	if !errors.Is(first.Context().Err(), context.Canceled) {
		t.Fatal("the old transport context was not cancelled")
	}
}

func TestOptOutCancelsAnInFlightRequestAndStopsTheRetryQueue(t *testing.T) {
	var consent Consent
	session := consent.Replace("FIRST")
	started := make(chan struct{})
	var requests atomic.Int32
	client := &http.Client{Transport: consentTransport(func(r *http.Request) (*http.Response, error) {
		if requests.Add(1) == 1 {
			close(started)
		}
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	finished := make(chan struct{})
	var saved atomic.Bool
	go func() {
		defer close(finished)
		for range 2 {
			if !consent.Valid(session) {
				return
			}
			ctx, cancel := context.WithTimeout(session.Context(), 3*time.Second)
			req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "https://report.invalid/", nil)
			resp, _ := client.Do(req)
			cancel()
			if resp != nil {
				resp.Body.Close()
			}
			if !consent.With(session, func() { saved.Store(true) }) {
				return
			}
		}
	}()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("request did not start")
	}
	consent.Replace("")
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("opt-out did not cancel the request")
	}
	if requests.Load() != 1 || saved.Load() {
		t.Fatal("opt-out must prevent the next retry and queue recreation")
	}
}

func TestAPreviousPermitNeverRevivesEvenWithTheSameInstallationNumber(t *testing.T) {
	var consent Consent
	first := consent.Replace("SAME")
	consent.Replace("")
	second := consent.Replace("SAME")
	if consent.Valid(first) || !consent.Valid(second) {
		t.Fatal("consent is a session, not only an installation number")
	}
}
