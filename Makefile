REGION := eu-central-1
ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text)
SCHEDULE_GROUP := scheduler_repro
SCHEDULER_ROLE_NAME := scheduler_repro
SCHEDULER_ROLE := arn:aws:iam::$(ACCOUNT_ID):role/$(SCHEDULER_ROLE_NAME)
DLQ_NAME := scheduler-repro-dlq
DLQ_ARN := arn:aws:sqs:$(REGION):$(ACCOUNT_ID):$(DLQ_NAME)

HTTP_PAYLOAD := {\\\"prompt\\\": \\\"Hi!\\\"}
A2A_PAYLOAD := {\\\"jsonrpc\\\":\\\"2.0\\\",\\\"id\\\":\\\"req-001\\\",\\\"method\\\":\\\"message/send\\\",\\\"params\\\":{\\\"message\\\":{\\\"role\\\":\\\"user\\\",\\\"parts\\\":[{\\\"kind\\\":\\\"text\\\",\\\"text\\\":\\\"what is 2+2?\\\"}],\\\"messageId\\\":\\\"12345678-1234-1234-1234-123456789012\\\"}}}

# Extract runtime ID from package's .bedrock_agentcore.yaml
runtime-id = $(shell grep 'agent_id:' $(1)/.bedrock_agentcore.yaml 2>/dev/null | head -1 | awk '{print $$2}')
runtime-arn = arn:aws:bedrock-agentcore:$(REGION):$(ACCOUNT_ID):runtime/$(call runtime-id,$(1))

.PHONY: all deploy destroy configure-http configure-a2a deploy-http deploy-a2a destroy-http destroy-a2a \
        create-schedule-http create-schedule-a2a delete-schedule-http delete-schedule-a2a \
        create-infra delete-infra status logs-http logs-a2a dlq

# Default: set up infra, configure+deploy agents, create schedules
all: create-infra configure-http deploy-http configure-a2a deploy-a2a create-schedule-http create-schedule-a2a status

# Tear down everything
destroy: delete-schedule-http delete-schedule-a2a delete-schedule-group destroy-http destroy-a2a delete-infra

# --- Infrastructure (IAM role, DLQ) ---
create-infra:
	@echo "=== Creating DLQ ==="
	@aws sqs create-queue --queue-name $(DLQ_NAME) --region $(REGION) || echo "DLQ already exists"
	@echo "=== Creating IAM Role ==="
	@aws iam create-role \
		--role-name $(SCHEDULER_ROLE_NAME) \
		--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"scheduler.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
		2>/dev/null || true
	@aws iam put-role-policy \
		--role-name $(SCHEDULER_ROLE_NAME) \
		--policy-name scheduler-permissions \
		--policy-document '{"Version":"2012-10-17","Statement":[{"Sid":"AgentCoreInvoke","Effect":"Allow","Action":["bedrock-agentcore:ListAgentRuntimes","bedrock-agentcore:GetAgentRuntime","bedrock-agentcore:GetAgentRuntimeEndpoint","bedrock-agentcore:InvokeAgentRuntime","bedrock-agentcore:InvokeAgentRuntimeForUser"],"Resource":"*"},{"Sid":"DLQAccess","Effect":"Allow","Action":["sqs:SendMessage"],"Resource":"arn:aws:sqs:$(REGION):$(ACCOUNT_ID):*"}]}'
	@echo "Waiting for IAM propagation..."
	@sleep 10

delete-infra:
	@echo "=== Deleting IAM Role ==="
	@aws iam delete-role-policy --role-name $(SCHEDULER_ROLE_NAME) --policy-name scheduler-permissions 2>/dev/null || true
	@aws iam delete-role --role-name $(SCHEDULER_ROLE_NAME) 2>/dev/null || true
	@echo "=== Deleting DLQ ==="
	@aws sqs delete-queue --queue-url https://sqs.$(REGION).amazonaws.com/$(ACCOUNT_ID)/$(DLQ_NAME) 2>/dev/null || true

# --- Agent lifecycle (parameterized) ---
define configure-agent
	cd $(1) && uv sync && uv run agentcore configure \
		--name $(2) \
		--entrypoint $(2).py \
		--region $(REGION) \
		--protocol $(3) \
		--disable-memory \
		--disable-otel \
		--non-interactive \
		--runtime PYTHON_3_13 \
		--verbose
endef

define deploy-agent
	cd $(1) && uv run agentcore deploy
endef

define destroy-agent
	cd $(1) && uv run agentcore destroy --force
endef

# --- Schedule lifecycle (parameterized) ---
define create-schedule
	@aws scheduler create-schedule-group --name $(SCHEDULE_GROUP) --region $(REGION) 2>/dev/null || true
	aws scheduler create-schedule \
		--name $(1) \
		--group-name $(SCHEDULE_GROUP) \
		--schedule-expression "rate(1 minute)" \
		--flexible-time-window Mode=OFF \
		--target '{"Arn":"arn:aws:scheduler:::aws-sdk:bedrockagentcore:invokeAgentRuntime","RoleArn":"$(SCHEDULER_ROLE)","Input":"{\"AgentRuntimeArn\":\"$(2)\",\"Payload\":\"$(3)\"}","DeadLetterConfig":{"Arn":"$(DLQ_ARN)"},"RetryPolicy":{"MaximumRetryAttempts":0}}' \
		--region $(REGION)
endef

define delete-schedule
	@aws scheduler delete-schedule --name $(1) --group-name $(SCHEDULE_GROUP) --region $(REGION) 2>/dev/null || true
endef

# --- HTTP targets ---
configure-http:
	$(call configure-agent,http,my_agent,HTTP)

deploy-http:
	$(call deploy-agent,http)

destroy-http:
	$(call destroy-agent,http)

create-schedule-http:
	$(call create-schedule,http-agent,$(call runtime-arn,http),$(HTTP_PAYLOAD))

delete-schedule-http:
	$(call delete-schedule,http-agent)

logs-http:
	aws logs tail /aws/bedrock-agentcore/runtimes/$(call runtime-id,http)-DEFAULT --since 10m --region $(REGION)

# --- A2A targets ---
configure-a2a:
	$(call configure-agent,a2a,my_a2a_server,A2A)

deploy-a2a:
	$(call deploy-agent,a2a)

destroy-a2a:
	$(call destroy-agent,a2a)

create-schedule-a2a:
	$(call create-schedule,a2a-agent,$(call runtime-arn,a2a),$(A2A_PAYLOAD))

delete-schedule-a2a:
	$(call delete-schedule,a2a-agent)

logs-a2a:
	aws logs tail /aws/bedrock-agentcore/runtimes/$(call runtime-id,a2a)-DEFAULT --since 10m --region $(REGION)

# --- Utilities ---
status:
	@echo "=== Schedules in $(SCHEDULE_GROUP) ==="
	@aws scheduler list-schedules --group-name $(SCHEDULE_GROUP) --region $(REGION) 2>/dev/null \
		| jq -r '.Schedules[] | "\(.Name): \(.State)"' || echo "Group not found"

delete-schedule-group: delete-schedule-http delete-schedule-a2a
	@aws scheduler delete-schedule-group --name $(SCHEDULE_GROUP) --region $(REGION) 2>/dev/null || true

dlq:
	@echo "=== DLQ Messages ==="
	@aws sqs receive-message \
		--queue-url https://sqs.$(REGION).amazonaws.com/$(ACCOUNT_ID)/$(DLQ_NAME) \
		--max-number-of-messages 5 \
		--attribute-names All \
		--message-attribute-names All \
		--region $(REGION) | jq '.Messages[] | {Body: .Body | fromjson, Attributes: .MessageAttributes}'
