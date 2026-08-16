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
LOG_FILE="/etc/script/add-arm-instance.log"
LOCK_FILE="/etc/script/add-arm-instance.done"

export PATH="/home/ubuntu/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export OCI_CLI_CONFIG_FILE="/home/ubuntu/.oci/config"

# 화면+로그 동시 출력 함수
log() { echo "$(date) - $*" | tee -a "$LOG_FILE"; }

# 이미 성공했으면 즉시 종료
if [ -f "$LOCK_FILE" ]; then
  log "이미 성공(lock 존재). 종료."
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
  log "🎉 성공! 인스턴스 생성됨"
  echo "$RESULT" | grep '"id"' | head -1 | tee -a "$LOG_FILE"
  touch "$LOCK_FILE"
  log "lock 생성. 더 이상 시도 안 함."
elif echo "$RESULT" | grep -qi "Out of capacity\|Out of host capacity"; then
  log "용량 부족. 다음 주기에 재시도."
elif echo "$RESULT" | grep -qi "TooManyRequests"; then
  log "요청 과다(429). 다음 주기에 재시도."
elif echo "$RESULT" | grep -qi "LimitExceeded\|QuotaExceeded"; then
  log "⚠️ 한도 초과. 확인 필요. 중단."
  echo "$RESULT" | tee -a "$LOG_FILE"
  touch "$LOCK_FILE"
else
  log "예상 밖 응답:"
  echo "$RESULT" | tee -a "$LOG_FILE"
fi

exit 0
