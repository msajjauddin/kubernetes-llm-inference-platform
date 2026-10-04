#!/usr/bin/env bash
# Creates the Secret the LiteLLM chart reads (shape: k8s/litellm/secret.example.yaml) with random
# values, unless it already exists. Keys never touch Git or disk (SEC-5).
#
# Usage: scripts/create-litellm-secrets.sh            # namespace llm, secret litellm-secrets
#        NS=llm SECRET=litellm-secrets scripts/create-litellm-secrets.sh
#
# Production: keep these in AWS Secrets Manager and sync them with External Secrets Operator.
# Never change LITELLM_SALT_KEY once the database has data; it encrypts stored credentials.
set -euo pipefail

NS="${NS:-llm}"
SECRET="${SECRET:-litellm-secrets}"

if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
  echo "Secret $NS/$SECRET already exists; leaving it alone."
  exit 0
fi

# Hex only, so the passwords are safe inside the postgresql:// URL.
rand() { openssl rand -hex "$1"; }

kubectl -n "$NS" create secret generic "$SECRET" \
  --from-literal=LITELLM_MASTER_KEY="sk-$(rand 24)" \
  --from-literal=LITELLM_SALT_KEY="sk-$(rand 24)" \
  --from-literal=LITELLM_METRICS_TOKEN="sk-$(rand 24)" \
  --from-literal=POSTGRES_PASSWORD="$(rand 24)" \
  --from-literal=REDIS_PASSWORD="$(rand 24)"

echo "Created $NS/$SECRET. Master key:"
echo "  kubectl -n $NS get secret $SECRET -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d"
