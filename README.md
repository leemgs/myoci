# myoci

Oracle Cloud Infrastructure(OCI)의 Always Free **ARM(VM.Standard.A1.Flex,
1 OCPU / 6GB)** 인스턴스 생성을 자동으로 시도하고, 생성에 성공하면 이메일로
알려 주는 스크립트입니다. 용량을 더 빨리 확보하기 위해 **fault domain을 순회**
시도하고, OCI가 요청을 제한(HTTP 429)하면 **지수적 백오프**로 물러납니다.

## 주요 파일

- `script/add-arm-instance.sh` — OCI ARM 인스턴스 생성 스크립트 (cron용, 1주기 실행 후 종료)
- `script/update-instance-info.sh` — OCI CLI 조회 결과를 웹 표시용 JSON으로 갱신
- `docs/` — 프로젝트 소개용 정적 웹 페이지 (`main.gif` 애니메이션 히어로 이미지)

실행 중 스크립트가 같은 폴더에 자동 생성/관리하는 파일:

- `add-arm-instance.log` — 실행 로그
- `add-arm-instance.state` — 429 백오프 상태(레벨/해제 시각)
- `add-arm-instance.done` — 성공 lock (존재하면 더 이상 시도하지 않음)
- `add-arm-instance.log.mail.log` — 성공 이메일 전송 시 SMTP 상세 로그

## 동작 방식

한 번 실행하면 아래 순서로 진행하고 종료합니다.

1. **lock 확인** — `*.done`이 있으면(이미 성공) 즉시 종료.
2. **백오프 확인** — 429 백오프 대기 창 안이면 이번 주기를 건너뛰고 종료.
3. **Fault domain 순회 시도** — `FAULT-DOMAIN-1 → 2 → 3` 순으로 launch를 시도.

각 시도 결과에 따른 처리:

| 결과 | 동작 |
| --- | --- |
| 성공 (`"id"` 반환) | lock 생성, 백오프 초기화, **성공 이메일 전송**, 종료 |
| 용량 부족 (Out of host capacity) | 다음 fault domain으로 계속 (3초 간격) |
| 요청 과다 (HTTP 429) | 이번 주기 나머지 FD를 건너뛰고 **백오프 진입** |
| 한도 초과 (LimitExceeded/QuotaExceeded) | lock 생성 후 중단 (사람이 확인 필요) |
| 그 외 예상 밖 응답 | 로그 남기고 다음 FD 시도 |

> **Fault domain 순회 이유**: A1 무료 용량은 fault domain별로 따로 관리되므로,
> 한 FD가 "용량 부족"이어도 다른 FD에는 여유가 있을 수 있습니다. 세 FD를 모두
> 훑어 어느 하나라도 열리면 즉시 확보합니다.

## 429 지수적 백오프

OCI가 테넌시 단위로 요청을 제한(429)하면, 같은 간격으로 계속 두드리는 것은
오히려 역효과입니다. 그래서 429가 나면 대기 시간을 지수적으로 늘립니다.

| 연속 429 | 대기 시간 |
| --- | --- |
| 1회 | 5분 |
| 2회 | 10분 |
| 3회 | 20분 |
| 4회 | 40분 |
| 5회 이상 | 60분 (상한) |

- 대기 시간과 상한은 스크립트 상단 `BACKOFF_BASE_MIN`(기본 5),
  `BACKOFF_MAX_MIN`(기본 60)으로 조정합니다.
- **429가 아닌 응답**(용량 부족·성공 등)이 한 번이라도 오면 백오프는 즉시
  초기화되어 빠른 재시도 주기로 복귀합니다. 즉 쓰로틀이 풀리면 스스로 정상화됩니다.
- 상태는 `add-arm-instance.state`에 저장되며, cron·수동 실행 모두에 적용됩니다.

## 준비 사항

- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) 설치 및 설정 (`~/.oci/config`)
- OCI 인스턴스에 등록할 SSH 공개 키
- 성공 알림을 위한 `s-nail`과 SMTP 설정 파일(`/home/ubuntu/.mailrc`)

Ubuntu에서는 다음 명령으로 `s-nail`을 설치합니다.

```bash
sudo apt install s-nail
sudo ln -s /usr/bin/s-nail /usr/bin/mail
```

`~/.mailrc`에는 Gmail SMTP(STARTTLS, 587, **앱 비밀번호**)를 설정합니다.
성공 이메일은 `mail -v`로 전송되며 실행 로그를 첨부합니다.

## 사용 방법

1. `script/add-arm-instance.sh` 상단의 OCI 리소스 ID, SSH 키 경로,
   인스턴스 사양, fault domain 목록, 이메일 주소를 환경에 맞게 수정합니다.
