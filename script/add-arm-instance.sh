#!/bin/bash
# ARM 무료 인스턴스 자동 생성 (cron용 - 1회 시도 후 종료)

# ===== 확인된 값 =====
COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaaai73qezllecwan2mibvjymv2g5u63xmumwbh5ghoya2vwiicckea"
AD="mVhA:AP-TOKYO-1-AD-1"
# 용량(Out of host capacity)은 fault domain 별로 따로 잡히므로, 한 주기에
# FD-1→2→3 을 순회 시도해 조기 확보 확률을 높인다. (하나라도 성공하면 종료)
FAULT_DOMAINS=("FAULT-DOMAIN-1" "FAULT-DOMAIN-2" "FAULT-DOMAIN-3")
IMAGE_ID="ocid1.image.oc1.ap-tokyo-1.aaaaaaaa7z7ownzqrqgvf4x6kf2yb7enpdtfm74ao7miu6tkppoenqnt735a"
SUBNET_ID="ocid1.subnet.oc1.ap-tokyo-1.aaaaaaaa42qsegafrbtnp7r4vvvvn3fv65gocrecqjlkd2djzuu3yqeyl6sq"
SSH_KEY_FILE="/home/ubuntu/.ssh/id_rsa.pub"
DISPLAY_NAME="free-arm-01"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEM_GB=6
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DATA_DIR="$SCRIPT_DIR/data"
LOG_FILE="$DATA_DIR/add-arm-instance.log"
LOCK_FILE="$DATA_DIR/add-arm-instance.done"
STATE_FILE="$DATA_DIR/add-arm-instance.state"
ARM_STATUS_FILE="$(dirname "$SCRIPT_DIR")/docs/arm-launch-status.json"
EMAIL_TO="leemgs@gmail.com"
MAILRC_FILE="/home/ubuntu/.mailrc"

# ===== 429(TooManyRequests) 적응형 백오프 설정 =====
# 429가 반복되면 대기시간을 지수적으로 늘려(BASE→2배→4배…) OCI 쓰로틀링을 완화한다.
# 429 외 응답(용량부족/타임아웃 등)은 백오프를 초기화해 빠른 재시도 주기를 유지한다.
BACKOFF_BASE_MIN=5     # 첫 429 시 대기(분)
BACKOFF_MAX_MIN=60     # 최대 대기(분) 상한

export PATH="/home/ubuntu/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export OCI_CLI_CONFIG_FILE="/home/ubuntu/.oci/config"

# 로그, lock, 백오프 상태는 Git 소스와 분리된 runtime data 폴더에 저장한다.
mkdir -p "$DATA_DIR" || {
  echo "오류: runtime data 디렉터리를 생성할 수 없습니다: $DATA_DIR" >&2
  exit 1
}

