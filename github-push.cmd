@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion
title BigqueryUV GitHub 배포
cd /d "%~dp0"

rem ==========================================================================
rem  github-push.cmd - BigqueryUV GitHub 배포 스크립트
rem
rem  사용법
rem    github-push.cmd                    patch 버전 증가  (v1.0.0 - v1.0.1)
rem    github-push.cmd minor              minor 버전 증가  (v1.0.1 - v1.1.0)
rem    github-push.cmd major              major 버전 증가  (v1.1.0 - v2.0.0)
rem    github-push.cmd "메시지"            배포 메시지 제목 직접 지정
rem    github-push.cmd minor "메시지" -y   확인 없이 바로 배포
rem
rem  최초 실행: git 초기화 + 원격 연결 + v1.0.0 태그로 최초 배포
rem  이후 실행: 변경 파일 분석 - 버전 태그 자동 증가 - 배포 메시지 자동 생성
rem ==========================================================================

set "REMOTE_URL=https://github.com/jiwonida-dotcom/BigqueryUV.git"
set "REPO_WEB=https://github.com/jiwonida-dotcom/BigqueryUV"
set "BRANCH=main"
set "FIRST_VERSION=v1.0.0"
set "MSG_FILE=%TEMP%\bigqueryuv_commit_msg.txt"

rem ---------- 인자 처리 ----------
set "BUMP=patch"
set "NOTE="
set "AUTO="
:args
if "%~1"=="" goto :args_done
set "ARG=%~1"
if "!ARG!"=="/?" goto :help
if /i "!ARG!"=="major" set "BUMP=major" & goto :args_next
if /i "!ARG!"=="minor" set "BUMP=minor" & goto :args_next
if /i "!ARG!"=="patch" set "BUMP=patch" & goto :args_next
if /i "!ARG!"=="-y" set "AUTO=1" & goto :args_next
set "NOTE=!ARG!"
:args_next
shift
goto :args
:args_done

echo ============================================
echo  BigqueryUV GitHub 배포
echo ============================================

rem ---------- 1. git 설치 확인 ----------
where git >nul 2>&1
if errorlevel 1 (
  echo [오류] git 미설치. https://git-scm.com/download/win 에서 설치 후 재실행하세요.
  goto :fail
)

rem ---------- 2. 저장소 초기화 / 원격 연결 ----------
if not exist ".git" (
  echo [초기화] git 저장소 생성
  git init -q
  if errorlevel 1 goto :fail
)
git config core.quotepath false

set "HAS_HEAD=1"
git rev-parse -q --verify HEAD >nul 2>&1
if errorlevel 1 set "HAS_HEAD=0"
if "%HAS_HEAD%"=="0" git symbolic-ref HEAD refs/heads/%BRANCH%

git remote get-url origin >nul 2>&1
if errorlevel 1 (
  git remote add origin "%REMOTE_URL%"
  echo [초기화] 원격 저장소 연결
)
for /f "delims=" %%u in ('git remote get-url origin') do set "CUR_REMOTE=%%u"
echo 원격 저장소: %CUR_REMOTE%

rem ---------- 3. 커밋 작성자 확인 ----------
set "GUN="
for /f "delims=" %%a in ('git config user.name 2^>nul') do set "GUN=%%a"
if not defined GUN (
  set /p "GUN=커밋 작성자 이름 입력: "
  git config user.name "!GUN!"
)
set "GUE="
for /f "delims=" %%a in ('git config user.email 2^>nul') do set "GUE=%%a"
if not defined GUE (
  set /p "GUE=커밋 작성자 이메일 입력: "
  git config user.email "!GUE!"
)

rem ---------- 4. 원격 상태 확인 ----------
echo 원격 저장소 확인 중...
git fetch -q --tags origin
if errorlevel 1 (
  echo [오류] 원격 저장소 접근 실패. 네트워크 또는 GitHub 로그인 계정 권한을 확인하세요.
  goto :fail
)
set "REMOTE_HAS=0"
git rev-parse -q --verify "refs/remotes/origin/%BRANCH%" >nul 2>&1
if not errorlevel 1 set "REMOTE_HAS=1"

rem 로컬 커밋이 없고 원격에 기록이 있으면 원격 기록 위에 로컬 파일을 얹음
if "%HAS_HEAD%"=="0" if "%REMOTE_HAS%"=="1" (
  echo [초기화] 원격 main 기록 기준으로 로컬 파일 반영
  git reset -q "origin/%BRANCH%"
)

