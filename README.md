# Claude Code Sandbox

Docker 기반 Claude Code 격리 실행 환경. Mac / Linux / WSL / Git Bash 지원.

## 요구사항

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- WSL 사용 시: Docker Desktop → Settings → Resources → WSL Integration 활성화
- Vertex AI 인증 (gcloud) 또는 `ANTHROPIC_API_KEY`

## 설치

### Mac / Linux / WSL

```bash
bash install.sh
source ~/.bashrc   # 또는 source ~/.zshrc
```

### Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

## 실행

```bash
# 현재 디렉토리를 프로젝트로 실행
claude-sandbox

# 특정 프로젝트 지정
claude-sandbox /path/to/project

# Docker 이미지 강제 재빌드
claude-sandbox --rebuild
```

## Harness workflow gate 보호 모드

프로젝트에 Harness Claude workflow gate가 설치되어 있으면 컨테이너 시작 시 자동으로 보호 모드가 적용됩니다.

감지 조건:

```text
<project>/.claude/hooks/workflow-gate.cjs
```

보호 모드에서 컨테이너는 두 유저를 사용합니다.

```text
node  : Claude Code 실행 유저
gate  : workflow gate/state/authority 전용 유저
```

적용 내용:

- `.claude/settings.json`의 hook command를 `/usr/local/bin/workflow-gate ...`로 패치
- `/workflow:*` command 파일의 gate 호출도 `/usr/local/bin/workflow-gate`로 패치
- 컨테이너 시작 시 project hook을 `/opt/harness-workflow-gate/workflow-gate.cjs`로 복사하고 `gate` 소유 read-only 실행 파일로 고정
- `/usr/local/bin/workflow-gate`는 `sudo -u gate`로 `/opt/harness-workflow-gate/workflow-gate.cjs`를 실행
- project 안의 mutable hook JS를 elevated 권한으로 직접 실행하지 않음
- `node` 유저는 아래 경로를 직접 읽거나 수정할 수 없도록 권한 변경

```text
.harness/state.json
.harness/workflow.json
.harness/policy.yaml
.harness/authority/**
.harness/.authority-runtime/**
.harness/checkpoints/**
.harness/dpaa-runs/**
```

또한 아래 경로는 `node` 유저가 수정할 수 없도록 read-only로 둡니다.

```text
.claude/settings.json
.claude/hooks/**
.claude/commands/workflow/**
```

즉 Claude Code는 `--dangerously-skip-permissions`로 실행되더라도 Bash에서 authority token/state/hook을 직접 조작하기 어렵고, gate helper를 통한 검증된 경로로만 workflow 상태를 바꿉니다. 또한 `gate` 유저도 mounted workspace에서 git을 사용할 수 있도록 `safe.directory`를 system scope에 등록합니다.

보호 모드를 끄려면:

```bash
CLAUDE_SANDBOX_PROTECT_HARNESS=0 claude-sandbox
```

주의:

- 보호 모드는 mounted workspace의 파일 소유자/권한을 컨테이너 내부 기준으로 변경합니다. Docker Desktop/Windows bind mount에서는 제한적으로 동작할 수 있습니다.
- workspace root 자체가 writable인 bind mount에서는 `.claude`/`.harness` 디렉토리 교체 같은 공격을 완벽히 막는 보안 경계가 아니라 강한 guardrail로 보아야 합니다. 더 강한 격리는 protected path를 별도 read-only/named volume으로 분리해야 합니다.
- Harness 설정을 업데이트하려면 보호 모드를 끄고 실행하거나 host에서 업데이트한 뒤 `claude-sandbox --rebuild`로 다시 실행하세요.

## 인증

### Vertex AI (기본)

WSL / Linux에 gcloud 설치 후 인증:

```bash
curl https://sdk.cloud.google.com | bash
exec -l $SHELL
gcloud auth application-default login
```

### Anthropic API Key (대안)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
claude-sandbox
```

## 구조

```
sandbox/
├── claude-sandbox.sh   # 메인 실행 스크립트
├── Dockerfile          # 컨테이너 이미지 정의
├── entrypoint.sh       # 컨테이너 시작 스크립트
├── install.sh          # Mac/Linux/WSL 설치 스크립트
├── install.ps1         # Windows PowerShell 설치 스크립트
├── ca-bundle.pem       # (선택) 사내 CA 인증서
└── workspace-settings.json
```

## 참고

- 세션 재개: 종료 후 출력되는 `claude-sandbox --resume <session_id>` 사용
- 사내 SSL 인증서가 필요한 경우 `ca-bundle.pem`을 sandbox 디렉토리에 배치
