# Bazaar Compute Antigravity Harness Plugin

Official Antigravity CLI (`agy acp`) `harness` plugin (`harness-antigravity`) for Bazaar Compute 0.4.

## Capabilities
- ACP JSON-RPC 2.0 session management over stdio (`bazaar.process` with automatic cross-platform process-tree teardown)
- CLI availability & version inspection (`inspect`)
- In-flight turn steering (`steerTurn`) & cancellation (`cancelTurn`)
- Interactive tool permission forwarding (`approval`)
- Background subagent & outliving tool checks (`hasBackgroundJob`)

## Install
```bash
bcn plugin install open-bazaar/plugin-harness-antigravity
```