set "LAST_TAG="
for /f "delims=" %%t in ('git tag -l "v*" --sort=-v:refname 2^>nul') do if not defined LAST_TAG set "LAST_TAG=%%t"

rem ---------- 5. 변경 파일 스테이징 / 키 유출 점검 ----------
git add -A
if errorlevel 1 goto :fail

git diff --cached --name-only | findstr /i /r /c:"sa-key" /c:"service-account" /c:"\.key" /c:"credentials.*\.json" >nul
if not errorlevel 1 (
  echo [중단] 서비스 계정 키로 의심되는 파일 감지. 커밋하지 않습니다.
  git diff --cached --name-only | findstr /i /r /c:"sa-key" /c:"service-account" /c:"\.key" /c:"credentials.*\.json"
  git reset -q >nul 2>&1
  goto :fail
)
git grep --cached -l -I -e "BEGIN PRIVATE KEY" -- . ":(exclude)github-push.cmd" >nul 2>&1
if not errorlevel 1 (
  echo [중단] 개인 키가 포함된 파일 감지. 커밋하지 않습니다.
  git grep --cached -l -I -e "BEGIN PRIVATE KEY" -- . ":(exclude)github-push.cmd"
  git reset -q >nul 2>&1
  goto :fail
)

git diff --cached --quiet
if not errorlevel 1 goto :no_changes

rem ---------- 6. 배포 버전 계산 ----------
set "IS_FIRST=0"
if not defined LAST_TAG (
  set "IS_FIRST=1"
  set "VERSION=%FIRST_VERSION%"
  set "PREV=없음"
) else (
  set "PREV=!LAST_TAG!"
  for /f "tokens=1-3 delims=v." %%a in ("!LAST_TAG!") do set /a MA=%%a, MI=%%b, PA=%%c
  if /i "%BUMP%"=="major" (set /a MA+=1, MI=0, PA=0) else if /i "%BUMP%"=="minor" (set /a MI+=1, PA=0) else (set /a PA+=1)
  set "VERSION=v!MA!.!MI!.!PA!"
)
git rev-parse -q --verify "refs/tags/%VERSION%" >nul 2>&1
if not errorlevel 1 (
  echo [오류] 태그 %VERSION% 이미 존재. 버전 인자를 확인하세요.
  git reset -q >nul 2>&1
  goto :fail
)

rem ---------- 7. 변경 내역 분석 ----------
set /a CA=0, CM=0, CD=0, CR=0, CNT=0
for %%v in (AR_SITE AR_DATA AR_SQL AR_SCR AR_WF AR_DOC AR_ETC) do set "%%v="
for /f "tokens=1,2" %%s in ('git diff --cached --name-status') do (
  set "ST=%%s"
  set "P=%%t"
  set /a CNT+=1
  if "!ST:~0,1!"=="A" set /a CA+=1
  if "!ST:~0,1!"=="M" set /a CM+=1
  if "!ST:~0,1!"=="D" set /a CD+=1
  if "!ST:~0,1!"=="R" set /a CR+=1
  if "!P:~0,10!"=="site/data/" (set "AR_DATA=1") else if "!P:~0,5!"=="site/" (set "AR_SITE=1") else if "!P:~0,4!"=="sql/" (set "AR_SQL=1") else if "!P:~0,8!"=="scripts/" (set "AR_SCR=1") else if "!P:~0,8!"==".github/" (set "AR_WF=1") else if /i "!P:~-3!"==".md" (set "AR_DOC=1") else (set "AR_ETC=1")
)

set "AREAS="
if defined AR_SITE set "AREAS=!AREAS!대시보드, "
if defined AR_DATA set "AREAS=!AREAS!리포트 데이터, "
if defined AR_SQL set "AREAS=!AREAS!BigQuery 쿼리, "
if defined AR_SCR set "AREAS=!AREAS!추출 스크립트, "
if defined AR_WF set "AREAS=!AREAS!자동화 워크플로, "
if defined AR_DOC set "AREAS=!AREAS!문서, "
if defined AR_ETC set "AREAS=!AREAS!설정, "
if defined AREAS set "AREAS=!AREAS:~0,-2!"

set "VERB=수정"
if %CM%==0 if %CD%==0 if %CR%==0 set "VERB=추가"
if %CA%==0 if %CM%==0 if %CR%==0 set "VERB=삭제"

for /f "delims=" %%d in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HH:mm"') do set "NOW=%%d"
set "NOW=!NOW:_= !"

