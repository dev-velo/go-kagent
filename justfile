set shell := ["bash", "-euo", "pipefail", "-c"]

profile        := "kagent-lab"
k8s_version    := "v1.37.0"
kagent_version := "v1.0.0"
namespace      := "kagent"
ui_port        := "8082"

# Local-only: every kubectl/helm/kagent/minikube call uses a repo-local kubeconfig,
# so the company contexts in ~/.kube/config are never visible to this repo.
export KUBECONFIG := justfile_directory() / ".kube/config"

default:
    @just --list

# One command: cluster, CLI, kagent+Substrate, agent, session. Needs OPENAI_API_KEY.
up: cluster-up cli-install install wait-ready harness-apply status delegation-apply session github-maybe ui-bg demo
    @echo "ready: UI at http://localhost:{{ui_port}} | just ask \"What is 2+2?\" | just delegation-ask"

# Stop the cluster but keep all its state (images, Helm releases, Postgres); `just up` resumes in about a minute
down: ngrok-stop ui-stop
    minikube stop -p {{profile}}

# Create the local minikube cluster (k8s 1.37+ is required by Agent Substrate)
cluster-up cpus="6" memory="6g":
    mkdir -p .kube
    minikube start -p {{profile}} --driver=docker --kubernetes-version={{k8s_version}} --cpus={{cpus}} --memory={{memory}}
    just guard
    kubectl api-resources --api-group=certificates.k8s.io

# Delete the cluster and the repo-local kubeconfig; the next `just up` is a full install
destroy: ngrok-stop ui-stop
    minikube delete -p {{profile}}
    rm -f .kube/config

# Abort unless kubectl points at the local minikube profile
guard:
    #!/usr/bin/env bash
    set -euo pipefail
    ctx="$(kubectl config current-context)"
    if [[ "$ctx" != "{{profile}}" ]]; then
      echo "refusing to run: current context is '$ctx', expected '{{profile}}'" >&2
      exit 1
    fi

# Install the kagent CLI (pinned to the 1.0 docs release)
cli-install:
    command -v kagent >/dev/null || curl https://raw.githubusercontent.com/kagent-dev/kagent/refs/heads/main/scripts/get-kagent | bash -s -- --version {{kagent_version}}
    kagent version

# Install kagent + Agent Substrate + dev PostgreSQL (evaluation path); needs OPENAI_API_KEY in the environment
install: guard
    #!/usr/bin/env bash
    set -euo pipefail
    if helm status kagent -n {{namespace}} >/dev/null 2>&1; then
      echo "kagent already installed; skipping (run 'just install-force' to re-run the install)"
    else
      : "${OPENAI_API_KEY:?export OPENAI_API_KEY first}"
      kagent --config deploy/kagent-config.yaml install --namespace {{namespace}}
    fi
    kubectl rollout status deployment/kagent-controller -n {{namespace}} --timeout=300s

# Re-run `kagent install` even if kagent is already installed (e.g. after editing deploy/kagent-values.yaml)
install-force: guard
    : "${OPENAI_API_KEY:?export OPENAI_API_KEY first}"
    kagent --config deploy/kagent-config.yaml install --namespace {{namespace}}
    kubectl rollout status deployment/kagent-controller -n {{namespace}} --timeout=300s

# Wait for every running pod in kagent and ate-system; needed after `just down` (pods restart on resume)
wait-ready: guard
    kubectl wait --for=condition=Ready pod --field-selector=status.phase=Running --all -n ate-system --timeout=600s
    kubectl wait --for=condition=Ready pod --field-selector=status.phase=Running --all -n {{namespace}} --timeout=600s
    kubectl rollout status daemonset/atelet -n ate-system --timeout=600s

status: guard
    kubectl get pods -n ate-system
    kubectl get pods -n {{namespace}}
    kubectl get workerpools -n {{namespace}}

# Apply the Harness that every agent runs on; must exist before the Agents that reference it
harness-apply: guard
    kubectl apply -f deploy/agent/harness.yaml

