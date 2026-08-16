# myoci

Oracle Cloud Infrastructure(OCI)의 Always Free ARM 인스턴스 생성을 자동으로
시도하고, 생성에 성공하면 이메일로 알려 주는 간단한 스크립트입니다.

## 주요 파일

- `script/add-arm-instance.sh`: OCI ARM 인스턴스 생성 스크립트
- `docs/`: 프로젝트 소개용 정적 웹 페이지

## 준비 사항

- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm) 설치 및 설정
- OCI 인스턴스에 등록할 SSH 공개 키
- 성공 알림을 위한 `s-nail`과 SMTP 설정 파일(`/home/ubuntu/.mailrc`)

Ubuntu에서는 다음 명령으로 `s-nail`을 설치할 수 있습니다.

```bash
sudo apt install s-nail
sudo ln -s /usr/bin/s-nail /usr/bin/mail
```

## 사용 방법

1. `script/add-arm-instance.sh` 상단의 OCI 리소스 ID, SSH 키 경로,
   인스턴스 사양과 이메일 주소를 환경에 맞게 수정합니다.
2. SMTP 비밀번호는 저장소에 기록하지 말고 `/home/ubuntu/.mailrc`에 설정합니다.
3. 스크립트를 실행합니다.

```bash
./script/add-arm-instance.sh
```

인스턴스 생성에 성공하면 lock 파일을 생성하여 중복 실행을 방지하고,
설정된 수신자에게 인스턴스 정보를 이메일로 전송합니다. 용량 부족이나 요청
제한이 발생하면 다음 실행 시 다시 시도할 수 있습니다.

> `.mailrc`, OCI API 키, SMTP 비밀번호 등 인증 정보는 Git에 커밋하지 마세요.
