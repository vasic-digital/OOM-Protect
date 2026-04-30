package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDefaults_SatisfiesValidate(t *testing.T) {
	t.Parallel()
	c := Defaults()
	if err := c.Validate(); err != nil {
		t.Fatalf("Defaults() failed Validate: %v", err)
	}
}

func TestLoad_PartialFileFillsDefaults(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "c.json")
	if err := os.WriteFile(path, []byte(`{"interval_seconds": 5}`), 0o644); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if c.IntervalSeconds != 5 {
		t.Errorf("IntervalSeconds = %d, want 5 (from file)", c.IntervalSeconds)
	}
	if c.Thresholds.MemoryUsedRatioCritical != 0.95 {
		t.Errorf("MemoryUsedRatioCritical = %.2f, want 0.95 (from defaults)", c.Thresholds.MemoryUsedRatioCritical)
	}
}

func TestLoad_RejectsUnknownFields(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	path := filepath.Join(dir, "c.json")
	if err := os.WriteFile(path, []byte(`{"unknown_typo": 1}`), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil {
		t.Fatal("expected error on unknown field, got nil")
	}
	if !strings.Contains(err.Error(), "unknown") && !strings.Contains(err.Error(), "field") {
		t.Errorf("error %q should mention unknown field", err)
	}
}

func TestValidate_ThresholdOrdering(t *testing.T) {
	t.Parallel()
	c := Defaults()
	c.Thresholds.MemoryUsedRatioWarn = 0.99
	c.Thresholds.MemoryUsedRatioCritical = 0.50
	if err := c.Validate(); err == nil {
		t.Error("expected ordering error when warn > critical, got nil")
	}
}

func TestValidate_CriticalCannotBeOne(t *testing.T) {
	t.Parallel()
	c := Defaults()
	c.Thresholds.MemoryUsedRatioCritical = 1.0
	if err := c.Validate(); err == nil {
		t.Error("expected error when critical == 1.0, got nil")
	}
}

func TestValidate_IntervalBounds(t *testing.T) {
	t.Parallel()
	c := Defaults()
	c.IntervalSeconds = 0
	if err := c.Validate(); err == nil {
		t.Error("expected error on interval=0")
	}
	c.IntervalSeconds = 1000
	if err := c.Validate(); err == nil {
		t.Error("expected error on interval=1000")
	}
}
