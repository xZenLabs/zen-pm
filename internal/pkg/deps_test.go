package pkg

import (
	"strings"
	"testing"

	"github.com/xZenLabs/zen-pm/internal/repo"
)

func TestResolvePlanWithInstalledAllowsInstalledKUAL(t *testing.T) {
	catalog := []*repo.CatalogEntry{
		{ID: "zen-reader", Deps: []string{"kual"}},
	}

	plan, err := ResolvePlanWithInstalled("zen-reader", catalog, map[string]bool{"kual": true})
	if err != nil {
		t.Fatalf("ResolvePlanWithInstalled returned error: %v", err)
	}
	if len(plan) != 1 || plan[0] != "zen-reader" {
		t.Fatalf("plan = %#v, want []string{\"zen-reader\"}", plan)
	}
}

func TestResolvePlanWithInstalledDoesNotInstallCatalogKUALDependency(t *testing.T) {
	catalog := []*repo.CatalogEntry{
		{ID: "zen-reader", Deps: []string{"kual"}},
		{ID: "kual"},
	}

	plan, err := ResolvePlanWithInstalled("zen-reader", catalog, map[string]bool{"kual": true})
	if err != nil {
		t.Fatalf("ResolvePlanWithInstalled returned error: %v", err)
	}
	if len(plan) != 1 || plan[0] != "zen-reader" {
		t.Fatalf("plan = %#v, want []string{\"zen-reader\"}", plan)
	}
}

func TestResolvePlanWithInstalledRequiresKUAL(t *testing.T) {
	catalog := []*repo.CatalogEntry{
		{ID: "zen-reader", Deps: []string{"kual"}},
	}

	_, err := ResolvePlanWithInstalled("zen-reader", catalog, nil)
	if err == nil || !strings.Contains(err.Error(), `dependency "kual" is not installed`) {
		t.Fatalf("err = %v, want missing kual dependency", err)
	}
}

func TestResolvePlanWithInstalledKeepsUnknownDependencyError(t *testing.T) {
	catalog := []*repo.CatalogEntry{
		{ID: "zen-reader", Deps: []string{"missing"}},
	}

	_, err := ResolvePlanWithInstalled("zen-reader", catalog, map[string]bool{"missing": true})
	if err == nil || !strings.Contains(err.Error(), `unknown dependency "missing"`) {
		t.Fatalf("err = %v, want unknown dependency", err)
	}
}

func TestResolvePlanWithInstalledKeepsCatalogDependencies(t *testing.T) {
	catalog := []*repo.CatalogEntry{
		{ID: "zen-reader", Deps: []string{"helper"}},
		{ID: "helper"},
	}

	plan, err := ResolvePlanWithInstalled("zen-reader", catalog, nil)
	if err != nil {
		t.Fatalf("ResolvePlanWithInstalled returned error: %v", err)
	}
	if len(plan) != 2 || plan[0] != "helper" || plan[1] != "zen-reader" {
		t.Fatalf("plan = %#v, want helper before zen-reader", plan)
	}
}