# Agent-to-agent demo: orchestrator-agent (no K8s tools) delegates to minikube-agent through kagent-api's invoke_agent
delegation-apply: guard
    kubectl apply -f deploy/delegation/
    kubectl wait --for=condition=Ready agent/minikube-agent agent/orchestrator-agent -n {{namespace}} --timeout=300s

# Ask orchestrator-agent something only minikube-agent can answer
delegation-ask +message="Which pods are running in the kagent namespace?": guard
    kagent agent session create --agent orchestrator-agent -o json | jq -r '.session.id' | tee .session-id-orchestrator
    kagent agent invoke --session "$(cat .session-id-orchestrator)" --task "{{message}}"

delegation-clean: guard
    kubectl delete -f deploy/delegation/ --ignore-not-found

agent-conditions agent="orchestrator-agent": guard
    kubectl get agent {{agent}} -n {{namespace}} -o jsonpath='{.status.conditions}' | jq

# Start a Session with the orchestrator and remember its ID in .session-id (Sessions pin the revision they start on)
session: guard
    kagent agent session create --agent orchestrator-agent -o json | jq -r '.session.id' | tee .session-id

# Send a message to the current Session
ask +message:
    kagent agent invoke --session "$(cat .session-id)" --task "{{message}}"

# Foreground UI port-forward (Ctrl+C to stop); `just up` already starts a background one
ui: guard
    kubectl port-forward -n {{namespace}} svc/kagent-ui {{ui_port}}:8080

# Port-forward the UI to http://localhost:{{ui_port}} in the background; safe to re-run. Stop with `just ui-stop`
ui-bg: guard
    #!/usr/bin/env bash
    set -euo pipefail
    listening() { lsof -nP -iTCP:{{ui_port}} -sTCP:LISTEN >/dev/null 2>&1; }
    if listening; then
      echo "UI already reachable on http://localhost:{{ui_port}}"
      exit 0
    fi
    nohup kubectl port-forward -n {{namespace}} svc/kagent-ui {{ui_port}}:8080 >.ui-port-forward.log 2>&1 &
    echo $! > .ui.pid
    for _ in $(seq 20); do
      listening && { echo "UI: http://localhost:{{ui_port}}"; exit 0; }
      sleep 1
    done
    echo "UI port-forward did not start; see .ui-port-forward.log" >&2
    exit 1

# Stop the background UI port-forward (no cluster needed)
ui-stop:
    #!/usr/bin/env bash
    if [[ -f .ui.pid ]]; then
      kill "$(cat .ui.pid)" 2>/dev/null || true
      rm -f .ui.pid
      echo "stopped UI port-forward"
    fi

# Run ngrok in the background (Google sign-in, @logicgate.com only), without tying up a terminal.
# Refuses to start if another ngrok is already running. Optional NGROK_URL. Stop with `just ngrok-stop` (or `just down`).
ngrok-bg: guard ui-bg
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -f .ngrok.pid ]] && kill -0 "$(cat .ngrok.pid)" 2>/dev/null; then
      echo "ngrok already running (pid $(cat .ngrok.pid))"
    elif pgrep -x ngrok >/dev/null; then
      echo "another ngrok is already running (pid $(pgrep -x ngrok | head -1)); stop it first" >&2
      exit 1
    else
      nohup ngrok http {{ui_port}} ${NGROK_URL:+--url "$NGROK_URL"} --traffic-policy-file deploy/ngrok/policy.yml --log=stdout >.ngrok.log 2>&1 &
      echo $! > .ngrok.pid
    fi
    for _ in $(seq 20); do
      url="$(curl -s localhost:4040/api/tunnels | jq -r '.tunnels[0].public_url // empty' 2>/dev/null || true)"
      [[ -n "$url" ]] && { echo "ngrok: $url"; exit 0; }
      sleep 1
    done
    echo "ngrok started but no tunnel is reported yet; see .ngrok.log" >&2

# Stop the background ngrok that `just ngrok-bg` started (never touches an ngrok you started yourself)
ngrok-stop:
    #!/usr/bin/env bash
    if [[ -f .ngrok.pid ]]; then
      kill "$(cat .ngrok.pid)" 2>/dev/null || true
      rm -f .ngrok.pid
      echo "stopped background ngrok"
    fi

