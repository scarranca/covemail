#!/usr/bin/env bash
set -euo pipefail
GCLOUD="${GCLOUD:-gcloud}"
PROJECT=cove-mail-20260922
REGION=us-east1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Supply a local non-secret YAML file: GOOGLE_CLIENT_IDS and PILOT_EMAILS, plus (for new-mail push)
# APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC, PUSH_AUDIENCE and PUSH_SERVICE_ACCOUNT. Set COVE_APNS_SECRET_VERSION
# to mount the pinned cove-apns-key version as APNS_KEY; without it push stays off.
: "${COVE_SYNC_ENV_FILE:?Set COVE_SYNC_ENV_FILE to a local environment YAML file}"
: "${COVE_DB_SECRET_VERSION:?Pin the tested restricted database secret version}"
IMAGE="$REGION-docker.pkg.dev/$PROJECT/cove-sync/api:$(date -u +%Y%m%d%H%M%S)"
"$GCLOUD" builds submit "$ROOT" --tag="$IMAGE" --project="$PROJECT" --region="$REGION" --quiet
# Public HTTPS ingress; every mail route independently verifies a Google ID token and pilot allowlist.
# Revision and service caps prevent an ordinary rollout from leaving extra baseline instances.
"$GCLOUD" run deploy cove-sync-api --image="$IMAGE" --project="$PROJECT" --region="$REGION" \
  --service-account="cove-sync-api@$PROJECT.iam.gserviceaccount.com" \
  --min=0 --min-instances=0 --max=2 --max-instances=2 --concurrency=8 --cpu=1 --memory=512Mi \
  --cpu-throttling --timeout=60 --no-invoker-iam-check \
  --env-vars-file="$COVE_SYNC_ENV_FILE" \
  --set-secrets="DATABASE_URL=cove-sync-database-url:$COVE_DB_SECRET_VERSION${COVE_APNS_SECRET_VERSION:+,APNS_KEY=cove-apns-key:$COVE_APNS_SECRET_VERSION}" --quiet
