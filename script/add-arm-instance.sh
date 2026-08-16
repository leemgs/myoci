#!/bin/bash
# ARM 무료 인스턴스 자동 생성 (cron용 - 1회 시도 후 종료)

# ===== 확인된 값 =====
COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaaai73qezllecwan2mibvjymv2g5u63xmumwbh5ghoya2vwiicckea"
AD="mVhA:AP-TOKYO-1-AD-1"
IMAGE_ID="ocid1.image.oc1.ap-tokyo-1.aaaaaaaa7z7ownzqrqgvf4x6kf2yb7enpdtfm74ao7miu6tkppoenqnt735a"
SUBNET_ID="ocid1.subnet.oc1.ap-tokyo-1.aaaaaaaa42qsegafrbtnp7r4vvvvn3fv65gocrecqjlkd2djzuu3yqeyl6sq"
SSH_KEY_FILE="/home/ubuntu/.ssh/id_rsa.pub"
DISPLAY_NAME="free-arm-01"
SHAPE="VM.Standard.A1.Flex"
OCPUS=1
MEM_GB=6
LOG_FILE="/var/www/html/myoci/script/add-arm-instance.log"
LOCK_FILE="/var/www/html/myoci/script/add-arm-instance.done"
STATE_FILE="/var/www/html/myoci/script/add-arm-instance.state"
EMAIL_TO="leemgs@gmail.com"
MAILRC_FILE="/home/ubuntu/.mailrc"

# ===== 429(TooManyRequests) 적응형 백오프 설정 =====
# 429가 반복되면 대기시간을 지수적으로 늘려(BASE→2배→4배…) OCI 쓰로틀링을 완화한다.
# 429 외 응답(용량부족/타임아웃 등)은 백오프를 초기화해 빠른 재시도 주기를 유지한다.
BACKOFF_BASE_MIN=5     # 첫 429 시 대기(분)
BACKOFF_MAX_MIN=60     # 최대 대기(분) 상한

export PATH="/home/ubuntu/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export OCI_CLI_CONFIG_FILE="/home/ubuntu/.oci/config"

# 화면+로그 동시 출력 함수
log() { echo "$(date) - $*" | tee -a "$LOG_FILE"; }

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

# 이미 성공했으면 즉시 종료
if [ -f "$LOCK_FILE" ]; then
  log "이미 성공(lock 존재). 종료."
  exit 0
fi

# 429 백오프 대기 중이면 이번 주기 건너뜀
read_state
NOW=$(date +%s)
if [ "${BACKOFF_UNTIL:-0}" -gt "$NOW" ]; then
  remain_min=$(( (BACKOFF_UNTIL - NOW + 59) / 60 ))
  log "백오프 대기 중(429, level=$BACKOFF_LEVEL). 약 ${remain_min}분 후 재시도. 이번 주기 건너뜀."
  exit 0
fi

log "시도 중..."

RESULT=$(oci compute instance launch \
  --availability-domain "$AD" \
  --compartment-id "$COMPARTMENT_ID" \
  --shape "$SHAPE" \
  --shape-config "{\"ocpus\": $OCPUS, \"memoryInGBs\": $MEM_GB}" \
  --image-id "$IMAGE_ID" \
  --subnet-id "$SUBNET_ID" \
  --display-name "$DISPLAY_NAME" \
  --assign-public-ip true \
  --ssh-authorized-keys-file "$SSH_KEY_FILE" \
  2>&1)

if echo "$RESULT" | grep -q '"id"'; then
  INSTANCE_ID=$(echo "$RESULT" | sed -n 's/^[[:space:]]*"id":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  log "🎉 성공! 인스턴스 생성됨"
  echo "$RESULT" | grep '"id"' | head -1 | tee -a "$LOG_FILE"
  touch "$LOCK_FILE"
  reset_backoff
  log "lock 생성. 더 이상 시도 안 함."
  send_success_email "${INSTANCE_ID:-확인 불가}"
elif echo "$RESULT" | grep -qi "Out of capacity\|Out of host capacity"; then
  reset_backoff
  log "용량 부족. 다음 주기에 재시도."
elif echo "$RESULT" | grep -qi "TooManyRequests"; then
  log "요청 과다(429). 백오프 진입."
  enter_backoff
elif echo "$RESULT" | grep -qi "LimitExceeded\|QuotaExceeded"; then
  log "⚠️ 한도 초과. 확인 필요. 중단."
  echo "$RESULT" | tee -a "$LOG_FILE"
  touch "$LOCK_FILE"
else
  reset_backoff
  log "예상 밖 응답(다음 주기에 재시도):"
  echo "$RESULT" | tee -a "$LOG_FILE"
fi

exit 0
