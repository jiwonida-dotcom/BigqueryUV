# 첫방문UV 월간 리포트 플랫폼

GA4 탐색 리포트 **「첫방문UV (\*빅쿼리 생성용)」** 과 동일한 리포트를 BigQuery에서 월 단위로
자동 추출해 Cloudflare Pages 대시보드로 제공합니다.

```
매월 2일 10:17 KST
GitHub Actions ──▶ BigQuery (uplusumobile.analytics_253244174)
      │                 sql/monthly_uv.sql 실행
      ▼
site/data/YYYY-MM.json 커밋/푸시
      │
      ▼
Cloudflare Pages 자동 배포 ──▶ 월 선택 대시보드 (+ CSV 다운로드)
```

## 리포트 정의 (GA4 탐색과 동일하게 재현)

| 항목 | 내용 |
|---|---|
| 세그먼트 | 첫방문(세션): `ga_session_number = 1` 인 신규 사용자 세션. 단, 방문 페이지+쿼리 문자열이 `^(/my/.*\|/mypg/.*\|/bill/.*\|/api/login/after\|/api/login/easy\|/api/login/finger-print\|/api/login/face-id\|/api/login/id-pw\|/util/pw/.*\|/login/rest/.*\|/my/main\|/login\|/login/app\|/login/id-pw\|/util/id/find)$` 와 일치하는 세션 제외 |
| 행 | 날짜 × 세션 기본 채널 그룹(맞춤채널(운영)) × 세션 소스/매체 |
| 값 | 총 사용자 (`COUNT(DISTINCT user_pseudo_id)`) |
| 필터 | 맞춤채널(운영) ≠ 바이럴 |

맞춤채널(운영) 8개 채널의 판정 규칙(순서·대소문자 포함)은 GA4 관리 화면의 정의를
`sql/monthly_uv.sql` 의 `CASE` 문으로 그대로 옮겼습니다. **GA4에서 채널 그룹 규칙을
수정하면 이 SQL도 함께 수정해야 합니다.**

> ⚠️ **수치 차이 안내**: GA4 탐색 UI는 샘플링·추정(HLL)·비공개 임계값이 적용된 수치를
> 보여줍니다(현재 탐색 리포트의 값이 모두 17의 배수인 것이 샘플링 흔적입니다).
> BigQuery는 원시 이벤트를 정확히 집계하므로 **UI와 수치가 다소 다를 수 있으며,
> BigQuery 쪽이 더 정확한 값**입니다. 또한 BigQuery 내보내기에서 제외된 89개
> 이벤트는 집계에 포함되지 않습니다.

## 최초 설정 (1회)

### 1. GCP 서비스 계정 발급

