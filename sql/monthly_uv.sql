-- =============================================================================
-- 첫방문UV 월간 리포트 (GA4 탐색 "첫방문UV (*빅쿼리 생성용)" 재현) — v2
--
-- v2 변경 (2026-10-07 검증 결과 반영):
--   * 세션 소스/매체와 채널을 session_traffic_source_last_click.cross_channel_campaign
--     에서 직접 사용. 이 필드는 GA4 UI의 "세션 소스/매체"와 동일하게
--     Google Ads 자동 태깅(gclid) 통합이 반영되고(예: UTM이 DA/GOOGLE이어도
--     UI처럼 google/cpc), primary_channel_group 에는 속성의 기본 채널 그룹인
--     "맞춤채널(운영)"의 채널명이 한글 그대로 들어 있음 (BigQuery 실측 확인).
--   * 기존 manual_campaign(수동 UTM) 기반 분류는 direct가 "(not set)"으로 빠지고
--     google/cpc가 organic/DA로 흩어지는 불일치가 있어 폐기.
--   * cross_channel 값이 NULL인 세션만 (direct)/(none) + 규칙 CASE로 폴백.
--
-- GA4 탐색 리포트 구성:
--   세그먼트  : 첫방문(세션)
--               - 포함: 신규 사용자/재사용자 = "new"  (ga_session_number = 1)
--               - 제외: 방문 페이지+쿼리 문자열이 아래 정규식과 일치하는 세션
--   행        : 날짜 / 세션 기본 채널 그룹(맞춤채널(운영)) / 세션 소스·매체
--   값        : 총 사용자 (COUNT DISTINCT user_pseudo_id)
--   필터      : 맞춤채널(운영) != '바이럴'
--
-- 파라미터: @start_suffix, @end_suffix  (예: '20260801', '20260831')
-- =============================================================================

WITH ev AS (
  SELECT
    user_pseudo_id,
    event_date,
    event_timestamp,
    event_name,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id')     AS ga_session_id,
    (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_number') AS ga_session_number,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location')     AS page_location,
    session_traffic_source_last_click.cross_channel_campaign.source                AS cc_source,
    session_traffic_source_last_click.cross_channel_campaign.medium                AS cc_medium,
    session_traffic_source_last_click.cross_channel_campaign.primary_channel_group AS cc_channel
  FROM `uplusumobile.analytics_253244174.events_*`
  WHERE _TABLE_SUFFIX BETWEEN @start_suffix AND @end_suffix
    AND user_pseudo_id IS NOT NULL
),

sessions AS (
  SELECT
    user_pseudo_id,
    ga_session_id,
    MIN(event_date)        AS session_date,
    MAX(ga_session_number) AS session_number,
    -- 세션 소스/매체/채널 (GA4 UI와 동일한 cross_channel 값, 세션 내 마지막 기록)
    ARRAY_AGG(
      IF(cc_source IS NOT NULL OR cc_medium IS NOT NULL OR cc_channel IS NOT NULL,
         STRUCT(cc_source AS s, cc_medium AS m, cc_channel AS ch), NULL)
      IGNORE NULLS ORDER BY event_timestamp DESC LIMIT 1
    )[SAFE_OFFSET(0)]      AS traffic,
    -- 방문 페이지 + 쿼리 문자열 (첫 page_view 의 path+query, 호스트/프래그먼트 제외)
    ARRAY_AGG(
      IF(event_name = 'page_view' AND page_location IS NOT NULL,
         STRUCT(event_timestamp AS t, page_location AS u), NULL)
      IGNORE NULLS ORDER BY event_timestamp ASC LIMIT 1
    )[SAFE_OFFSET(0)].u    AS landing_url
  FROM ev
  WHERE ga_session_id IS NOT NULL
  GROUP BY user_pseudo_id, ga_session_id
),

