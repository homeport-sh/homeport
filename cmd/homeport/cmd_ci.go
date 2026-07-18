package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const workflowPath = ".github/workflows/homeport-deploy.yml"

// cmdCI wires a pipeline deploy: a dedicated ed25519 key authorized on the
// server, the host key pinned (no StrictHostKeyChecking=no), and a GitHub
// Actions workflow. The pipeline needs exactly one secret pair — app
// secrets already live on the server, not in CI.
func cmdCI(args []string) error {
	if len(args) < 1 || args[0] != "setup" {
		return fmt.Errorf("usage: homeport ci setup github")
	}
	provider := "github"
	if len(args) > 1 {
		provider = args[1]
	}
	if provider != "github" {
		return fmt.Errorf("only github is supported for now (got %q)", provider)
	}
	cfg, err := loadConfig()
	if err != nil {
		return err
	}

	// 1. dedicated CI keypair — never your personal key
	tmp, err := os.MkdirTemp("", "homeport-ci-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	keyPath := filepath.Join(tmp, "ci_key")
	step("generating a dedicated CI deploy key")
	if err := run(nil, "ssh-keygen", "-t", "ed25519", "-N", "", "-C", "homeport-ci-"+cfg.App, "-f", keyPath, "-q"); err != nil {
		return fmt.Errorf("ssh-keygen failed: %w", err)
	}
	pub, err := os.ReadFile(keyPath + ".pub")
	if err != nil {
		return err
	}
	priv, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}

	// 2. authorize it on the server (over your existing access)
	step("authorizing the CI key on %s", cfg.Server)
	if err := sshRunIn(cfg.Server, cfg.homeportd("key-add"), string(pub)); err != nil {
		return fmt.Errorf("could not authorize CI key: %w", err)
	}

	// 3. pin the host key so CI never has to trust-on-first-use
	step("pinning the server host key")
	out, err := exec.Command("ssh-keyscan", "-t", "ed25519", cfg.host()).Output()
	if err != nil {
		return fmt.Errorf("ssh-keyscan failed: %w", err)
	}
	var hostKeys []string
	for _, line := range strings.Split(string(out), "\n") {
		if line != "" && !strings.HasPrefix(line, "#") {
			hostKeys = append(hostKeys, line)
		}
	}
	if len(hostKeys) == 0 {
		return fmt.Errorf("ssh-keyscan returned no host key for %s", cfg.host())
	}
	hostKey := strings.Join(hostKeys, "\n")

	// 4. workflow file
	if _, err := os.Stat(workflowPath); err == nil && !hasFlag(args, "--force") {
		step("%s already exists — leaving it untouched", workflowPath)
	} else {
		if err := os.MkdirAll(filepath.Dir(workflowPath), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(workflowPath, []byte(workflowYAML(detectProject())), 0o644); err != nil {
			return err
		}
		step("wrote %s", workflowPath)
	}

	// 5. hand the two secrets to GitHub — via gh if present, else print
	if _, lookErr := exec.LookPath("gh"); lookErr == nil {
		step("setting repo secrets via gh")
		if err := run(strings.NewReader(string(priv)), "gh", "secret", "set", "HOMEPORT_SSH_KEY"); err != nil {
			return fmt.Errorf("gh secret set HOMEPORT_SSH_KEY failed: %w", err)
		}
		if err := run(strings.NewReader(hostKey), "gh", "secret", "set", "HOMEPORT_HOST_KEY"); err != nil {
			return fmt.Errorf("gh secret set HOMEPORT_HOST_KEY failed: %w", err)
		}
		step("done — push to main and the pipeline deploys")
		return nil
	}

	fmt.Printf(`
gh CLI not found — add these two repository secrets by hand
(GitHub → Settings → Secrets and variables → Actions):

HOMEPORT_SSH_KEY
-------------
%s
HOMEPORT_HOST_KEY
--------------
%s

Then push to main and the pipeline deploys.
`, string(priv), hostKey)
	return nil
}

func workflowYAML(det projectInfo) string {
	toolchain := det.ciToolchain
	if toolchain == "" {
		toolchain = "      # TODO: install whatever toolchain `build.command` in homeport.yaml needs"
	}
	return `name: homeport deploy
on:
  push:
    branches: [main]

# never let two deploys race for the same box
concurrency: homeport-deploy

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
` + toolchain + `

      - name: Install homeport
        run: go install github.com/homeport-sh/homeport/cmd/homeport@latest

      - name: Deploy key
        run: |
          mkdir -p ~/.ssh
          printf '%s\n' "${{ secrets.HOMEPORT_SSH_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
          printf '%s\n' "${{ secrets.HOMEPORT_HOST_KEY }}" >> ~/.ssh/known_hosts

      # ── App secrets — managed here as GitHub Actions secrets, synced every
      # deploy (declarative: the box's env becomes EXACTLY this list, so a
      # secret you delete here is dropped on the box). Add each in the repo:
      # Settings → Secrets and variables → Actions.
      #
      # ⚠️  EDIT the list below to your real keys, and add every one as a repo
      #     secret BEFORE pushing — an unset ${{ secrets.X }} renders empty and
      #     would set that var blank. List ALL your app's env vars here (sync
      #     drops anything not listed). Prefer 'push -' over 'sync -' if you
      #     want additive/no-delete behaviour instead.
      - name: Sync secrets
        run: |
          cat <<'EOF' | homeport secrets sync -
          DATABASE_URL=${{ secrets.DATABASE_URL }}
          EOF

      # Alternative — secrets managed on the server instead of in CI: set them
      # once by hand ('homeport secrets push .env'); they persist across
      # deploys and CI never sees them. If you use that model, delete the
      # "Sync secrets" step above entirely.

      - name: Deploy
        run: homeport deploy
`
}