rem ---------- 8. 배포 메시지 자동 생성 ----------
if defined NOTE (
  set "SUBJECT=[%VERSION%] !NOTE!"
) else if "%IS_FIRST%"=="1" (
  set "SUBJECT=[%VERSION%] 최초 배포: 첫방문UV 월간 리포트 플랫폼 초기 구성"
) else (
  set "SUBJECT=[%VERSION%] !AREAS! !VERB!"
)

> "%MSG_FILE%" echo !SUBJECT!
>>"%MSG_FILE%" echo(
>>"%MSG_FILE%" echo 배포 버전: %VERSION%
>>"%MSG_FILE%" echo 이전 버전: %PREV%
>>"%MSG_FILE%" echo 배포 일시: %NOW% KST
>>"%MSG_FILE%" echo 변경 영역: %AREAS%
>>"%MSG_FILE%" echo 변경 파일: 총 %CNT%개 / 추가 %CA% · 수정 %CM% · 삭제 %CD% · 이름 변경 %CR%
>>"%MSG_FILE%" echo(
>>"%MSG_FILE%" echo [변경 파일 목록] A=추가 M=수정 D=삭제 R=이름 변경
git diff --cached --name-status >> "%MSG_FILE%"

echo.
echo -------------- 배포 메시지 --------------
type "%MSG_FILE%"
echo -----------------------------------------
echo.

if not defined AUTO (
  choice /c YN /n /m "이 내용으로 커밋 후 GitHub 배포 진행 [Y/N] "
  if errorlevel 2 (
    git reset -q >nul 2>&1
    echo 배포 취소. 변경 파일은 그대로 유지됩니다.
    goto :done
  )
)

rem ---------- 9. 커밋 / 원격 반영 / 태그 ----------
git commit -q -F "%MSG_FILE%"
if errorlevel 1 goto :fail
git branch -M %BRANCH%

if "%REMOTE_HAS%"=="1" (
  echo 원격 변경 반영 중 - GitHub Actions 데이터 커밋 포함
  git pull -q --rebase origin %BRANCH%
  if errorlevel 1 (
    git rebase --abort >nul 2>&1
    echo [오류] 원격 변경과 충돌. 커밋은 로컬에 유지됩니다. 충돌 해결 후 재실행하세요.
    goto :fail
  )
)

git tag -a "%VERSION%" -F "%MSG_FILE%"
if errorlevel 1 goto :fail
goto :push

rem ---------- 변경 없음: 미푸시 커밋만 확인 ----------
:no_changes
set "AHEAD=0"
if "%REMOTE_HAS%"=="1" (
  for /f %%n in ('git rev-list --count origin/%BRANCH%..HEAD 2^>nul') do set "AHEAD=%%n"
) else (
  for /f %%n in ('git rev-list --count HEAD 2^>nul') do set "AHEAD=%%n"
)
if "%AHEAD%"=="0" (
  echo 변경 파일 없음. 배포 생략.
  goto :done
)
echo 미푸시 커밋 %AHEAD%개 감지. 푸시만 진행합니다.
set "VERSION=%LAST_TAG%"

rem ---------- 10. 푸시 ----------
:push
echo.
echo GitHub 푸시 중...
git push -u --follow-tags origin %BRANCH%
if errorlevel 1 (
  echo [오류] 푸시 실패. 커밋과 태그는 로컬에 유지되며, 원인 해결 후 재실행하면 이어서 푸시됩니다.
  goto :fail
)

echo.
echo ============================================
echo  배포 완료: %VERSION%
echo  저장소   : %REPO_WEB%
echo  커밋 기록: %REPO_WEB%/commits/%BRANCH%
echo  Cloudflare Workers 연결 시 1~2분 내 자동 배포
echo ============================================
goto :done

:help
echo 사용법: github-push.cmd [patch^|minor^|major] ["배포 메시지"] [-y]
echo   patch  기본값. v1.0.0 - v1.0.1
echo   minor  v1.0.1 - v1.1.0
echo   major  v1.1.0 - v2.0.0
echo   -y     확인 없이 바로 배포
goto :done

:fail
if exist "%MSG_FILE%" del "%MSG_FILE%" >nul 2>&1
echo.
echo 배포 중단.
if not defined AUTO pause
endlocal
exit /b 1

:done
if exist "%MSG_FILE%" del "%MSG_FILE%" >nul 2>&1
if not defined AUTO pause
endlocal
exit /b 0
