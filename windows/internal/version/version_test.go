package version

import (
	"encoding/json"
	"os"
	"testing"
)

func TestWindowMetadataMatchesRuntimeVersion(t *testing.T) {
	raw, err := os.ReadFile("../../cmd/nimb/wails.json")
	if err != nil {
		t.Fatal(err)
	}
	var config struct {
		Info struct {
			ProductVersion string `json:"productVersion"`
		} `json:"info"`
	}
	if err := json.Unmarshal(raw, &config); err != nil {
		t.Fatal(err)
	}
	if config.Info.ProductVersion != Version {
		t.Fatalf("wails.json version %q differs from application/service %q", config.Info.ProductVersion, Version)
	}
}