classified AS (
  SELECT
    user_pseudo_id,
    session_date,
    CONCAT(src, ' / ', med) AS source_medium,
    -- 1순위: GA4가 계산해 준 맞춤채널(운영) 값. NULL일 때만 규칙 CASE 폴백.
    -- 폴백 명칭은 GA 맞춤채널(운영) 명칭과 일치 필수 (배너광고·메세지광고·바이럴 명칭 미확인)
    COALESCE(
      ch,
      CASE
        WHEN src = '(direct)' AND med = '(none)'
          THEN '직접유입(Direct)'
        WHEN REGEXP_CONTAINS(src, r'(?i)^(brandsearch|BSA)$')
          THEN '브랜드검색광고(bsa)'
        WHEN REGEXP_CONTAINS(src, r'(?i)^(SA|sa)$')
          OR REGEXP_CONTAINS(med, r'(?i)^cpc$')
          THEN '검색광고'
        WHEN REGEXP_CONTAINS(med, r'(?i)^organic$')
          OR REGEXP_CONTAINS(src, r'(?i)^(search\.zum\.com|m\.search\.daum|m\.search\.naver)$')
          THEN '자연유입(Organic Search)'
        WHEN REGEXP_CONTAINS(med, r'(?i)^(kakao_message|0916_MGM|LMS)$')
          OR REGEXP_CONTAINS(src, r'(?i)^LMS$')
          THEN '메세지광고'
        WHEN REGEXP_CONTAINS(src, r'(?i)^(da|DA|criteo|cashslide)$')
          OR REGEXP_CONTAINS(med, r'(?i)^(sales|gfa|fbig|ig|fb|sns|gdn|edn|manplus|blind|navercafe|ppomppu)$')
          THEN '배너광고'
        WHEN REGEXP_CONTAINS(med, r'(?i)^(referral|powercon|channel|video|tistoryblog|blog|powerblog|seo|상위노출)$')
          OR REGEXP_CONTAINS(src, r'(?i)^(viral|kakaoplus|wiggle|MOYO|moyo|checkplus|pay\.naver|xpay|inicis|recommend|mvnopartners|gswelfaremall|gs25|qrcode|me-qr|localhost|medialog)$')
          THEN '추천유입(Referral)'
        WHEN REGEXP_CONTAINS(med, r'(?i)^viral$')
          THEN '바이럴'
        ELSE 'Unassigned'
      END
    ) AS channel
  FROM (
    SELECT
      user_pseudo_id,
      session_date,
      COALESCE(traffic.s, '(direct)') AS src,
      COALESCE(traffic.m, '(none)')   AS med,
      traffic.ch                      AS ch,
      landing_url
    FROM sessions
    -- 세그먼트 포함 조건: 신규 사용자 세션
    WHERE session_number = 1
  )
  -- 세그먼트 제외 조건: 방문 페이지+쿼리 문자열 정규식 (전체 일치)
  WHERE NOT REGEXP_CONTAINS(
    COALESCE(REGEXP_EXTRACT(landing_url, r'^https?://[^/#?]+([^#]*)'), ''),
    r'^(/my/.*|/mypg/.*|/bill/.*|/api/login/after|/api/login/easy|/api/login/finger-print|/api/login/face-id|/api/login/id-pw|/util/pw/.*|/login/rest/.*|/my/main|/login|/login/app|/login/id-pw|/util/id/find)$'
  )
)

SELECT
  CASE
    WHEN GROUPING(session_date) = 0 AND GROUPING(channel) = 0 AND GROUPING(source_medium) = 0 THEN 'detail'
    WHEN GROUPING(session_date) = 0 AND GROUPING(channel) = 0 THEN 'date_channel'
    WHEN GROUPING(session_date) = 0 THEN 'date'
    WHEN GROUPING(channel) = 0 THEN 'channel'
    ELSE 'total'
  END                              AS level,
  session_date,
  channel,
  source_medium,
  COUNT(DISTINCT user_pseudo_id)   AS users
FROM classified
-- 리포트 필터: 바이럴 채널 제외
WHERE channel != '바이럴'
GROUP BY GROUPING SETS (
  (session_date, channel, source_medium),
  (session_date, channel),
  (session_date),
  (channel),
  ()
)
ORDER BY level, session_date, channel, source_medium
