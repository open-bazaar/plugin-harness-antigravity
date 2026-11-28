package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

type rpcPacket struct {
	JSONRPC string          `json:"jsonrpc,omitempty"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

var (
	outMu     sync.Mutex
	targetRe  = regexp.MustCompile(`target=([^\s\]]+)`)
	pendingMu sync.Mutex
	pending   = map[string]chan rpcPacket{}
)

func sendJSON(v any) {
	outMu.Lock()
	defer outMu.Unlock()
	b, _ := json.Marshal(v)
	_, _ = os.Stdout.Write(append(b, '\n'))
}

func main() {
	args := os.Args[1:]
	if len(args) >= 1 && args[0] == "--version" {
		fmt.Println("1.5.16")
		return
	}
	if len(args) >= 1 && args[0] == "models" {
		fmt.Println("fake-agy-1-low  Fake Agy 1 (Low)")
		fmt.Println("fake-agy-1-high  Fake Agy 1 (High)")
		return
	}
	if len(args) >= 2 && args[0] == "mcp" && args[1] == "list" {
		fmt.Println("test  stdio  enabled  mcp-test")
		return
	}

	skipPerms := false
	for _, a := range args {
		if a == "--dangerously-skip-permissions" {
			skipPerms = true
		}
	}

	currentSession := "fake-agy-session-1"
	currentModel := "fake-agy-1"
	currentEffort := "low"
	serverReqSeq := 7000

	configOptions := func() []map[string]any {
		return []map[string]any{
			{
				"id":           "model",
				"currentValue": currentModel,
				"options": []map[string]any{
					{"value": "fake-agy-1", "name": "Fake Agy 1"},
				},
			},
			{
				"id":           "thought_level",
				"currentValue": currentEffort,
				"options": []map[string]any{
					{"value": "low", "name": "Low"},
					{"value": "high", "name": "High"},
				},
			},
		}
	}

	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var pkt rpcPacket
		if err := json.Unmarshal([]byte(line), &pkt); err != nil {
			continue
		}

		// Response to a server-initiated request (session/request_permission).
		if pkt.Method == "" && len(pkt.ID) > 0 {
			key := strings.Trim(string(pkt.ID), `"`)
			pendingMu.Lock()
			ch := pending[key]
			delete(pending, key)
			pendingMu.Unlock()
			if ch != nil {
				ch <- pkt
			}
			continue
		}

		switch pkt.Method {
		case "initialize":
			sendJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(pkt.ID),
				"result": map[string]any{
					"protocolVersion": 1,
					"agentCapabilities": map[string]any{
						"_meta": map[string]any{
							"antigravity": map[string]any{
								"systemPrompt": map[string]any{"append": true},
							},
						},
					},
				},
			})

		case "session/new":
			sendJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(pkt.ID),
				"result": map[string]any{
					"sessionId":     currentSession,
					"configOptions": configOptions(),
				},
			})

		case "session/resume":
			var p struct {
				SessionID string `json:"sessionId"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			if p.SessionID != "" {
				currentSession = p.SessionID
			}
			sendJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(pkt.ID),
				"result": map[string]any{
					"sessionId":     currentSession,
					"configOptions": configOptions(),
				},
			})

		case "session/set_config_option":
			var p struct {
				ConfigID string `json:"configId"`
				Value    string `json:"value"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			if p.ConfigID == "model" && p.Value != "" {
				currentModel = p.Value
			} else if p.ConfigID == "thought_level" && p.Value != "" {
				currentEffort = p.Value
			}
			sendJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(pkt.ID),
				"result": map[string]any{
					"configOptions": configOptions(),
				},
			})

		case "session/close":
			sendJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      json.RawMessage(pkt.ID),
				"result":  map[string]any{},
			})
			return

		case "session/cancel":
			// notification

		case "session/prompt":
			var p struct {
				SessionID string `json:"sessionId"`
				Prompt    []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"prompt"`
			}
			_ = json.Unmarshal(pkt.Params, &p)
			promptID := append(json.RawMessage(nil), pkt.ID...)
			inputText := ""
			for _, blk := range p.Prompt {
				if blk.Type == "text" {
					inputText += blk.Text + "\n"
				}
			}

			pendingMu.Lock()
			serverReqSeq++
			reqID := serverReqSeq
			pendingMu.Unlock()

			go func(promptID json.RawMessage, reqID int, sessID, inputText string) {
				approved := skipPerms
				if !approved {
					ch := make(chan rpcPacket, 1)
					key := fmt.Sprintf("%d", reqID)
					pendingMu.Lock()
					pending[key] = ch
					pendingMu.Unlock()

					sendJSON(map[string]any{
						"jsonrpc": "2.0",
						"id":      reqID,
						"method":  "session/request_permission",
						"params": map[string]any{
							"sessionId": sessID,
							"toolCall": map[string]any{
								"toolCallId": "tc-1",
								"name":       "run_command",
								"title":      "Run bcc message send",
								"kind":       "execute",
								"rawInput": map[string]any{
									"command": "bcc message send",
								},
							},
							"options": []map[string]any{
								{"optionId": "allow_once", "kind": "allow_once", "name": "Allow once"},
								{"optionId": "allow_always", "kind": "allow_always", "name": "Always allow"},
								{"optionId": "reject_once", "kind": "reject_once", "name": "Reject"},
							},
						},
					})

					select {
					case resp := <-ch:
						var out struct {
							Outcome struct {
								Outcome  string `json:"outcome"`
								OptionID string `json:"optionId"`
							} `json:"outcome"`
						}
						_ = json.Unmarshal(resp.Result, &out)
						if out.Outcome.Outcome == "selected" && (out.Outcome.OptionID == "allow_once" || out.Outcome.OptionID == "allow_always") {
							approved = true
						}
					case <-time.After(20 * time.Second):
					}
				}

				sendJSON(map[string]any{
					"jsonrpc": "2.0",
					"method":  "session/update",
					"params": map[string]any{
						"sessionId": sessID,
						"update": map[string]any{
							"sessionUpdate": "tool_call",
							"toolCallId":    "tc-1",
							"name":          "run_command",
							"title":         "Run bcc message send",
							"status":        "in_progress",
						},
					},
				})

				replyBody := "FAKE_AGY_OK"
				toolStatus := "failed"
				if approved {
					chkOut, _ := exec.Command("bcc", "message", "check").CombinedOutput()
					target := ""
					if m := targetRe.FindStringSubmatch(string(chkOut)); len(m) >= 2 {
						target = m[1]
					}
					if target == "" {
						if m := targetRe.FindStringSubmatch(inputText); len(m) >= 2 {
							target = m[1]
						}
					}
					if target != "" {
						cmd := exec.Command("bcc", "message", "send", "--target", target)
						cmd.Stdin = strings.NewReader(replyBody + "\n")
						var buf bytes.Buffer
						cmd.Stdout = &buf
						cmd.Stderr = &buf
						if err := cmd.Run(); err == nil {
							toolStatus = "completed"
						}
					}
				}

				sendJSON(map[string]any{
					"jsonrpc": "2.0",
					"method":  "session/update",
					"params": map[string]any{
						"sessionId": sessID,
						"update": map[string]any{
							"sessionUpdate": "tool_call_update",
							"toolCallId":    "tc-1",
							"status":        toolStatus,
						},
					},
				})

				sendJSON(map[string]any{
					"jsonrpc": "2.0",
					"method":  "session/update",
					"params": map[string]any{
						"sessionId": sessID,
						"update": map[string]any{
							"sessionUpdate": "agent_message_chunk",
							"content": map[string]any{
								"type": "text",
								"text": replyBody,
							},
						},
					},
				})

				sendJSON(map[string]any{
					"jsonrpc": "2.0",
					"method":  "session/update",
					"params": map[string]any{
						"sessionId": sessID,
						"update": map[string]any{
							"sessionUpdate": "usage_update",
							"size":          131072,
						},
					},
				})

				sendJSON(map[string]any{
					"jsonrpc": "2.0",
					"id":      promptID,
					"result": map[string]any{
						"stopReason": "end_turn",
						"usage": map[string]any{
							"inputTokens":  120,
							"outputTokens": 30,
							"totalTokens":  150,
						},
					},
				})
			}(promptID, reqID, currentSession, inputText)
		}
	}
}