# Expose the kagent UI through ngrok with Google sign-in limited to @logicgate.com (deploy/ngrok/policy.yml).
# Optional NGROK_URL=https://<name>.ngrok.app. Never expose controller port 8083.
ngrok: guard ui-bg
    ngrok http {{ui_port}} ${NGROK_URL:+--url "$NGROK_URL"} --traffic-policy-file deploy/ngrok/policy.yml

# Add the GitHub MCP server and github-agent (read-only). Needs GITHUB_TOKEN: fine-grained, one repo, read-only.
github-up: guard
    #!/usr/bin/env bash
    set -euo pipefail
    : "${GITHUB_TOKEN:?export GITHUB_TOKEN first (fine-grained PAT, one repo, read-only; never paste it in chat)}"
    printf 'Bearer %s' "$GITHUB_TOKEN" | kubectl create secret generic github-mcp-credentials -n {{namespace}} \
      --from-file=authorization=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
    kubectl apply -f deploy/github/github-mcp.yaml
    kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'=True \
      remotemcpserver/github-mcp -n {{namespace}} --timeout=120s
    kubectl apply -f deploy/github/github-agent.yaml
    kubectl wait --for=condition=Ready agent/github-agent -n {{namespace}} --timeout=300s
    discovered="$(kubectl get remotemcpserver github-mcp -n {{namespace}} -o jsonpath='{range .status.discoveredTools[*]}{.name}{"\n"}{end}')"
    echo "github-mcp serves $(grep -c . <<<"$discovered") tools"
    for t in $(kubectl get agenttemplate github-template -n {{namespace}} -o json | jq -r '.spec.tools[].mcp.tools[]?'); do
      grep -qxF "$t" <<<"$discovered" || echo "WARNING: bound tool '$t' is not served by github-mcp (kagent will not flag it)"
    done

# Used by `up`: run github-up when GITHUB_TOKEN is set, otherwise skip with a notice
github-maybe: guard
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
      echo "GITHUB_TOKEN not set; skipping github-agent (export it and run 'just github-up' to add it)"
    else
      just github-up
    fi

# Fresh Session on any agent with one question, e.g. `just ask-agent minikube-agent "list the pods"`
ask-agent agent +message: guard
    #!/usr/bin/env bash
    set -euo pipefail
    sid="$(kagent agent session create --agent {{agent}} -o json | jq -r '.session.id')"
    kagent agent invoke --session "$sid" --task "{{message}}"

# Ask each specialist directly, then ask the orchestrator a question that needs all of them
demo: guard
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    run() { echo; echo "=== $1 ==="; just ask-agent "$1" "$2" || { echo "FAILED: $1" >&2; fail=1; }; }
    run minikube-agent "Which pods are running in the kagent namespace?"
    if kubectl get agent github-agent -n {{namespace}} >/dev/null 2>&1; then
      run github-agent "What are the open issues and pull requests in dev-velo/go-kagent?"
    else
      echo; echo "=== github-agent: not installed, skipping ==="
    fi
    run orchestrator-agent "Give me a status report. Use list_agents, then ask every specialist agent you have: which pods run in the kagent namespace, and what issues and pull requests are open in dev-velo/go-kagent. Name which agent answered each part."
    exit $fail

# Ask github-agent directly in a fresh Session
github-ask +message="What are the open issues and pull requests in dev-velo/go-kagent?": guard
    kagent agent session create --agent github-agent -o json | jq -r '.session.id' | tee .session-id-github
    kagent agent invoke --session "$(cat .session-id-github)" --task "{{message}}"

# Remove github-agent, the GitHub MCP server and its token Secret
github-clean: guard
    kubectl delete -f deploy/github/ --ignore-not-found
    kubectl delete secret github-mcp-credentials -n {{namespace}} --ignore-not-found

# Watch the Actor/worker lifecycle while you idle and resume a Session
watch-ate: guard
    kubectl get pods -n ate-system -w
