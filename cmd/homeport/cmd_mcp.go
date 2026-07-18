package main

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// cmdMCP serves the Homeport CLI over MCP (stdio), turning any MCP client
// (Claude Code, agents) into a fleet operator. Tools shell out to this same
// binary with captured output, so agents see exactly what a human would —
// same validation, same health-gated activation, same auto-revert safety.
//
// Register with e.g.:  claude mcp add homeport -- homeport mcp
//
// Scope: project — tools operate on the homeport.yaml in the working
// directory the server was started in, same as the CLI itself.
func cmdMCP(args []string) error {
	_ = args
	server := mcp.NewServer(
		&mcp.Implementation{Name: "homeport", Title: "Homeport", Version: version},
		&mcp.ServerOptions{
			Instructions: "Homeport deploys single-binary web apps to a VPS. " +
				"These tools operate on the app defined by homeport.yaml in the server's working directory. " +
				"Deploys are health-gated and auto-revert on failure; rollbacks are instant. " +
				"Setup commands (init, bootstrap, ci) are intentionally not exposed — humans run those.",
		},
	)

	type statusArgs struct{}
	mcp.AddTool(server, &mcp.Tool{
		Name: "status",
		Description: "Current state of the app: systemd state, domain, port, live release, " +
			"and all rollback-eligible releases. Returns JSON.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args statusArgs) (*mcp.CallToolResult, any, error) {
		return selfExec(ctx, 60*time.Second, "status", "--json")
	})

	type deployArgs struct {
		NoBuild bool `json:"no_build,omitempty" jsonschema:"skip the build step and upload the existing artifact"`
	}
	mcp.AddTool(server, &mcp.Tool{
		Name: "deploy",
		Description: "Build the app, upload the binary, and activate it. Activation health-checks the " +
			"new release and automatically reverts to the previous one on failure — the result text " +
			"states which release is live. Can take several minutes (build + upload).",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args deployArgs) (*mcp.CallToolResult, any, error) {
		cmdArgs := []string{"deploy"}
		if args.NoBuild {
			cmdArgs = append(cmdArgs, "--no-build")
		}
		return selfExec(ctx, 20*time.Minute, cmdArgs...)
	})

	type rollbackArgs struct {
		Release string `json:"release,omitempty" jsonschema:"release id to activate; omit for the previous release"`
	}
	mcp.AddTool(server, &mcp.Tool{
		Name: "rollback",
		Description: "Instantly activate the previous release (or a specific one from status.releases). " +
			"Health-gated like a deploy.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args rollbackArgs) (*mcp.CallToolResult, any, error) {
		cmdArgs := []string{"rollback"}
		if args.Release != "" {
			cmdArgs = append(cmdArgs, args.Release)
		}
		return selfExec(ctx, 5*time.Minute, cmdArgs...)
	})

	type logsArgs struct {
		Lines int `json:"lines,omitempty" jsonschema:"number of recent log lines (default 100)"`
	}
	mcp.AddTool(server, &mcp.Tool{
		Name:        "logs",
		Description: "Recent app logs from journald (most recent last).",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args logsArgs) (*mcp.CallToolResult, any, error) {
		cmdArgs := []string{"logs"}
		if args.Lines > 0 {
			cmdArgs = append(cmdArgs, "-n", strconv.Itoa(args.Lines))
		}
		return selfExec(ctx, 60*time.Second, cmdArgs...)
	})

	type statsArgs struct{}
	mcp.AddTool(server, &mcp.Tool{
		Name:        "stats",
		Description: "Live resource usage: app memory (current/peak), cpu time, tasks, releases disk, host memory and disk.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args statsArgs) (*mcp.CallToolResult, any, error) {
		return selfExec(ctx, 60*time.Second, "stats")
	})

	type secretsListArgs struct{}
	mcp.AddTool(server, &mcp.Tool{
		Name:        "secrets_list",
		Description: "List the app's env keys and value lengths. Values never leave the server.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args secretsListArgs) (*mcp.CallToolResult, any, error) {
		return selfExec(ctx, 60*time.Second, "secrets", "list")
	})

	type secretsSetArgs struct {
		Values map[string]string `json:"values" jsonschema:"env values to set or update, e.g. {\"API_URL\": \"https://...\"}"`
	}
	mcp.AddTool(server, &mcp.Tool{
		Name: "secrets_set",
		Description: "Set or update env values on the server (merges; restarts the app if running). " +
			"NOTE: values passed here transit the model context — prefer `homeport secrets push` " +
			"run by a human for high-sensitivity credentials.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args secretsSetArgs) (*mcp.CallToolResult, any, error) {
		if len(args.Values) == 0 {
			return errResult("no values given"), nil, nil
		}
		cmdArgs := []string{"secrets", "set"}
		keys := make([]string, 0, len(args.Values))
		for k := range args.Values {
			keys = append(keys, k)
		}
		sort.Strings(keys) // deterministic order
		for _, k := range keys {
			cmdArgs = append(cmdArgs, k+"="+args.Values[k])
		}
		return selfExec(ctx, 60*time.Second, cmdArgs...)
	})

	type secretsRmArgs struct {
		Keys []string `json:"keys" jsonschema:"env keys to remove, e.g. [\"OLD_FLAG\"]"`
	}
	mcp.AddTool(server, &mcp.Tool{
		Name:        "secrets_rm",
		Description: "Remove env keys from the server (restarts the app if running).",
	}, func(ctx context.Context, req *mcp.CallToolRequest, args secretsRmArgs) (*mcp.CallToolResult, any, error) {
		if len(args.Keys) == 0 {
			return errResult("no keys given"), nil, nil
		}
		return selfExec(ctx, 60*time.Second, append([]string{"secrets", "rm"}, args.Keys...)...)
	})

	// EOF on stdin is the normal client-initiated shutdown, not a failure.
	if err := server.Run(context.Background(), &mcp.StdioTransport{}); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	return nil
}

var ansiRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

// toolMu serializes tool execution. The MCP SDK dispatches tool calls
// concurrently, but fleet operations must not interleave — a status racing
// a rollback reads stale state, and parallel deploys would fight over the
// release symlink. Agents get sequential, predictable ops.
var toolMu sync.Mutex

// selfExec runs this same binary with the given args, capturing everything.
// Exit != 0 becomes an isError result carrying the CLI's own message —
// which is already written to be actionable.
func selfExec(ctx context.Context, timeout time.Duration, args ...string) (*mcp.CallToolResult, any, error) {
	toolMu.Lock()
	defer toolMu.Unlock()

	self, err := os.Executable()
	if err != nil {
		return nil, nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, self, args...)
	out, runErr := cmd.CombinedOutput()
	text := ansiRe.ReplaceAllString(string(out), "")
	if runErr != nil {
		if text == "" {
			text = runErr.Error()
		}
		return errResult(text), nil, nil
	}
	if text == "" {
		text = "(ok — no output)"
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
	}, nil, nil
}

func errResult(text string) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		IsError: true,
		Content: []mcp.Content{&mcp.TextContent{Text: text}},
	}
}
