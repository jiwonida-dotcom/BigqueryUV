# HANDOFF — 첫방문UV 월간 리포트 플랫폼 (BigqueryUV)

> 다른 계정/데스크탑 클라우드 세션에서 작업을 이어받기 위한 인수인계 문서.
> **작업 디렉토리: `D:\ClaudeProject\202610_BigqueryUV`**
> 작성: 2026-10-07 (Asia/Seoul) · 이전 세션에서 GA4 화면을 직접 분석해 확정한 내용임.

---

## 1. 프로젝트 목표

GA4 탐색 리포트 **「첫방문UV (\*빅쿼리 생성용)」** 과 동일한 리포트를 BigQuery에서
**월 단위로 자동 추출**하고, **Cloudflare Pages** 대시보드로 제공한다.

- GA4 속성: **U+유모바일_GA4** (`a52894037` / property `p253244174`)
- 원본 탐색 리포트: `https://analytics.google.com/analytics/web/#/analysis/a52894037p253244174/edit/R85Ckl2LTqOfyb3MzobJnQ`
- 배포: GitHub 리포 `https://github.com/jiwonida-dotcom/BigqueryUV` → Cloudflare Pages 자동 배포

## 2. 확정된 아키텍처 (사용자 승인 완료)

```
매월 2일 10:17 KST
GitHub Actions ──▶ BigQuery (uplusumobile.analytics_253244174)
      │                 sql/monthly_uv.sql (파라미터: @start_suffix/@end_suffix)
      ▼
site/data/YYYY-MM.json + index.json 커밋/푸시
      │
      ▼
Cloudflare Pages (출력 디렉토리 site, 빌드 명령 없음) ──▶ 월 선택 대시보드
      └ Cloudflare Access 로 이메일 인증 접근 제한 (사용자 요구사항)
```

사용자 결정 사항: ① GitHub Actions 추출 방식(서비스 계정 키는 GitHub Secrets에만 보관),
② 월 선택 대시보드(KPI+차트+테이블+CSV), ③ GCP 서비스 계정 발급 가능, ④ 접근 제한 필요.

## 3. GA4에서 실측·확정한 리포트 정의 (재조사 불필요)

### 3-1. 탐색 리포트 구성
- 기법: 자유 형식 / 피봇: 첫 번째 열 / 행 표시 500 / 중첩된 행 No
- 행: **날짜 × 세션 기본 채널 그룹(맞춤채널(운영)) × 세션 소스/매체**
- 값: **총 사용자**
- 필터: 맞춤채널(운영) 이 정규식 `^(바이럴)$` 과 **일치하지 않음**
- 세그먼트: **첫방문(세션)** (아래)
- (탐색에는 다른 탭 「맞춤채널별(~2602)」, 「기기」도 있으나 이번 범위는 메인 탭만)

### 3-2. 세그먼트 「첫방문(세션)」 (세그먼트 편집기에서 추출한 원문)
- **포함**: 신규 사용자/재사용자 가 정규식 `new` 와 일치 → BigQuery 구현: `ga_session_number = 1`
- **제외**(일시적으로 제외): 방문 페이지 + 쿼리 문자열이 아래 정규식과 일치
  ```
  ^(/my/.*|/mypg/.*|/bill/.*|/api/login/after|/api/login/easy|/api/login/finger-print|/api/login/face-id|/api/login/id-pw|/util/pw/.*|/login/rest/.*|/my/main|/login|/login/app|/login/id-pw|/util/id/find)$
  ```

### 3-3. 맞춤 채널 그룹 「맞춤채널(운영)」 (관리 화면에서 채널별로 추출, 순서 중요)
| # | 채널 | 규칙 (그룹 내 OR) |
|---|---|---|
| 1 | 직접유입(Direct) | 소스 `^\(direct\)$` **AND** 매체 `^\(none\)$` |
| 2 | 브랜드검색광고 | 소스 `^(brandsearch\|BSA)$` |
| 3 | 검색광고 | 소스 `^(SA\|sa)$` OR 매체 `^cpc$` |
| 4 | 자연유입 | 매체 `^organic$` OR 소스 `^(search\.zum\.com\|m\.search\.daum\|m\.search\.naver)$` |
| 5 | 메세지광고 | 매체 `^(kakao_message\|0916_MGM\|LMS)$` OR 소스 `^LMS$` |
| 6 | 배너광고 | 소스 `^(da\|DA\|criteo\|cashslide)$` OR 매체 `^(sales\|gfa\|fbig\|ig\|fb\|sns\|gdn\|edn\|manplus\|blind\|navercafe\|ppomppu)$` |
| 7 | 추천유입 | 매체 `^(referral\|powercon\|channel\|video\|tistoryblog\|blog\|powerblog\|seo\|상위노출)$` OR 소스 `^(viral\|kakaoplus\|wiggle\|MOYO\|moyo\|checkplus\|pay\.naver\|xpay\|inicis\|recommend\|mvnopartners\|gswelfaremall\|gs25\|qrcode\|me-qr\|localhost\|medialog)$` |
| 8 | 바이럴 | 매체 `^viral$` (리포트 필터로 **제외됨**) |
| — | Unassigned | 위에 해당 없음 |

