#!/bin/bash
# OCI CLI 조회 결과를 웹 페이지에서 읽을 수 있는 JSON으로 갱신한다.

set -u

ENV_FILE="/etc/environment"

if [ ! -r "$ENV_FILE" ]; then
  echo "오류: $ENV_FILE 파일을 읽을 수 없습니다." >&2
  exit 1
fi

# /etc/environment에 저장한 OCI_* 변수를 현재 프로세스로 불러온다.
set -a
# shellcheck disable=SC1091
. "$ENV_FILE"
set +a

: "${OCI_COMPARTMENT_ID:?/etc/environment에 OCI_COMPARTMENT_ID를 설정하세요.}"
: "${OCI_REGION:?/etc/environment에 OCI_REGION을 설정하세요.}"

OCI_CLI_CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-/home/ubuntu/.oci/config}"
OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
OCI_INSTANCE_INFO_FILE="${OCI_INSTANCE_INFO_FILE:-/var/www/html/myoci/docs/instance-info.json}"
export OCI_CLI_CONFIG_FILE

if ! command -v oci >/dev/null 2>&1; then
  echo "오류: oci 명령을 찾을 수 없습니다." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "오류: python3 명령을 찾을 수 없습니다." >&2
  exit 1
fi

output_dir=$(dirname "$OCI_INSTANCE_INFO_FILE")
mkdir -p "$output_dir"
work_dir=$(mktemp -d "$output_dir/.instance-info.XXXXXX") || exit 1
trap 'rm -rf "$work_dir"' EXIT

raw_file="$work_dir/oci-instances.json"
output_file="$work_dir/instance-info.json"

# 웹에는 인스턴스 조회 결과 중 운영에 필요한 필드만 공개한다.
if ! oci compute instance list \
  --compartment-id "$OCI_COMPARTMENT_ID" \
  --region "$OCI_REGION" \
  --profile "$OCI_CLI_PROFILE" \
  --all \
  --output json >"$raw_file"; then
  echo "오류: OCI 인스턴스 조회에 실패했습니다." >&2
  exit 1
fi

RAW_FILE="$raw_file" OUTPUT_FILE="$output_file" OCI_REGION="$OCI_REGION" \
python3 <<'PY'
import json
import os
from datetime import datetime, timezone

with open(os.environ["RAW_FILE"], encoding="utf-8") as source:
    response = json.load(source)

instances = []
for item in response.get("data", []):
    state = item.get("lifecycle-state", "UNKNOWN")
    if state == "TERMINATED":
        continue

    shape_config = item.get("shape-config") or {}
    instances.append(
        {
            "displayName": item.get("display-name", "-"),
            "id": item.get("id", "-"),
            "lifecycleState": state,
            "shape": item.get("shape", "-"),
            "ocpus": shape_config.get("ocpus"),
            "memoryInGBs": shape_config.get("memory-in-gbs"),
            "availabilityDomain": item.get("availability-domain", "-"),
            "timeCreated": item.get("time-created"),
        }
    )

payload = {
    "updatedAt": datetime.now(timezone.utc).isoformat(),
    "region": os.environ["OCI_REGION"],
    "instances": instances,
}

with open(os.environ["OUTPUT_FILE"], "w", encoding="utf-8") as target:
    json.dump(payload, target, ensure_ascii=False, indent=2)
    target.write("\n")
PY

chmod 0644 "$output_file"
mv -f "$output_file" "$OCI_INSTANCE_INFO_FILE"
echo "OCI 인스턴스 정보 갱신 완료: $OCI_INSTANCE_INFO_FILE"
