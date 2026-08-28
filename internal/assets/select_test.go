package assets

import "testing"

const rakuyomiAssets = `[
  {"arch":"arm64","asset":"rakuyomi-aarch64.zip"},
  {"arch":"any","asset":"rakuyomi-android.zip"},
  {"arch":"any","asset":"rakuyomi-desktop.zip"},
  {"arch":"any","asset":"rakuyomi-macos.zip"},
  {"arch":"kindle","asset":"rakuyomi-kindle.zip"},
  {"arch":"kindle","asset":"rakuyomi-kindlesf.zip"},
  {"arch":"kindle","asset":"rakuyomi-kindlea9.zip"},
  {"arch":"kindle","asset":"rakuyomi-kindlehf.zip"}
]`

const zenFMAssets = `[
  {"asset":"ZenFM-koreader-android-1.0.1.zip"},
  {"asset":"ZenFM-koreader-ereader-1.0.1.zip"},
  {"asset":"ZenFM-koreader-linux-1.0.1.zip"},
  {"asset":"ZenFM-koreader-macos-1.0.1.zip"}
]`

func TestSelectKindleHardFloat(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "kindle", KindleHF: true})
	if r.NeedsChoice || r.Auto != "rakuyomi-kindlehf.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-kindlehf.zip", r)
	}
}

func TestSelectKindleSoftFloat(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "kindle"})
	if r.NeedsChoice || r.Auto != "rakuyomi-kindlesf.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-kindlesf.zip", r)
	}
}

func TestSelectKindleCortexA9(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "kindle", KindleHF: true, CortexA9: true})
	if r.NeedsChoice || r.Auto != "rakuyomi-kindlea9.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-kindlea9.zip", r)
	}
}

func TestSelectKoboUsesPlainKindle(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "kobo"})
	if r.NeedsChoice || r.Auto != "rakuyomi-kindle.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-kindle.zip", r)
	}
}

func TestSelectARM64KoboGetsRakuyomiAArch64(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "kobo", Arch: "arm64"})
	if r.NeedsChoice || r.Auto != "rakuyomi-aarch64.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-aarch64.zip", r)
	}
}

func TestSelectEReadersGetCombinedEReaderZip(t *testing.T) {
	for _, dev := range []Device{
		{Platform: "kindle"},
		{Platform: "kindle", KindleHF: true},
		{Platform: "kobo", Arch: "arm"},
		{Platform: "ereader", Arch: "arm"},
	} {
		r := Select(zenFMAssets, dev)
		if r.NeedsChoice || r.Auto != "ZenFM-koreader-ereader-1.0.1.zip" {
			t.Fatalf("%+v got %+v, want combined e-reader asset", dev, r)
		}
	}
}

func TestSelectLinuxHostGetsLinuxZip(t *testing.T) {
	r := Select(zenFMAssets, Device{Platform: "host", OS: "linux"})
	if r.NeedsChoice || r.Auto != "ZenFM-koreader-linux-1.0.1.zip" {
		t.Fatalf("got %+v, want Linux asset", r)
	}
}

func TestSelectARM64KoboGetsLinuxZip(t *testing.T) {
	r := Select(zenFMAssets, Device{Platform: "kobo", Arch: "arm64"})
	if r.NeedsChoice || r.Auto != "ZenFM-koreader-linux-1.0.1.zip" {
		t.Fatalf("got %+v, want Linux asset", r)
	}
}

func TestSelectAndroidGetsAndroidZip(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "android"})
	if r.NeedsChoice || r.Auto != "rakuyomi-android.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-android.zip", r)
	}
}

func TestSelectMacHostGetsMacOSZip(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "host", OS: "darwin"})
	if r.NeedsChoice || r.Auto != "rakuyomi-macos.zip" {
		t.Fatalf("got %+v, want auto rakuyomi-macos.zip", r)
	}
}

func TestSelectExcludesAndroidOnKindle(t *testing.T) {
	r := Select(rakuyomiAssets, Device{Platform: "kindle"})
	for _, c := range r.Candidates {
		if c.Asset == "rakuyomi-android.zip" {
			t.Fatal("android asset offered to kindle")
		}
	}
}

func TestSelectSingleAssetNoChoice(t *testing.T) {
	r := Select(`[{"asset":"only.koplugin.zip"}]`, Device{Platform: "kobo"})
	if r.NeedsChoice || r.Auto != "only.koplugin.zip" {
		t.Fatalf("got %+v, want auto only.koplugin.zip", r)
	}
}

func TestSelectEmptyAssets(t *testing.T) {
	r := Select("", Device{Platform: "kindle"})
	if r.Auto != "" || r.NeedsChoice {
		t.Fatalf("got %+v, want empty result", r)
	}
}

func TestSelectNeedsChoiceWhenAmbiguous(t *testing.T) {
	raw := `[{"asset":"foo-build-x.zip"},{"asset":"foo-build-y.zip"}]`
	r := Select(raw, Device{Platform: "kobo"})
	if !r.NeedsChoice || len(r.Candidates) != 2 {
		t.Fatalf("got %+v, want needs_choice with 2 candidates", r)
	}
}
