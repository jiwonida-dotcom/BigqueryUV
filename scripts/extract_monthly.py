#!/usr/bin/env python3
"""GA4 BigQuery 첫방문UV 월간 추출 스크립트.

지정한 월(기본: 지난달)의 데이터를 BigQuery에서 추출해
site/data/<YYYY-MM>.json 과 site/data/index.json 을 생성/갱신한다.

사용법:
    python scripts/extract_monthly.py              # 지난달
    python scripts/extract_monthly.py 2026-08      # 특정 월
    python scripts/extract_monthly.py 2026-08 --allow-partial  # 진행 중인 달 허용

인증: GOOGLE_APPLICATION_CREDENTIALS 또는 google-github-actions/auth 가 설정한
      ADC(Application Default Credentials)를 사용한다.
"""

import argparse
import calendar
import datetime as dt
import json
import pathlib
import sys
import zoneinfo

from google.cloud import bigquery

PROJECT = "uplusumobile"
DATASET = "analytics_253244174"
KST = zoneinfo.ZoneInfo("Asia/Seoul")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SQL_PATH = ROOT / "sql" / "monthly_uv.sql"
DATA_DIR = ROOT / "site" / "data"

# 채널 정렬 기준: GA 맞춤채널(운영) 명칭 접두어 (접미어 변경에도 정렬 유지)
CHANNEL_BASES = ["직접유입", "검색광고", "브랜드검색광고", "자연유입",
                 "배너광고", "추천유입", "메세지광고", "Unassigned"]


def channel_rank(ch: str) -> int:
    for i, base in enumerate(CHANNEL_BASES):
        if ch.startswith(base):
            return i
    return 99


def month_range(month: str) -> tuple[str, str]:
    year, mon = map(int, month.split("-"))
    last = calendar.monthrange(year, mon)[1]
    return f"{year:04d}{mon:02d}01", f"{year:04d}{mon:02d}{last:02d}"


def previous_month(today: dt.date) -> str:
    first = today.replace(day=1)
    prev_last = first - dt.timedelta(days=1)
    return f"{prev_last.year:04d}-{prev_last.month:02d}"


def check_tables(client: bigquery.Client, start: str, end: str, allow_partial: bool) -> list[str]:
    """해당 월의 events_* 테이블 존재 여부 확인 (GA4 일일 내보내기 지연 감지)."""
    q = f"""
        SELECT table_name FROM `{PROJECT}.{DATASET}.INFORMATION_SCHEMA.TABLES`
        WHERE table_name BETWEEN 'events_{start}' AND 'events_{end}'
        ORDER BY table_name
    """
    tables = [r.table_name for r in client.query(q).result()]
    expected_last = f"events_{end}"
    if not tables:
        sys.exit(f"[오류] {start}~{end} 범위의 events_ 테이블이 없습니다. "
                 f"GA4 BigQuery 내보내기 상태를 확인하세요.")
    if tables[-1] != expected_last and not allow_partial:
        sys.exit(f"[오류] 마지막 일자 테이블({expected_last})이 아직 생성되지 않았습니다 "
                 f"(현재 마지막: {tables[-1]}). GA4 일일 내보내기는 최대 72시간 지연될 수 있습니다. "
                 f"나중에 다시 실행하거나 --allow-partial 로 강제 실행하세요.")
    return tables


def run(month: str, allow_partial: bool) -> None:
    start, end = month_range(month)
    sql = SQL_PATH.read_text(encoding="utf-8")

    client = bigquery.Client(project=PROJECT)
    tables = check_tables(client, start, end, allow_partial)
    print(f"[정보] {month}: events_ 테이블 {len(tables)}개 확인 "
          f"({tables[0]} ~ {tables[-1]})")

    job = client.query(
        sql,
        job_config=bigquery.QueryJobConfig(
            query_parameters=[
                bigquery.ScalarQueryParameter("start_suffix", "STRING", start),
                bigquery.ScalarQueryParameter("end_suffix", "STRING", end),
            ]
        ),
    )
    rows = list(job.result())
    gb = (job.total_bytes_processed or 0) / 1e9
    print(f"[정보] 쿼리 완료: {len(rows)}행, {gb:.2f} GB 처리")

    detail, date_channel, by_date, by_channel = [], [], [], []
    total_users = 0
    for r in rows:
        if r.level == "detail":
            detail.append({"date": r.session_date, "channel": r.channel,
                           "source_medium": r.source_medium, "users": r.users})
        elif r.level == "date_channel":
            date_channel.append({"date": r.session_date, "channel": r.channel,
                                 "users": r.users})
        elif r.level == "date":
            by_date.append({"date": r.session_date, "users": r.users})
        elif r.level == "channel":
            by_channel.append({"channel": r.channel, "users": r.users})
        elif r.level == "total":
            total_users = r.users

    by_channel.sort(key=lambda x: (channel_rank(x["channel"]), x["channel"]))

    out = {
        "month": month,
        "generated_at": dt.datetime.now(KST).isoformat(timespec="seconds"),
        "source": f"{PROJECT}.{DATASET}.events_{start}..{end}",
        "days_available": len(tables),
        "partial": tables[-1] != f"events_{end}",
        "total_users": total_users,
        "by_date": by_date,
        "by_channel": by_channel,
        "by_date_channel": date_channel,
        "rows": detail,
    }

    DATA_DIR.mkdir(parents=True, exist_ok=True)
    out_path = DATA_DIR / f"{month}.json"
    out_path.write_text(json.dumps(out, ensure_ascii=False, separators=(",", ":")),
                        encoding="utf-8")
    print(f"[완료] {out_path} ({out_path.stat().st_size / 1024:.0f} KB, "
          f"상세 {len(detail)}행, 월 총 사용자 {total_users:,})")

    index_path = DATA_DIR / "index.json"
    months = []
    if index_path.exists():
        months = json.loads(index_path.read_text(encoding="utf-8")).get("months", [])
    if month not in months:
        months.append(month)
    months.sort(reverse=True)
    index_path.write_text(
        json.dumps({"months": months,
                    "updated_at": dt.datetime.now(KST).isoformat(timespec="seconds")},
                   ensure_ascii=False, indent=2),
        encoding="utf-8")
    print(f"[완료] index.json 갱신: {months}")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("month", nargs="?", default=None, help="YYYY-MM (기본: 지난달)")
    p.add_argument("--allow-partial", action="store_true",
                   help="월이 끝나지 않았거나 마지막 테이블이 없어도 추출")
    a = p.parse_args()
    m = a.month or previous_month(dt.datetime.now(KST).date())
    if len(m) != 7 or m[4] != "-":
        sys.exit(f"[오류] 월 형식이 잘못됨: {m} (YYYY-MM)")
    run(m, a.allow_partial)