# 예전 버전이 script/ 바로 아래에 만들던 log/state 파일은 더 이상 사용하지 않는다.
# 현재 runtime 원본은 모두 script/data/에 있으므로 중복 파일을 자동 정리한다.
cleanup_legacy_runtime_files() {
  local legacy_file
  local legacy_files=("$SCRIPT_DIR"/*.log "$SCRIPT_DIR"/*.state)

  for legacy_file in "${legacy_files[@]}"; do
    if [ -e "$legacy_file" ] || [ -L "$legacy_file" ]; then
      if rm -f -- "$legacy_file"; then
        echo "이전 runtime 파일 제거: $legacy_file"
      else
        echo "경고: 이전 runtime 파일을 제거할 수 없습니다: $legacy_file" >&2
      fi
    fi
  done
}

cleanup_legacy_runtime_files

# 화면+로그 동시 출력 함수
log() { echo "$(date) - $*" | tee -a "$LOG_FILE"; }

# ARM 생성 시도 결과를 웹에서 읽을 수 있는 JSON으로 안전하게 교체한다.
publish_launch_status() {
  local status="$1"
  local message="$2"
  local fault_domain="${3:-}"
  local details="${4:-}"
  local output_dir
  local output_tmp

  output_dir=$(dirname "$ARM_STATUS_FILE")
  mkdir -p "$output_dir" || return 1
  output_tmp=$(mktemp "$output_dir/.arm-launch-status.XXXXXX") || return 1

  STATUS_FILE="$output_tmp" STATUS="$status" MESSAGE="$message" \
  FAULT_DOMAIN="$fault_domain" DETAILS="$details" DISPLAY_NAME="$DISPLAY_NAME" \
  SHAPE="$SHAPE" OCPUS="$OCPUS" MEM_GB="$MEM_GB" AD="$AD" \
  BACKOFF_LEVEL="${BACKOFF_LEVEL:-0}" BACKOFF_UNTIL="${BACKOFF_UNTIL:-0}" \
  python3 <<'PY'
import json
import os
from datetime import datetime, timezone

backoff_until = int(os.environ["BACKOFF_UNTIL"] or 0)
next_retry_at = None
if backoff_until > 0:
    next_retry_at = datetime.fromtimestamp(backoff_until, timezone.utc).isoformat()

payload = {
    "updatedAt": datetime.now(timezone.utc).isoformat(),
    "status": os.environ["STATUS"],
    "message": os.environ["MESSAGE"],
    "details": os.environ["DETAILS"][:2000] or None,
    "displayName": os.environ["DISPLAY_NAME"],
    "shape": os.environ["SHAPE"],
    "ocpus": int(os.environ["OCPUS"]),
    "memoryInGBs": int(os.environ["MEM_GB"]),
    "availabilityDomain": os.environ["AD"],
    "faultDomain": os.environ["FAULT_DOMAIN"] or None,
    "backoffLevel": int(os.environ["BACKOFF_LEVEL"] or 0),
    "nextRetryAt": next_retry_at,
}

with open(os.environ["STATUS_FILE"], "w", encoding="utf-8") as target:
    json.dump(payload, target, ensure_ascii=False, indent=2)
    target.write("\n")
PY
  if [ "$?" -ne 0 ]; then
    rm -f "$output_tmp"
    return 1
  fi

  chmod 0644 "$output_tmp"
  mv -f "$output_tmp" "$ARM_STATUS_FILE"
}

# ---- 백오프 상태 파일 입출력 (source 대신 안전하게 파싱) ----
BACKOFF_LEVEL=0
BACKOFF_UNTIL=0

read_state() {
  BACKOFF_LEVEL=0
  BACKOFF_UNTIL=0
  if [ -r "$STATE_FILE" ]; then
    BACKOFF_LEVEL=$(sed -n 's/^BACKOFF_LEVEL=\([0-9]\{1,\}\).*/\1/p' "$STATE_FILE" | head -1)
    BACKOFF_UNTIL=$(sed -n 's/^BACKOFF_UNTIL=\([0-9]\{1,\}\).*/\1/p' "$STATE_FILE" | head -1)
    [ -z "$BACKOFF_LEVEL" ] && BACKOFF_LEVEL=0
    [ -z "$BACKOFF_UNTIL" ] && BACKOFF_UNTIL=0
  fi
}

write_state() { printf 'BACKOFF_LEVEL=%s\nBACKOFF_UNTIL=%s\n' "$1" "$2" > "$STATE_FILE"; }

# 429 외 응답: 백오프 초기화(상태 파일이 남아있을 때만 기록)
reset_backoff() {
  if [ "${BACKOFF_LEVEL:-0}" -ne 0 ] || [ "${BACKOFF_UNTIL:-0}" -ne 0 ]; then
    write_state 0 0
    log "백오프 초기화(정상 주기 복귀)."
  fi
}

# 429 응답: 대기시간을 지수적으로 늘리고 다음 실행부터 그만큼 건너뜀
enter_backoff() {
  local level=$(( ${BACKOFF_LEVEL:-0} + 1 ))
  local mins=$BACKOFF_BASE_MIN i=1
  while [ "$i" -lt "$level" ]; do mins=$(( mins * 2 )); i=$(( i + 1 )); done
  [ "$mins" -gt "$BACKOFF_MAX_MIN" ] && mins=$BACKOFF_MAX_MIN
  local until=$(( $(date +%s) + mins * 60 ))
  write_state "$level" "$until"
  log "⏳ 429 백오프: ${mins}분 대기 (level=$level, $(date -d "@$until" '+%H:%M:%S' 2>/dev/null || echo "$until") 까지 건너뜀)."
}

# s-nail(mail)과 MAILRC_FILE에 설정된 Gmail SMTP 계정으로 성공 알림 전송
#
# 사전 준비(최초 1회):
#   sudo apt install s-nail
#   sudo ln -s /usr/bin/s-nail /usr/bin/mail
#   ~/.mailrc 에 Gmail SMTP(STARTTLS, 587, 앱 비밀번호) 설정 작성
send_success_email() {
  local instance_id="$1"
  local subject="[OCI] ARM 인스턴스 생성 성공: $DISPLAY_NAME"
  local mail_verbose_log="${LOG_FILE}.mail.log"

  # mail(s-nail) 미설치 시 설치 방법 안내
  if ! command -v mail >/dev/null 2>&1; then
    log "⚠️ 성공 이메일 전송 실패: mail(s-nail) 명령 없음. 설치: 'sudo apt install s-nail && sudo ln -s /usr/bin/s-nail /usr/bin/mail'"
    return 1
  fi

  # SMTP 설정(~/.mailrc) 확인
  if [ ! -r "$MAILRC_FILE" ]; then
    log "⚠️ 성공 이메일 전송 실패: SMTP 설정 파일 $MAILRC_FILE 을(를) 읽을 수 없음"
    return 1
  fi

  # 메일 본문 구성
  local body
  body=$(printf '%s\n' \
    "OCI ARM 인스턴스 생성이 성공했습니다. 🎉" \
    "" \
    "이름               : $DISPLAY_NAME" \
    "인스턴스 ID        : $instance_id" \
    "Shape              : $SHAPE" \
    "OCPU               : $OCPUS" \
    "Memory(GB)         : $MEM_GB" \
    "Availability Domain: $AD" \
    "생성 시각          : $(date)" \
    "" \
    "상세 로그는 첨부한 $(basename "$LOG_FILE") 파일을 참고하세요.")

  # ~/.mailrc 의 Gmail SMTP 계정으로 전송 (-v 상세, -a 로그 첨부)
  # 상세 SMTP 로그는 첨부 파일 훼손을 막기 위해 별도 파일에 기록
  if printf '%s\n' "$body" \
      | MAILRC="$MAILRC_FILE" mail -v -s "$subject" -a "$LOG_FILE" "$EMAIL_TO" \
        >"$mail_verbose_log" 2>&1; then
    log "성공 이메일 전송 완료: $EMAIL_TO (SMTP 상세 로그: $mail_verbose_log)"
  else
    log "⚠️ 성공 이메일 전송 실패: $EMAIL_TO. SMTP 설정/앱 비밀번호 확인 필요 (상세: $mail_verbose_log)"
    return 1
  fi
}

# 인스턴스 생성 여부와 관계없이 현재 OCI 상태를 웹 표시용 JSON으로 갱신한다.
# 이미 성공 lock이 존재해도 cron 실행 때마다 최신 상태를 반영한다.
refresh_instance_info() {
  local updater="$SCRIPT_DIR/update-instance-info.sh"

  if [ ! -x "$updater" ]; then
    log "⚠️ 웹 인스턴스 정보 갱신 실패: 실행 가능한 $updater 파일이 없음"
    return 1
  fi

  if "$updater" >>"$LOG_FILE" 2>&1; then
    return 0
  fi

  log "⚠️ 웹 인스턴스 정보 갱신 실패. $updater 또는 /etc/environment를 확인하세요."
  return 1
}

# add-arm-instance.sh가 기존 cron에 이미 등록되어 있으면 별도 cron 없이도 갱신된다.
refresh_instance_info

# 이미 성공했으면 즉시 종료
if [ -f "$LOCK_FILE" ]; then
  if [ ! -r "$ARM_STATUS_FILE" ]; then
    publish_launch_status \
      "LOCKED" \
      "실행 중단 lock이 존재합니다. 기존 로그에서 성공 또는 한도 초과 결과를 확인하세요." \
      "" \
      "lock file: $LOCK_FILE"
  fi
  log "이미 성공(lock 존재). 종료."
  exit 0
fi

# 429 백오프 대기 중이면 이번 주기 건너뜀
read_state
NOW=$(date +%s)
if [ "${BACKOFF_UNTIL:-0}" -gt "$NOW" ]; then
  remain_min=$(( (BACKOFF_UNTIL - NOW + 59) / 60 ))
  log "백오프 대기 중(429, level=$BACKOFF_LEVEL). 약 ${remain_min}분 후 재시도. 이번 주기 건너뜀."
  publish_launch_status \
    "BACKOFF" \
    "OCI 요청 제한으로 백오프 대기 중입니다. 약 ${remain_min}분 후 재시도합니다." \
    "" \
    "HTTP 429 · backoff level=$BACKOFF_LEVEL"
  exit 0
fi

# 지정한 fault domain 으로 1회 launch 시도
launch_instance() {
  local fd="$1"
  oci compute instance launch \
    --availability-domain "$AD" \
    --compartment-id "$COMPARTMENT_ID" \
    --fault-domain "$fd" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEM_GB}" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --display-name "$DISPLAY_NAME" \
    --assign-public-ip true \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    2>&1
}

