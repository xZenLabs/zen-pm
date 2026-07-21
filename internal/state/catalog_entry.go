package state

type CatalogEntry struct {
	Repo                  string
	Priority              int
	ID                    string
	Name                  string
	Version               string
	Platforms             []string
	IncompatiblePlatforms []string
	Deps                  []string
	Conflicts             []string
	InstallURL            string
	UninstallURL          string
	Size                  string
	Description           string
	Author                string
	Tags                  []string
	IconURL               string
	RepoIconURL           string
	Images                []string
	Featured              bool
	FeaturedImage         string
	FeaturedOrder         *int
	Category              string
	Source                string
	SourceAsset           string
	SourceType            string
	SourceURL             string
	Stars                 string
	Assets                string
	Constraints           string
	PluginModule          string
	ReadmeURL             string
}
