package antigravity_test

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const liveTurnTimeout = 8 * time.Minute

type mcpCallRecord struct {
	Server    string         `json:"server"`
	Tool      string         `json:"tool"`
	Arguments map[string]any `json:"arguments"`
	Result    map[string]any `json:"result"`
}

func readMCPCalls(path string) []mcpCallRecord {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []mcpCallRecord
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		var r mcpCallRecord
		if err := json.Unmarshal(sc.Bytes(), &r); err == nil {
			out = append(out, r)
		}
	}
	return out
}

func discoverAgyMCPTools(t *testing.T, agyHome string, envMap map[string]string) {
	t.Helper()
	schemaPath := filepath.Join(agyHome, ".gemini", "antigravity-cli", "mcp", "test", "get_value.json")
	if _, err := os.Stat(schemaPath); err == nil {
		return
	}

	cmd := exec.Command("agy", "acp", "--process-per-session")
	cmd.Dir = agyHome
	cmd.Env = cleanEnv(envMap)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("agy discovery stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("agy discovery stdout pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start agy discovery: %v", err)
	}
	defer func() {
		_ = stdin.Close()
		_ = cmd.Wait()
	}()

	reader := bufio.NewScanner(stdout)
	reader.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	rpcCall := func(id int, method string, params map[string]any) map[string]any {
		req := map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"method":  method,
			"params":  params,
		}
		b, _ := json.Marshal(req)
		if _, err := stdin.Write(append(b, '\n')); err != nil {
			t.Fatalf("agy discovery write %s: %v", method, err)
		}
		for reader.Scan() {
			var resp map[string]any
			if err := json.Unmarshal(reader.Bytes(), &resp); err != nil {
				continue
			}
			if respID, ok := resp["id"].(float64); ok && int(respID) == id {
				res, ok := resp["result"].(map[string]any)
				if !ok {
					t.Fatalf("agy discovery %s failed: %+v", method, resp)
				}
				return res
			}
		}
		t.Fatalf("agy closed before replying to %s", method)
		return nil
	}

	rpcCall(1, "initialize", map[string]any{"protocolVersion": 1})
	sess := rpcCall(2, "session/new", map[string]any{"cwd": agyHome, "mcpServers": []any{}})
	sessID := fmt.Sprint(sess["sessionId"])

	deadline := time.Now().Add(45 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(schemaPath); err == nil {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	if _, err := os.Stat(schemaPath); err != nil {
		t.Fatalf("timed out waiting for agy MCP tool schema at %s: %v", schemaPath, err)
	}

	rpcCall(3, "session/close", map[string]any{"sessionId": sessID})
}

func writeAgyHomeConfig(t *testing.T, agyHome, model, mcpBin, mcpLog string) {
	t.Helper()
	settingsDir := filepath.Join(agyHome, ".gemini", "antigravity-cli")
	configDir := filepath.Join(agyHome, ".gemini", "config")
	if err := os.MkdirAll(settingsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		t.Fatal(err)
	}

	settings := map[string]any{
		"modelProvider":      "gemini",
		"setupComplete":      true,
		"onboardingComplete": true,
		"agentMode":          "",
		"toolPermission":     "request-review",
		"model":              model + "-low",
	}
	sb, _ := json.MarshalIndent(settings, "", "  ")
	if err := os.WriteFile(filepath.Join(settingsDir, "settings.json"), append(sb, '\n'), 0o600); err != nil {
		t.Fatalf("write agy settings.json: %v", err)
	}

	mcpCfg := map[string]any{
		"mcpServers": map[string]any{
			"test": map[string]any{
				"command": mcpBin,
				"args":    []string{},
				"env": map[string]string{
					"BCN_MCP_LOG": mcpLog,
				},
			},
		},
	}
	mb, _ := json.MarshalIndent(mcpCfg, "", "  ")
	if err := os.WriteFile(filepath.Join(configDir, "mcp_config.json"), append(mb, '\n'), 0o600); err != nil {
		t.Fatalf("write agy mcp_config.json: %v", err)
	}
}

func TestLiveAntigravityE2E(t *testing.T) {
	scenario := strings.TrimSpace(os.Getenv("BCN_E2E_SCENARIO"))
	gatewayURL := strings.TrimSpace(os.Getenv("AI_GATEWAY_BASE_URL"))
	apiKey := strings.TrimSpace(os.Getenv("AI_API_KEY"))
	model := strings.TrimSpace(os.Getenv("BCN_E2E_MODEL"))
	if scenario == "" || gatewayURL == "" || apiKey == "" || model == "" {
		if os.Getenv("BCN_REQUIRE_LIVE_E2E") == "1" {
			t.Fatalf("missing required env: BCN_E2E_SCENARIO=%q AI_GATEWAY_BASE_URL=%q BCN_E2E_MODEL=%q (AI_API_KEY set=%v)",
				scenario, gatewayURL, model, apiKey != "")
		}
		t.Skip("live Antigravity E2E environment not configured")
	}

	bcnBin := resolveBCNBin(t)
	artDir := artifactDir(t, "antigravity-"+scenario)
	tmp := t.TempDir()
	homeDir := filepath.Join(tmp, "home")
	agyHome := filepath.Join(tmp, "antigravity-home")
	const agentID = "assistant"
	workspaceDir := filepath.Join(homeDir, "workspaces", agentID)
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		t.Fatal(err)
	}

	mcpBin := buildGoBinary(t, filepath.Join("fixtures", "mcp"), filepath.Join(tmp, "mcp-test"))
	mcpLog := filepath.Join(artDir, "mcp.jsonl")
	writeAgyHomeConfig(t, agyHome, model, mcpBin, mcpLog)

	nodeEnv := map[string]string{
		"HOME":                        agyHome,
		"USERPROFILE":                 agyHome,
		"GEMINI_API_KEY":              apiKey,
		"GOOGLE_GEMINI_BASE_URL":      gatewayURL,
		"AGY_CLI_DISABLE_AUTO_UPDATE": "true",
	}
	discoverAgyMCPTools(t, agyHome, nodeEnv)

	pluginZip := filepath.Join(tmp, "harness-antigravity.zip")
	channelZip := filepath.Join(tmp, "channel-e2e.zip")
	packagePluginDir(t, "..", pluginZip)
	packagePluginDir(t, filepath.Join("fixtures", "channel"), channelZip)
	installPluginZip(t, bcnBin, homeDir, pluginZip)
	installPluginZip(t, bcnBin, homeDir, channelZip)

	chSrv := newE2EChannelServer()
	defer chSrv.Close()

	cfgOpt := agyConfigOptions{
		AgentID:     agentID,
		ChannelURL:  chSrv.URL(),
		Mode:        "session",
		Sandbox:     "workspace-write",
		IdleTimeout: 0,
		Model:       model,
		Effort:      "low",
	}
	if scenario == "mcp-once" {
		nodeEnv["GEMINI_API_KEY"] = "inherited-key-overridden-by-config"
		cfgOpt.APIKey = apiKey
	}
	if scenario == "full-access" || scenario == "background" {
		cfgOpt.Sandbox = "danger-full-access"
	}
	if scenario == "background" {
		cfgOpt.IdleTimeout = 2
	}
	if scenario == "refresh" {
		_ = os.WriteFile(filepath.Join(workspaceDir, "AGENTS.md"), []byte("Keep replies clear.\n"), 0o644)
		_ = os.WriteFile(filepath.Join(workspaceDir, "GEMINI.md"), []byte("Keep replies clear.\n"), 0o644)
	}
	writeAgyNodeConfig(t, homeDir, cfgOpt)

	// Verify real agy CLI inspection.
	inspOut := runBCN(t, bcnBin, homeDir, nodeEnv, "agent", "inspect", agentID)
	t.Logf("bcn agent inspect:\n%s", inspOut)
	if !strings.Contains(inspOut, "true") {
		t.Fatalf("expected available=true in bcn agent inspect:\n%s", inspOut)
	}

	var activeNode *runningBCN
	nodeRunIdx := 0
	var previewPort int

	startNode := func() *runningBCN {
		nodeRunIdx++
		logPath := filepath.Join(artDir, fmt.Sprintf("node-%d.log", nodeRunIdx))
		n := startBCNNode(t, bcnBin, homeDir, nodeEnv, logPath)
		if _, err := n.waitEvent(30*time.Second, 0, func(ev auditEvent) bool {
			return ev.Type == "channel.connected" && ev.PluginID == "channel-e2e"
		}); err != nil {
			t.Fatalf("wait channel.connected: %v\nlog:\n%s", err, n.LogText())
		}
		activeNode = n
		return n
	}

	stopAndVerifyClean := func() {
		if activeNode == nil {
			return
		}
		n := activeNode
		activeNode = nil
		n.dumpEventsToFile(filepath.Join(artDir, fmt.Sprintf("audit-%d.jsonl", nodeRunIdx)))
		children := linuxDescendants(n.PID())
		if err := n.Stop(); err != nil {
			t.Logf("node stop returned: %v", err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			alive := 0
			for _, c := range children {
				if pidAliveLinux(c.PID) {
					alive++
				}
			}
			if alive == 0 {
				break
			}
			time.Sleep(150 * time.Millisecond)
		}
		for _, c := range children {
			if pidAliveLinux(c.PID) {
				t.Fatalf("leaked child process after bcn stop: pid=%d cmd=%q", c.PID, c.Cmdline)
			}
		}
	}

	t.Cleanup(func() {
		stopAndVerifyClean()
		if previewPort > 0 {
			conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", previewPort), time.Second)
			if err == nil {
				_ = conn.Close()
				t.Errorf("preview port %d still listening after node stop", previewPort)
			}
		}
	})

	startNode()

	reports, err := activeNode.inspectHarnesses(agentID)
	if err != nil || len(reports) == 0 || !reports[0].Result.Available {
		t.Fatalf("online agents.inspect failed: reports=%+v err=%v", reports, err)
	}
	foundMCPTool := false
	for _, s := range reports[0].Result.MCPServers {
		if s.Name == "test" {
			for _, tool := range s.Tools {
				if tool.Name == "get_value" {
					foundMCPTool = true
				}
			}
		}
	}
	if !foundMCPTool {
		t.Fatalf("expected MCP server test/get_value in online agents.inspect: %+v", reports[0].Result)
	}

	type turnResult struct {
		SessionID        string
		ProviderThreadID string
		TurnID           string
		Events           []auditEvent
		Outbound         []outboundMsg
		Prompts          []promptRecord
		Steered          bool
	}

	runTurn := func(body string, steer bool, stopAtStarted bool) turnResult {
		afterSeq := activeNode.lastEventSeq()
		outIdx := chSrv.OutboundCount()
		prIdx := chSrv.PromptsCount()
		msgID := "msg-" + randomHex(t, 6)
		chSrv.PushDM(msgID, body)

		approvedAt := time.Now().Add(15 * time.Second)
		go func() {
			for time.Now().Before(approvedAt) {
				if activeNode != nil && activeNode.approvePendingReviews(agentID) > 0 {
					return
				}
				time.Sleep(200 * time.Millisecond)
			}
		}()

		steered := false
		deadline := time.Now().Add(liveTurnTimeout)
		var terminal auditEvent
		for time.Now().Before(deadline) {
			evs, err := activeNode.eventsSince(afterSeq)
			if err == nil {
				for _, ev := range evs {
					if steer && !steered && (ev.Type == "harness.content_delta" || ev.Type == "harness.tool_started") {
						chSrv.PushDM("steer-"+randomHex(t, 4), "Reply with one short sentence.")
						steered = true
					}
					if stopAtStarted && ev.Type == "harness.turn_started" {
						terminal = ev
						break
					}
					if ev.Type == "harness.turn_completed" || ev.Type == "harness.turn_failed" || ev.Type == "harness.turn_cancelled" {
						terminal = ev
						break
					}
				}
			}
			if terminal.Seq > 0 {
				break
			}
			time.Sleep(300 * time.Millisecond)
		}
		if terminal.Seq == 0 {
			t.Fatalf("timed out waiting for turn completion (body=%q)\nlog:\n%s", body, activeNode.LogText())
		}
		if !stopAtStarted && terminal.Type != "harness.turn_completed" {
			t.Fatalf("expected harness.turn_completed, got %s: %+v", terminal.Type, terminal.Payload)
		}
		allEvs, _ := activeNode.eventsSince(0)
		turnEvs, _ := activeNode.eventsSince(afterSeq)
		sid := fmt.Sprint(terminal.Payload["sessionId"])
		var provThread string
		for _, ev := range allEvs {
			if (ev.Type == "harness.session.started" || ev.Type == "harness.session_started") && fmt.Sprint(ev.Payload["sessionId"]) == sid {
				if pt := fmt.Sprint(ev.Payload["providerThreadId"]); pt != "" && pt != "<nil>" {
					provThread = pt
				}
			}
		}
		return turnResult{
			SessionID:        sid,
			ProviderThreadID: provThread,
			TurnID:           fmt.Sprint(terminal.Payload["turnId"]),
			Events:           turnEvs,
			Outbound:         chSrv.OutboundSince(outIdx),
			Prompts:          chSrv.PromptsSince(prIdx),
			Steered:          steered,
		}
	}

	queryMCP := func(key string, scope string) turnResult {
		if scope != "" {
			chSrv.SetDecisionFunc(func(pr promptRecord) string {
				if hasPromptAction(pr, "approve:"+scope) {
					return "approve:" + scope
				}
				return "approve:once"
			})
		} else {
			chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		}
		beforeCalls := len(readMCPCalls(mcpLog))
		reqText := fmt.Sprintf(`请使用 MCP 工具 test/get_value，参数为 {"key": %q}，读取测试值。`, key)
		var lastRes turnResult
		for retry := 0; retry <= 6; retry++ {
			msg := reqText
			if retry > 0 {
				msg = fmt.Sprintf(`还没有收到实际工具结果。请使用 MCP 工具 test/get_value，参数为 {"key": %q}，读取测试值。`, key)
			}
			lastRes = runTurn(msg, false, false)
			calls := readMCPCalls(mcpLog)
			if len(calls) > beforeCalls {
				matched := false
				for _, c := range calls[beforeCalls:] {
					if c.Server == "test" && c.Tool == "get_value" && fmt.Sprint(c.Arguments["key"]) == key && fmt.Sprint(c.Result["value"]) == "MCP_OK" {
						matched = true
					}
				}
				if !matched {
					t.Fatalf("MCP calls did not match key=%q: %+v", key, calls[beforeCalls:])
				}
				if scope != "" {
					foundScope := false
					for _, pr := range lastRes.Prompts {
						if pr.DecisionAction == "approve:"+scope {
							foundScope = true
						}
					}
					if !foundScope {
						t.Fatalf("expected prompt approved with scope %q for key=%q, got prompts=%+v", scope, key, lastRes.Prompts)
					}
				}
				return lastRes
			}
		}
		t.Fatalf("MCP tool test/get_value was never invoked for key=%q", key)
		return lastRes
	}

	switch scenario {
	case "mcp-once":
		queryMCP("once", "once")

	case "bcc":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		first := runTurn("Please remind me to drink some water in five seconds.", true, false)
		sawSteer := false
		sawCmdApproval := false
		for _, ev := range first.Events {
			if ev.Type == "harness.turn.steer.accepted" {
				sawSteer = true
			}
			if ev.Type == "approval.requested" && fmt.Sprint(ev.Payload["action"]) == "command_execution" {
				sawCmdApproval = true
			}
		}
		if !sawCmdApproval {
			t.Fatalf("expected command_execution approval in bcc scenario")
		}
		if !first.Steered || !sawSteer {
			t.Fatalf("expected mid-turn steering accepted (steered=%v sawSteer=%v)", first.Steered, sawSteer)
		}

		rejectedOnce := false
		chSrv.SetDecisionFunc(func(pr promptRecord) string {
			if !rejectedOnce {
				rejectedOnce = true
				return "deny"
			}
			return "approve:once"
		})
		continued := runTurn("What reminder did I ask you to set? Please reply to me.", false, false)
		if continued.ProviderThreadID != first.ProviderThreadID {
			t.Fatalf("expected same provider thread on continued turn: %s vs %s", continued.ProviderThreadID, first.ProviderThreadID)
		}
		sawRejected := false
		for _, ev := range continued.Events {
			if ev.Type == "approval.decided" && strings.HasPrefix(fmt.Sprint(ev.Payload["decision"]), "deny") {
				sawRejected = true
			}
		}
		if !sawRejected {
			t.Fatalf("expected rejected tool approval in continued turn")
		}

	case "full-access":
		res := runTurn(
			"I'm reading this chat on my phone and cannot view our workspace. "+
				"Please save a short note about drinking enough water to full-access-note.txt in the workspace, "+
				"then send me a message here with the filename and a one-sentence summary.",
			false, false,
		)
		noteBytes, err := os.ReadFile(filepath.Join(workspaceDir, "full-access-note.txt"))
		if err != nil || strings.TrimSpace(string(noteBytes)) == "" {
			t.Fatalf("expected non-empty full-access-note.txt: err=%v content=%q", err, string(noteBytes))
		}
		if len(res.Outbound) == 0 {
			t.Fatalf("expected outbound reply via bcc message send in full-access scenario")
		}
		if len(res.Prompts) > 0 {
			t.Fatalf("expected zero approval prompts in danger-full-access mode, got %d", len(res.Prompts))
		}

	case "recovery":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		first := runTurn("Please remember that I prefer brief replies.", false, false)
		var agyPID int
		for _, c := range linuxDescendants(activeNode.PID()) {
			if strings.Contains(c.Cmdline, "acp") && c.Env["HOME"] == agyHome {
				agyPID = c.PID
				break
			}
		}
		if agyPID == 0 {
			t.Fatalf("could not locate agy acp child process")
		}
		terminatePID(agyPID)
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) && pidAliveLinux(agyPID) {
			time.Sleep(100 * time.Millisecond)
		}
		if pidAliveLinux(agyPID) {
			killPID(agyPID)
		}
		recovered := runTurn("What reply style did I ask for? Please reply to me.", false, false)
		if recovered.ProviderThreadID != first.ProviderThreadID {
			t.Fatalf("expected recovery to resume provider thread %q, got %q", first.ProviderThreadID, recovered.ProviderThreadID)
		}
		var newPID int
		for _, c := range linuxDescendants(activeNode.PID()) {
			if strings.Contains(c.Cmdline, "acp") && c.Env["HOME"] == agyHome {
				newPID = c.PID
				break
			}
		}
		if newPID == 0 || newPID == agyPID {
			t.Fatalf("expected new agy acp PID after recovery (old=%d new=%d)", agyPID, newPID)
		}
		runTurn("Tell me briefly what you can help me with.", false, true)

	case "refresh":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		first := runTurn("Please remember that I prefer brief replies.", false, false)
		if err := os.WriteFile(filepath.Join(workspaceDir, "GEMINI.md"), []byte("Keep replies concise.\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		time.Sleep(6 * time.Second)
		refreshed := runTurn("What reply style did I ask for? Please reply to me.", false, true)
		if refreshed.ProviderThreadID == first.ProviderThreadID {
			t.Fatalf("expected fresh provider thread after GEMINI.md update (still %q)", refreshed.ProviderThreadID)
		}

	case "background":
		chSrv.SetDecisionFunc(func(pr promptRecord) string { return "approve:once" })
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		previewPort = ln.Addr().(*net.TCPAddr).Port
		_ = ln.Close()

		filename := "preview-" + randomHex(t, 6) + ".txt"
		expected := "BCN preview " + randomHex(t, 6) + "\n"
		if err := os.WriteFile(filepath.Join(workspaceDir, filename), []byte(expected), 0o644); err != nil {
			t.Fatal(err)
		}

		checkPreview := func() {
			t.Helper()
			resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/%s", previewPort, filename))
			if err != nil {
				t.Fatalf("GET preview failed: %v", err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			if resp.StatusCode != 200 || string(body) != expected {
				t.Fatalf("unexpected preview response: status=%d body=%q", resp.StatusCode, string(body))
			}
		}

		first := runTurn(
			fmt.Sprintf(
				"Please start a local HTTP preview for the current folder. Run "+
					"`python3 -m http.server %d --bind 127.0.0.1` "+
					"as a background daemon command without a trailing `&`. "+
					"Keep that background task running after this turn. "+
					"Check that the preview responds, then use `bcc message send` to send its address to this conversation.",
				previewPort,
			),
			false, false,
		)
		if len(first.Outbound) == 0 {
			t.Fatalf("expected preview URL sent via bcc message send")
		}
		checkPreview()

		// Sleep past idle_timeout=2s; hasBackgroundJob must keep the session alive.
		time.Sleep(4 * time.Second)
		checkPreview()

		continued := runTurn(
			"Is the preview still available? Please check it, keep the existing server running, "+
				"and use `bcc message send` to send its address to this conversation.",
			false, false,
		)
		if continued.ProviderThreadID != first.ProviderThreadID {
			t.Fatalf("expected background session preserved across idle timeout: %s vs %s", continued.ProviderThreadID, first.ProviderThreadID)
		}
		checkPreview()

	default:
		t.Fatalf("unknown BCN_E2E_SCENARIO=%q", scenario)
	}
}
