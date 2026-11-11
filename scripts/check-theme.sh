#!/usr/bin/env bash
# 원본 콘셉트의 잔재 용어가 남아 있는지 검사한다. 결과가 0건이어야 통과(exit 0).
# 사용: bash scripts/check-theme.sh            # 저장소 전체
#       bash scripts/check-theme.sh src        # 특정 경로만
#
# 금지어 목록 자체가 원본 콘셉트를 드러내므로 저장소에 두지 않는다.
#   - 로컬: _private/theme-pattern.txt (gitignore, 확장 정규식 한 줄)
#   - CI:   저장소 시크릿 THEME_PATTERN
# 둘 다 없으면 검사를 건너뛰지 않고 실패한다.
set -u
cd "$(dirname "$0")/.."
PATTERN="${THEME_PATTERN:-}"
if [ -z "$PATTERN" ] && [ -f _private/theme-pattern.txt ]; then
  PATTERN="$(tr -d '\r\n' < _private/theme-pattern.txt)"
fi
if [ -z "$PATTERN" ]; then
  echo "check-theme: 금지어 목록이 없습니다. THEME_PATTERN 또는 _private/theme-pattern.txt 를 준비하세요." >&2
  exit 2
fi
if [ "$#" -eq 0 ]; then set -- .; fi
if git grep -nE "$PATTERN" -- "$@"; then
  echo "check-theme: 금지어가 남아 있습니다." >&2
  exit 1
fi
echo "check-theme: OK"
exit 0
