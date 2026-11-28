package antigravity_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestOfflinePackageAndInspect(t *testing.T) {
	bcnBin := resolveBCNBin(t)
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	pluginZip := filepath.Join(tmp, "harness-antigravity.zip")

	entries := packagePluginDir(t, "..", pluginZip)
	if len(entries) == 0 {
		t.Fatal("packaged plugin.zip has no entries")
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry, "tests/") || strings.HasPrefix(entry, ".") {
			t.Fatalf("unexpected non-runtime file leaked into plugin.zip: %s", entry)
		}
	}

	insp := runBCN(t, bcnBin, homeDir, nil, "plugin", "inspect", "--dry-run", pluginZip)
	if !strings.Contains(insp, "harness-antigravity") {
		t.Fatalf("expected harness-antigravity in inspect output:\n%s", insp)
	}
	installPluginZip(t, bcnBin, homeDir, pluginZip)
}

func TestOfflineFakeCLIE2E(t *testing.T) {
	bcnBin := resolveBCNBin(t)
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	agyHome := filepath.Join(tmp, "agy-home")
	mcpToolDir := filepath.Join(agyHome, ".gemini", "antigravity-cli", "mcp", "test")
	if err := os.MkdirAll(mcpToolDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(mcpToolDir, "get_value.json"),
		[]byte(`{"name":"get_value","description":"Return a fixed value for a test key."}`+"\n"),
		0o644,
	); err != nil {
		t.Fatal(err)
	}

	fakeCLI := buildGoBinary(t, filepath.Join("fixtures", "fakecli"), filepath.Join(tmp, "fake-agy"))
	pluginZip := filepath.Join(tmp, "harness-antigravity.zip")
	channelZip := filepath.Join(tmp, "channel-e2e.zip")
	packagePluginDir(t, "..", pluginZip)
	packagePluginDir(t, filepath.Join("fixtures", "channel"), channelZip)

	installPluginZip(t, bcnBin, homeDir, pluginZip)
	installPluginZip(t, bcnBin, homeDir, channelZip)
	patchReceiptOverrides(t, homeDir, "harness-antigravity", receiptOverrides{
		ExecOverrides: map[string]string{"agy": fakeCLI},
	})

	chSrv := newE2EChannelServer()
	defer chSrv.Close()

	const agentID = "assistant"
	writeAgyNodeConfig(t, homeDir, agyConfigOptions{
		AgentID:     agentID,
		ChannelURL:  chSrv.URL(),
		Mode:        "session",
		Sandbox:     "workspace-write",
		IdleTimeout: 0,
		Model:       "fake-agy-1",
		Effort:      "low",
	})

	env := map[string]string{
		"HOME":        agyHome,
		"USERPROFILE": agyHome,
	}

	// 1. Offline bcn agent inspect against fake agy CLI + local MCP tool schema cache.
	inspectOut := runBCN(t, bcnBin, homeDir, env, "agent", "inspect", agentID)
	for _, want := range []string{"harness-antigravity", "true", "1.5.16"} {
		if !strings.Contains(inspectOut, want) {
			t.Fatalf("expected %q in bcn agent inspect output:\n%s", want, inspectOut)
		}
	}

	// 2. Live bcn run turn with approval prompt -> real injected `bcc message send` -> clean shutdown.
	artDir := artifactDir(t, "offline-antigravity")
	node := startBCNNode(t, bcnBin, homeDir, env, filepath.Join(artDir, "node.log"))
	defer func() {
		node.dumpEventsToFile(filepath.Join(artDir, "audit.jsonl"))
		_ = node.Stop()
	}()

	if _, err := node.waitEvent(20*time.Second, 0, func(ev auditEvent) bool {
		return ev.Type == "channel.connected" && ev.PluginID == "channel-e2e"
	}); err != nil {
		t.Fatalf("wait channel.connected: %v\nlog:\n%s", err, node.LogText())
	}

	reports, err := node.inspectHarnesses(agentID)
	if err != nil || len(reports) != 1 || !reports[0].Result.Available || reports[0].Result.Version != "1.5.16" {
		t.Fatalf("unexpected online agents.inspect report: reports=%+v err=%v", reports, err)
	}
	hasModel, hasMCPTool := false, false
	for _, m := range reports[0].Result.Models {
		if m.ID == "fake-agy-1" {
			hasModel = true
		}
	}
	for _, s := range reports[0].Result.MCPServers {
		if s.Name == "test" {
			for _, tool := range s.Tools {
				if tool.Name == "get_value" {
					hasMCPTool = true
				}
			}
		}
	}
	if !hasModel || !hasMCPTool {
		t.Fatalf("expected model fake-agy-1 and MCP test/get_value in agents.inspect: %+v", reports[0].Result)
	}

	chSrv.PushDM("offline-msg-1", "Please say hello via bcc.")
	approveDeadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(approveDeadline) {
		if node.approvePendingReviews(agentID) > 0 {
			break
		}
		time.Sleep(150 * time.Millisecond)
	}

	if _, err := node.waitEvent(30*time.Second, 0, func(ev auditEvent) bool {
		return ev.Type == "harness.turn_completed" && ev.PluginID == "harness-antigravity"
	}); err != nil {
		t.Fatalf("wait harness.turn_completed: %v\nlog:\n%s", err, node.LogText())
	}

	if chSrv.PromptsCount() == 0 {
		t.Fatalf("expected at least one interactive approval prompt in workspace-write mode")
	}
	outs := chSrv.OutboundSince(0)
	foundReply := false
	for _, m := range outs {
		if strings.Contains(m.Body, "FAKE_AGY_OK") {
			foundReply = true
			break
		}
	}
	if !foundReply {
		t.Fatalf("expected FAKE_AGY_OK via real bcc message send, got outbound=%+v", outs)
	}

	evs, err := node.eventsSince(0)
	if err != nil {
		t.Fatalf("eventsSince: %v", err)
	}
	hasUsage, hasApprovalDecided := false, false
	for _, ev := range evs {
		if ev.Type == "harness.usage_updated" {
			hasUsage = true
		}
		if ev.Type == "approval.decided" && ev.Payload["decision"] == "approve:once" {
			hasApprovalDecided = true
		}
	}
	if !hasUsage {
		t.Fatalf("expected harness.usage_updated event")
	}
	if !hasApprovalDecided {
		t.Fatalf("expected approval.decided=approve:once event")
	}

	// Verify clean teardown and zero lingering child processes on Linux.
	beforeStopChildren := linuxDescendants(node.PID())
	if err := node.Stop(); err != nil {
		t.Fatalf("node.Stop returned error: %v", err)
	}
	for _, child := range beforeStopChildren {
		if pidAliveLinux(child.PID) {
			t.Fatalf("leaked child process after bcn stop: pid=%d cmd=%q", child.PID, child.Cmdline)
		}
	}
}