**중요 발견**: 탐색 실데이터에서 `AMBASSADOR / BLOG` 이 추천유입으로 분류됨
→ GA4 채널 그룹 매칭은 **대소문자 구분 없음**. SQL의 채널 정규식에 `(?i)` 적용 완료.

### 3-4. 세션 소스/매체 매핑
BigQuery `session_traffic_source_last_click.manual_campaign.source / medium` 사용,
NULL 이면 `(direct) / (none)` 으로 처리. 세션 키는 `user_pseudo_id × ga_session_id`,
세션 날짜는 `MIN(event_date)`.

## 4. BigQuery 연동 정보 (GA4 관리 화면에서 확인)

| 항목 | 값 |
|---|---|
| GCP 프로젝트 | `uplusumobile` (번호 148754389366) |
| 데이터셋 | `analytics_253244174` (서울 asia-northeast3) |
| 내보내기 | **매일**(daily)만, 스트리밍 없음 → `events_YYYYMMDD` |
| 생성일 | 2026-07-21 (jiwonida@gmail.com) → **백필은 2026-08월부터 가능** |
| 규모 | 일 약 0.75M 이벤트, 이벤트 89개 제외됨 |

## 5. 리포 구성 (이 폴더의 파일, 모두 작성·검증 완료)

| 파일 | 역할 |
|---|---|
| `sql/monthly_uv.sql` | 리포트 재현 쿼리. GROUPING SETS 로 detail/date_channel/date/channel/total 5레벨 동시 집계 |
| `scripts/extract_monthly.py` | 월 추출 → `site/data/<YYYY-MM>.json`, `index.json` 갱신. 말일 테이블 존재 검사(없으면 실패, `--allow-partial` 로 강제) |
| `.github/workflows/monthly-report.yml` | 매월 2일 01:17 UTC 스케줄 + workflow_dispatch(month, allow_partial). `GCP_SA_KEY` 시크릿 사용, 결과 커밋/푸시 |
| `site/index.html` | 단일 파일 대시보드: 월 선택, KPI 4종, 채널 누적 막대 차트(호버 툴팁·범례 토글), 채널 요약, 상세 테이블(필터·정렬·페이징), CSV 다운로드, 라이트/다크 |
| `site/data/index.json` | 추출된 월 목록 (현재 빈 상태) |
| `README.md` | 설정 가이드 (서비스 계정, Secrets, Pages, Access) |

## 6. 완료된 검증 (재검증 불필요)

- SQL: sqlglot(BigQuery dialect) 파싱 통과. **단, 실제 BigQuery 실행은 아직 안 됨** (이전 세션에 GCP 자격증명 없음)
- 채널 분류: 탐색 화면 실측 36개 (소스/매체→채널) 쌍 전부 일치 (Python 단위 테스트)
- 날짜 로직(month_range/previous_month, 윤년 포함) 단위 테스트 통과
- workflow YAML 파싱 통과
- 대시보드: Playwright 로 라이트/다크/모바일 렌더링 확인, 콘솔 에러 없음
- 차트 팔레트: dataviz 검증 스크립트 라이트/다크 모두 통과 (채널→슬롯 고정 매핑: 직접유입=blue, 검색광고=orange, 브랜드검색=aqua, 자연유입=yellow, 배너=magenta, 추천=green, 메세지=violet, Unassigned=red)

## 7. 남은 작업 (이어받는 세션이 할 일)

1. [ ] 이 폴더 내용을 `jiwonida-dotcom/BigqueryUV` 리포에 커밋/푸시 (main)
2. [ ] GCP 서비스 계정 생성: `roles/bigquery.jobUser`(프로젝트) + `roles/bigquery.dataViewer`(`analytics_253244174` 데이터셋이면 충분) → JSON 키
3. [ ] GitHub Secrets에 `GCP_SA_KEY` 등록 (키 파일 내용 전체)
4. [ ] Actions 수동 실행으로 **첫 실제 쿼리 검증**: month=`2026-08` → 결과 수치를 GA4 탐색과 대조 (±수% 차이는 정상, 아래 8번)
5. [ ] 백필: `2026-09` 실행
6. [ ] Cloudflare Pages 연결: Production branch `main`, 빌드 명령 없음, 출력 디렉토리 `site`
7. [ ] Cloudflare Access(Zero Trust) 로 이메일 기반 접근 제한
8. [ ] (선택) 탐색의 「기기」 탭 등 추가 리포트 확장, 웹페이지 고도화

## 8. 주의사항

- **수치 차이는 정상**: 현재 GA4 탐색 수치는 모두 17의 배수(샘플링 흔적). BigQuery는 원시 집계라 더 정확하며 UI와 다소 다를 수 있음. 사용자에게 이미 안내됨.
- GA4에서 채널 그룹/세그먼트 정의를 바꾸면 `sql/monthly_uv.sql` 도 함께 수정해야 함.
- GA4 일일 내보내기는 최대 72시간 지연 가능 → 스케줄을 2일로 잡았고, 말일 테이블 없으면 스크립트가 의도적으로 실패함 (Actions에서 Re-run).
- 서비스 계정 키는 절대 리포에 커밋 금지 (`.gitignore` 에 패턴 있음).
- 월 경계 세션(자정 걸침)은 시작일 기준 귀속 — GA4와 미세 차이 가능.