# 모든 fault domain 을 순회 시도 (용량은 FD별로 다를 수 있어 조기 확보 확률↑)
launched=0
saw_429=0
saw_capacity=0
unexpected=""

for FD in "${FAULT_DOMAINS[@]}"; do
  log "시도 중... ($FD)"
  publish_launch_status "ATTEMPTING" "ARM 인스턴스 생성을 시도하고 있습니다." "$FD"
  RESULT=$(launch_instance "$FD")

  if echo "$RESULT" | grep -q '"id"'; then
    INSTANCE_ID=$(echo "$RESULT" | sed -n 's/^[[:space:]]*"id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    log "🎉 성공! 인스턴스 생성됨 ($FD)"
    echo "$RESULT" | grep '"id"' | head -1 | tee -a "$LOG_FILE"
    touch "$LOCK_FILE"
    reset_backoff
    log "lock 생성. 더 이상 시도 안 함."
    publish_launch_status \
      "SUCCESS" \
      "ARM 인스턴스 생성에 성공했습니다." \
      "$FD" \
      "인스턴스 ID: ${INSTANCE_ID:-확인 불가}"
    send_success_email "${INSTANCE_ID:-확인 불가}"
    launched=1
    break

  elif echo "$RESULT" | grep -qi "TooManyRequests\|Too many requests"; then
    # 429는 사용자(테넌시) 단위 쓰로틀 → 이번 주기 나머지 FD는 무의미, 중단하고 백오프
    saw_429=1
    log "요청 과다(429) ($FD). 이번 주기 나머지 FD 건너뜀."
    break

  elif echo "$RESULT" | grep -qi "Out of capacity\|Out of host capacity"; then
    saw_capacity=1
    log "용량 부족 ($FD). 다음 FD 시도."
    sleep 3
    continue

  elif echo "$RESULT" | grep -qi "LimitExceeded\|QuotaExceeded"; then
    log "⚠️ 한도 초과. 확인 필요. 중단."
    echo "$RESULT" | tee -a "$LOG_FILE"
    touch "$LOCK_FILE"
    publish_launch_status \
      "LIMIT_EXCEEDED" \
      "OCI 서비스 한도 또는 할당량을 초과하여 생성이 중단되었습니다." \
      "$FD" \
      "$RESULT"
    exit 0

  else
    unexpected="$RESULT"
    log "예상 밖 응답 ($FD). 다음 FD 시도."
    sleep 3
    continue
  fi
done

# 이번 주기 결과에 따른 백오프 처리
if [ "$launched" -eq 1 ]; then
  :   # 성공 처리 완료
elif [ "$saw_429" -eq 1 ]; then
  enter_backoff
  publish_launch_status \
    "THROTTLED" \
    "OCI HTTP 429 요청 제한이 발생하여 백오프에 진입했습니다." \
    "$FD" \
    "$RESULT"
else
  reset_backoff
  if [ "$saw_capacity" -eq 1 ]; then
    log "모든 FD 용량 부족. 다음 주기에 재시도."
    publish_launch_status \
      "CAPACITY_SHORTAGE" \
      "모든 Fault Domain에서 ARM 가용 용량이 부족했습니다. 다음 주기에 재시도합니다." \
      "" \
      "Out of host capacity"
  fi
  if [ -n "$unexpected" ]; then
    log "예상 밖 응답 상세:"
    echo "$unexpected" | tee -a "$LOG_FILE"
    publish_launch_status \
      "ERROR" \
      "ARM 인스턴스 생성 중 예상하지 못한 오류가 발생했습니다." \
      "" \
      "$unexpected"
  fi
fi

exit 0
