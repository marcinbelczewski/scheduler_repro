# EventBridge Scheduler + AgentCore: A2A Protocol Bug

This repository provides a minimal reproduction case for a critical bug where **EventBridge Scheduler cannot invoke A2A protocol AgentCore runtimes**, while HTTP protocol runtimes work correctly.

## Issue Summary

When using EventBridge Scheduler's universal target `aws-sdk:bedrockagentcore:invokeAgentRuntime` to invoke AgentCore runtimes:

| Protocol | Agent Executes? | Scheduler Reports |
|----------|-----------------|-------------------|
| HTTP     | Yes             | Success           |
| A2A      | Yes             | `AWS.Scheduler.InternalServerError` |

The A2A agent executes successfully (visible in CloudWatch logs), but EventBridge Scheduler reports failure and sends the invocation to the Dead Letter Queue.

**Impact**: It is currently impossible to use EventBridge Scheduler with A2A protocol agents in production.

## Root Cause Analysis

The `invokeAgentRuntime` API returns a streaming response. EventBridge Scheduler appears to handle HTTP protocol streaming responses correctly, but fails to properly handle A2A protocol (JSON-RPC) streaming responses, resulting in an internal server error even when the agent completes successfully.

## Repository Structure

```
.
├── Makefile           # Orchestrates all infrastructure and deployments
├── http/              # HTTP protocol agent (works with Scheduler)
│   ├── my_agent.py
│   ├── pyproject.toml
│   └── uv.lock
└── a2a/               # A2A protocol agent (fails with Scheduler)
    ├── my_a2a_server.py
    ├── pyproject.toml
    └── uv.lock
```

## Prerequisites

- AWS CLI configured with credentials that have permissions to:
  - Create IAM roles and policies
  - Create SQS queues
  - Create EventBridge schedules
  - Deploy AgentCore runtimes
- [uv](https://docs.astral.sh/uv/) - Python package manager
- Python 3.13+

## Step-by-Step Reproduction

### 1. Clone the repository

```bash
git clone https://github.com/marcinbelczewski/scheduler_repro.git
cd scheduler_repro
```

### 2. Deploy everything

The Makefile creates all required infrastructure:

```bash
make all
```

This command:
1. Creates an SQS Dead Letter Queue (`scheduler-repro-dlq`)
2. Creates an IAM role (`scheduler_repro`) with trust policy for `scheduler.amazonaws.com`
3. Configures and deploys the HTTP protocol agent
4. Configures and deploys the A2A protocol agent
5. Creates a schedule group (`scheduler_repro`)
6. Creates two schedules (both run every 1 minute):
   - `http-agent` - invokes the HTTP protocol agent
   - `a2a-agent` - invokes the A2A protocol agent

### 3. Verify schedules are running

```bash
make status
```

Expected output:
```
=== Schedules in scheduler_repro ===
http-agent: ENABLED
a2a-agent: ENABLED
```

### 4. Wait 2-3 minutes for invocations

Both schedules trigger every minute. Wait for a few invocations to occur.

### 5. Check the Dead Letter Queue

```bash
make dlq
```

**Expected result**: You will see failure messages only for the A2A agent:

```json
{
  "Body": {
    "version": "1.0",
    "timestamp": "2024-12-10T12:45:00.000Z",
    "errorType": "AWS.Scheduler.InternalServerError",
    "errorMessage": "Unexpected error occurred while executing the request.",
    "requestPayload": "..."
  }
}
```

The HTTP agent schedule will have no failures in the DLQ.

### 6. Verify A2A agent actually executed successfully

```bash
make logs-a2a
```

You will see the agent received the request and processed it correctly - the failure is entirely on the Scheduler side, not the agent.

### 7. Clean up

```bash
make destroy
```

## Additional Makefile Commands

| Command | Description |
|---------|-------------|
| `make all` | Deploy everything |
| `make destroy` | Tear down everything |
| `make status` | Show schedule statuses |
| `make dlq` | View DLQ messages |
| `make logs-http` | Tail HTTP agent logs |
| `make logs-a2a` | Tail A2A agent logs |
| `make create-infra` | Create IAM role and DLQ only |
| `make delete-infra` | Delete IAM role and DLQ only |

## Technical Details

### Schedule Configuration

Both schedules use identical configuration except for the target agent:

```json
{
  "Arn": "arn:aws:scheduler:::aws-sdk:bedrockagentcore:invokeAgentRuntime",
  "RoleArn": "<scheduler-role-arn>",
  "Input": "{\"AgentRuntimeArn\":\"<agent-arn>\",\"Payload\":\"<protocol-specific-payload>\"}",
  "DeadLetterConfig": {"Arn": "<dlq-arn>"},
  "RetryPolicy": {"MaximumRetryAttempts": 0}
}
```

### HTTP Agent Payload

```json
{"prompt": "Hi!"}
```

### A2A Agent Payload (JSON-RPC)

```json
{
  "jsonrpc": "2.0",
  "id": "req-001",
  "method": "message/send",
  "params": {
    "message": {
      "role": "user",
      "parts": [{"kind": "text", "text": "what is 2+2?"}],
      "messageId": "12345678-1234-1234-1234-123456789012"
    }
  }
}
```

---

## Related Issue: TLS Probing Warning on First Request

When an AgentCore runtime instance starts and receives its first request, the following warning appears in logs:

```
WARNING: Invalid HTTP request received.
```

This occurs because the AgentCore sidecar performs TLS/SSL handshake probing to determine whether the agent server supports HTTPS. It first attempts an HTTPS connection, which fails (since agents typically run HTTP internally), then falls back to HTTP.

**Impact**: This warning is benign but confusing for developers, as it appears to indicate an error when the agent is functioning correctly.

**Reproduction**: Deploy any agent and observe the CloudWatch logs during the first invocation after a cold start.