2. SMTP 비밀번호는 저장소에 기록하지 말고 `/home/ubuntu/.mailrc`에 설정합니다.
3. cron에 등록해 주기적으로 실행합니다 (예: 2분마다).

```cron
*/2 * * * * ubuntu /var/www/html/myoci/script/add-arm-instance.sh
```

수동으로 한 번 실행하려면:

```bash
./script/add-arm-instance.sh
```

백오프 대기 중에는 수동 실행도 "이번 주기 건너뜀"으로 즉시 종료됩니다.
테스트 목적으로 백오프를 무시하고 강제로 시도하려면 상태 파일을 지웁니다.

```bash
rm -f script/add-arm-instance.state
./script/add-arm-instance.sh
```

## 웹에서 인스턴스 정보 확인

`script/update-instance-info.sh`는 서버의 `/etc/environment`에서 OCI 설정을
불러온 뒤 `oci compute instance list`를 실행합니다. 조회 결과는 공개해도 되는
필드만 `docs/instance-info.json`에 저장되며, 웹 페이지가 이 파일을 읽어 인스턴스
이름, 상태, Shape, OCPU, 메모리, AD와 생성 시각을 표시합니다.

OCI CLI를 실행할 서버에서 다음 변수를 `/etc/environment`에 추가합니다. 실제
compartment OCID와 서버 경로에 맞게 값을 변경하세요.

```bash
sudo tee -a /etc/environment >/dev/null <<'EOF'
OCI_CLI_CONFIG_FILE="/home/ubuntu/.oci/config"
OCI_CLI_PROFILE="DEFAULT"
OCI_REGION="ap-tokyo-1"
OCI_COMPARTMENT_ID="ocid1.compartment.oc1..여기에_compartment_OCID"
OCI_INSTANCE_INFO_FILE="/var/www/html/myoci/docs/instance-info.json"
EOF
```

`/etc/environment`에는 OCI API 개인 키 내용이나 SMTP 비밀번호를 넣지 마세요.
OCI CLI 인증 키와 설정 파일은 `ubuntu` 사용자만 읽을 수 있도록 권한을 제한합니다.
설정 후 아래 명령으로 JSON을 생성할 수 있습니다.

```bash
sudo chmod +x /var/www/html/myoci/script/update-instance-info.sh
/var/www/html/myoci/script/update-instance-info.sh
```

인스턴스 상태를 주기적으로 갱신하려면 `crontab -e`에 다음 항목을 등록합니다.

```cron
*/2 * * * * /var/www/html/myoci/script/update-instance-info.sh >> /var/www/html/myoci/script/update-instance-info.log 2>&1
```

웹 서버 프로세스가 `docs/instance-info.json`을 읽을 수 있어야 하고, 스크립트를
실행하는 사용자는 `docs/` 디렉터리에 파일을 생성할 권한이 있어야 합니다.

## 확보 가능성 통계

과거 로그에서는 약 3시간 39분 동안 110회 시도했으며, 성공 0회, 용량 부족
85회, 요청 과다(HTTP 429) 22회가 기록되었습니다. 이 표본의 성공률은 0%지만,
OCI의 가용 용량은 시간대별로 달라지므로 앞으로의 성공 가능성이 0%라는 뜻은
아닙니다. 또한 2분 간격의 요청은 같은 용량 상태를 반복해서 확인할 수 있어
각 시도를 서로 독립적인 기회로 간주하면 안 됩니다.

향후 의미 있는 통계를 얻으려면 최소 1~2주 동안 다음 항목을 보관합니다.

- 요청 시작 시각과 완료까지 걸린 시간
- 성공, 용량 부족, HTTP 429, 한도 초과, 기타 오류의 구분
- OCI CLI 종료 코드
- 요청한 Availability Domain, Fault Domain, Shape, OCPU 및 메모리

설정 오류와 HTTP 429처럼 실제 용량을 확인하지 못한 요청은 제외하고 아래와
같이 유효 시도 성공률을 계산합니다.

```text
유효 시도 성공률 = 성공 횟수 / (전체 시도 - HTTP 429 - 설정 오류)
```

시간대별 성공률도 함께 집계하면 실행 주기를 조정하는 데 도움이 됩니다. API
요청 제한이 반복될 때 고정 간격으로 재시도하지 않도록, 이 스크립트는 위에서
설명한 지수적 백오프(exponential backoff)를 적용합니다.

> `.mailrc`, OCI API 키, SMTP 비밀번호 등 인증 정보는 Git에 커밋하지 마세요.
