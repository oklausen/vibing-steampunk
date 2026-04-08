package adt

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
)

// newFeatureTestProber creates a FeatureProber backed by a mock HTTP client.
// The mock maps URL paths to HTTP responses.
func newFeatureTestProber(responses map[string]*http.Response, config FeatureConfig) *FeatureProber {
	mock := &mockTransportClient{
		responses: responses,
	}
	cfg := NewConfig("https://sap.example.com:44300", "user", "pass")
	transport := NewTransportWithClient(cfg, mock)
	client := NewClientWithTransport(cfg, transport)
	return NewFeatureProber(client, config, false)
}

func newStatusResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     http.Header{"X-Csrf-Token": []string{"test-token"}},
	}
}

func TestEndpointExists_200(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/test/endpoint": newStatusResponse(200, "OK"),
		"discovery":                 newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	exists, msg, err := p.endpointExists(context.Background(), "/sap/bc/adt/test/endpoint")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !exists {
		t.Errorf("expected endpoint to exist, got false (msg=%s)", msg)
	}
}

func TestEndpointExists_400_TreatedAsExists(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/test/endpoint": newStatusResponse(400, `<?xml version="1.0" encoding="utf-8"?><exc:exception xmlns:exc="http://www.sap.com/abapxml/types/communicationframework"><message>HTTP method OPTIONS not supported</message></exc:exception>`),
		"discovery":                 newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	exists, _, err := p.endpointExists(context.Background(), "/sap/bc/adt/test/endpoint")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !exists {
		t.Error("expected 400 to be treated as 'endpoint exists'")
	}
}

func TestEndpointExists_404_NotFound(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/test/endpoint": newStatusResponse(404, "Not Found"),
		"discovery":                 newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	exists, _, err := p.endpointExists(context.Background(), "/sap/bc/adt/test/endpoint")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if exists {
		t.Error("expected 404 to mean endpoint does not exist")
	}
}

func TestEndpointExists_405_TreatedAsExists(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/test/endpoint": newStatusResponse(405, "Method Not Allowed"),
		"discovery":                 newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	exists, _, err := p.endpointExists(context.Background(), "/sap/bc/adt/test/endpoint")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !exists {
		t.Error("expected 405 to be treated as 'endpoint exists'")
	}
}

func TestEndpointExists_403_NotAvailable(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/test/endpoint": newStatusResponse(403, "Forbidden"),
		"discovery":                 newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	exists, msg, err := p.endpointExists(context.Background(), "/sap/bc/adt/test/endpoint")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if exists {
		t.Error("expected 403 to mean endpoint not available for current user")
	}
	if !strings.Contains(msg, "forbidden") {
		t.Errorf("expected message to mention forbidden, got: %s", msg)
	}
}

func TestProbeRAP_Available(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/ddic/ddl/sources": newStatusResponse(400, `<?xml version="1.0"?><exc:exception xmlns:exc="http://www.sap.com/abapxml/types/communicationframework"><message>bad request</message></exc:exception>`),
		"discovery":                    newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	available, msg, err := p.probeRAP(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !available {
		t.Errorf("expected RAP to be available (msg=%s)", msg)
	}
}

func TestProbeRAP_NotAvailable(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/ddic/ddl/sources": newStatusResponse(404, "Not Found"),
		"discovery":                    newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	available, _, err := p.probeRAP(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if available {
		t.Error("expected RAP to not be available on 404")
	}
}

func TestProbeTransport_Available(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/cts/transports": newStatusResponse(400, `<?xml version="1.0"?><exc:exception xmlns:exc="http://www.sap.com/abapxml/types/communicationframework"><message>bad request</message></exc:exception>`),
		"discovery":                  newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	available, msg, err := p.probeTransport(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !available {
		t.Errorf("expected Transport to be available (msg=%s)", msg)
	}
}

func TestProbeUI5_NotAvailable(t *testing.T) {
	p := newFeatureTestProber(map[string]*http.Response{
		"/sap/bc/adt/filestore/ui5-bsp": newStatusResponse(404, "Not Found"),
		"discovery":                     newStatusResponse(200, "OK"),
	}, DefaultFeatureConfig())

	available, _, err := p.probeUI5(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if available {
		t.Error("expected UI5 to not be available on 404")
	}
}

func TestFeatureMode_ForcedOn(t *testing.T) {
	config := DefaultFeatureConfig()
	config.RAP = FeatureModeOn

	p := newFeatureTestProber(map[string]*http.Response{
		"discovery": newStatusResponse(200, "OK"),
	}, config)

	status := p.Probe(context.Background(), FeatureRAP)
	if !status.Available {
		t.Error("expected forced-on feature to be available")
	}
	if status.Message != "forced enabled" {
		t.Errorf("expected 'forced enabled' message, got: %s", status.Message)
	}
}

func TestFeatureMode_ForcedOff(t *testing.T) {
	config := DefaultFeatureConfig()
	config.Transport = FeatureModeOff

	p := newFeatureTestProber(map[string]*http.Response{
		"discovery": newStatusResponse(200, "OK"),
	}, config)

	status := p.Probe(context.Background(), FeatureTransport)
	if status.Available {
		t.Error("expected forced-off feature to not be available")
	}
	if status.Message != "forced disabled" {
		t.Errorf("expected 'forced disabled' message, got: %s", status.Message)
	}
}

func TestFeatureProbe_Caching(t *testing.T) {
	config := DefaultFeatureConfig()
	config.RAP = FeatureModeOn

	p := newFeatureTestProber(map[string]*http.Response{
		"discovery": newStatusResponse(200, "OK"),
	}, config)

	// First probe
	status1 := p.Probe(context.Background(), FeatureRAP)
	// Second probe should return cached result
	status2 := p.Probe(context.Background(), FeatureRAP)

	if status1 != status2 {
		t.Error("expected cached probe to return same pointer")
	}
}