[GCP 콘솔](https://console.cloud.google.com/iam-admin/serviceaccounts?project=uplusumobile) → 프로젝트 `uplusumobile`

1. **서비스 계정 만들기** → 이름 예: `ga4-monthly-report`
2. 역할 부여: **BigQuery 작업 사용자**(`roles/bigquery.jobUser`)
   그리고 **BigQuery 데이터 뷰어**(`roles/bigquery.dataViewer`)
   — 데이터 뷰어는 프로젝트 전체 대신 `analytics_253244174` 데이터셋에만 부여해도 됩니다
   (BigQuery 콘솔 → 데이터셋 → 공유 → 주 구성원 추가).
3. 만든 서비스 계정 → **키** 탭 → **키 추가 → JSON** → 키 파일 다운로드.

### 2. GitHub Secrets 등록

이 리포( `jiwonida-dotcom/BigqueryUV` ) → **Settings → Secrets and variables → Actions → New repository secret**

| 이름 | 값 |
|---|---|
| `GCP_SA_KEY` | 위에서 받은 JSON 키 파일의 **내용 전체** 붙여넣기 |

키 파일은 등록 후 로컬에서 삭제하고, 절대 리포에 커밋하지 마세요.

### 3. Cloudflare Pages 연결

[Cloudflare 대시보드](https://dash.cloudflare.com) → **Workers & Pages → Create → Pages →
Connect to Git** → `jiwonida-dotcom/BigqueryUV` 선택

| 설정 | 값 |
|---|---|
| Production branch | `main` |
| Build command | (비움) |
| Build output directory | `site` |

이후 GitHub Actions가 데이터를 커밋할 때마다 자동으로 재배포됩니다.

### 4. 접근 제한 (Cloudflare Access — 무료)

사내 데이터이므로 공개 URL 노출을 막습니다.

1. Cloudflare 대시보드 → **Zero Trust** (처음이면 무료 플랜 선택) → **Access → Applications → Add an application → Self-hosted**
2. Application domain: Pages 도메인 (예: `bigqueryuv.pages.dev`) — `*.bigqueryuv.pages.dev` 와 프리뷰 도메인도 함께 추가 권장
3. Policy: Action **Allow**, Include → **Emails / Emails ending in** 에 허용할 사내 이메일(또는 도메인) 입력
4. 저장하면 접속 시 이메일 OTP 인증을 거칩니다.

## 사용법

### 자동 실행
매월 **2일 10:17 KST** 에 지난달 데이터를 추출합니다. (GA4 일일 내보내기가 최대 72시간
지연될 수 있어 1일이 아닌 2일에 실행하며, 말일 테이블이 아직 없으면 실패 처리되므로
Actions 탭에서 **Re-run** 하면 됩니다.)

### 수동 실행 / 과거 월 백필
GitHub → **Actions → 월간 첫방문UV 리포트 추출 → Run workflow**
- `month` 에 `2026-08` 처럼 입력하면 해당 월을 추출 (비우면 지난달)
- 진행 중인 달을 미리 보려면 `allow_partial` 체크

GA4 → BigQuery 연동이 2026-07-21에 생성되었으므로 **2026-08월부터** 백필 가능합니다.

### 로컬 실행 (선택)
```bash
pip install google-cloud-bigquery
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json
python scripts/extract_monthly.py 2026-08
```

## 파일 구조

```
.github/workflows/monthly-report.yml   # 월간 스케줄 + 수동 실행 워크플로
sql/monthly_uv.sql                     # 리포트 재현 쿼리 (채널 규칙·세그먼트 포함)
scripts/extract_monthly.py             # 추출 → site/data/*.json 생성
site/index.html                        # 대시보드 (월 선택·차트·테이블·CSV)
site/data/index.json                   # 추출된 월 목록
site/data/YYYY-MM.json                 # 월별 데이터
```

## 비용

- BigQuery: 월 1회 쿼리, 일 0.75M 이벤트 기준 한 달 스캔량 수 GB 수준 → 무료 한도(월 1TB) 내
- GitHub Actions: 월 1회 수 분 → 무료 한도 내
- Cloudflare Pages / Access: 무료 플랜으로 충분

## 코드 배포 (github-push.cmd)

로컬 수정 사항을 GitHub에 반영하는 Windows 스크립트. 더블클릭 또는 명령 프롬프트에서 실행.

| 실행 | 동작 |
|---|---|
| `github-push.cmd` | patch 버전 증가 (v1.0.0 → v1.0.1) |
| `github-push.cmd minor` | minor 버전 증가 (v1.0.1 → v1.1.0) |
| `github-push.cmd major` | major 버전 증가 (v1.1.0 → v2.0.0) |
| `github-push.cmd "메시지"` | 배포 메시지 제목 직접 지정 |
| `github-push.cmd -y` | 확인 절차 생략 |

- 최초 실행: git 초기화, 원격 연결, `v1.0.0` 태그로 최초 배포
- 배포 메시지: 버전·일시·변경 영역·변경 파일 목록 자동 생성
- 서비스 계정 키 의심 파일 감지 시 커밋 중단
