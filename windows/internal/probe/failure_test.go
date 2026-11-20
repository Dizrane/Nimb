package probe

import (
	"strings"
	"testing"

	"github.com/Dizrane/Nimb/windows/internal/dnsx"
)

func TestFailureDetailsSeparateDNSHTTPSAndServiceRefusals(t *testing.T) {
	target := All[0]
	r := ProviderReport{Provider: dnsx.Available()[0], Samples: []Sample{
		{Target: target, Outcome: Outcome{Status: Failed, Reason: "DNS: не получен IPv4-адрес"}},
		{Target: target, Address: "203.0.113.1", Outcome: Outcome{Status: Failed, Reason: "TLS: ошибка проверки сертификата"}},
		{Target: target, Address: "203.0.113.2", Outcome: Outcome{Status: Blocked, Reason: "403: доступ закрыт"}},
	}}
	if len(r.Failures()) != 2 || len(r.Refusals()) != 1 {
		t.Fatalf("failures=%v refusals=%v", r.Failures(), r.Refusals())
	}
	if !strings.Contains(r.Details(), "DNS:") || !strings.Contains(r.Details(), "TLS:") {
		t.Fatal(r.Details())
	}
	if strings.Contains(strings.Join(r.Failures(), "\n"), "403") {
		t.Fatal("service refusal presented as a transport failure")
	}
	if len(r.View().Failures) != 2 || !strings.Contains(strings.Join(Lines([]ProviderReport{r}), "\n"), "TLS:") {
		t.Fatal("failure details missing from UI or diagnostic report")
	}
}
