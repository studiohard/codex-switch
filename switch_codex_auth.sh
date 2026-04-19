#!/bin/sh

set -eu

CODEX_DIR="${1:-${CODEX_DIR:-$HOME/.codex}}"
CURRENT_AUTH="$CODEX_DIR/auth.json"
CODEX_APP_NAME="${CODEX_APP_NAME:-Codex}"
CODEX_APP_PATH="${CODEX_APP_PATH:-/Applications/${CODEX_APP_NAME}.app}"
CODEX_BINARY_PATH="${CODEX_BINARY_PATH:-$CODEX_APP_PATH/Contents/MacOS/$CODEX_APP_NAME}"

codex_main_pids() {
  ps ax -o pid=,comm= | awk -v target="$CODEX_BINARY_PATH" '$2 == target { print $1 }'
}

codex_is_running() {
  [ -n "$(codex_main_pids)" ]
}

wait_for_codex_exit() {
  timeout="${1:-20}"
  elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    if ! codex_is_running; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  ! codex_is_running
}

stop_codex_app() {
  if ! codex_is_running; then
    printf '未发现运行中的 Codex 进程。\n'
    return 0
  fi

  printf '正在退出 Codex...\n'
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "tell application \"$CODEX_APP_NAME\" to quit" >/dev/null 2>&1 || true
  fi

  if wait_for_codex_exit 20; then
    printf 'Codex 已退出。\n'
    return 0
  fi

  printf 'Codex 未在 20 秒内退出，尝试结束主进程...\n'
  codex_main_pids | while IFS= read -r pid; do
    if [ -n "$pid" ]; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  done

  if wait_for_codex_exit 10; then
    printf 'Codex 已退出。\n'
    return 0
  fi

  printf '无法退出 Codex，请手动关闭后重试。\n' >&2
  return 1
}

start_codex_app() {
  if [ ! -d "$CODEX_APP_PATH" ]; then
    printf '未找到 Codex 应用: %s\n' "$CODEX_APP_PATH" >&2
    return 1
  fi

  printf '正在启动 Codex...\n'
  if open "$CODEX_APP_PATH" >/dev/null 2>&1; then
    printf 'Codex 已启动。\n'
    return 0
  fi

  printf '启动 Codex 失败，请手动打开: %s\n' "$CODEX_APP_PATH" >&2
  return 1
}

find_saved_auth_copy() {
  auth_file="$1"

  if [ ! -f "$auth_file" ]; then
    return 1
  fi

  find "$CODEX_DIR" -maxdepth 1 -type f -name 'auth*.json' ! -name 'auth.json' | sort | while IFS= read -r file; do
    if [ "$file" != "$auth_file" ] && cmp -s "$file" "$auth_file"; then
      printf '%s\n' "$file"
      exit 0
    fi
  done
}

suggest_backup_path() {
  auth_file="$1"

  if [ ! -f "$auth_file" ] || ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$auth_file" "$CODEX_DIR" <<'PY'
import base64
import json
import pathlib
import re
import sys

auth_file = pathlib.Path(sys.argv[1]).resolve()
codex_dir = pathlib.Path(sys.argv[2]).resolve()


def slug(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9]+", "_", value).strip("_")
    return cleaned or "backup"


try:
    obj = json.loads(auth_file.read_text())
    tokens = obj.get("tokens", {})
    token = tokens.get("id_token") or tokens.get("access_token")
    if not token:
        raise ValueError("missing token")

    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    data = json.loads(base64.urlsafe_b64decode(payload))
    auth = data.get("https://api.openai.com/auth", {})
    profile = data.get("https://api.openai.com/profile", {})
except Exception:
    raise SystemExit(1)

email = data.get("email") or profile.get("email") or ""
account_id = auth.get("chatgpt_account_id") or ""

candidates = []
if email:
    local = email.split("@", 1)[0]
    candidates.append(f"auth_{slug(local)}.json")
    candidates.append(f"auth_{slug(email)}.json")
if account_id:
    candidates.append(f"auth_{slug(account_id)}.json")

seen = set()
for name in candidates:
    if name in seen:
        continue
    seen.add(name)
    candidate = (codex_dir / name).resolve()
    if candidate != auth_file:
        print(candidate)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

ensure_saved_auth_copy() {
  auth_file="$1"

  if [ ! -f "$auth_file" ]; then
    return 1
  fi

  existing_copy="$(find_saved_auth_copy "$auth_file")"
  if [ -n "$existing_copy" ]; then
    printf '%s\n' "$existing_copy"
    return 0
  fi

  backup_path="$(suggest_backup_path "$auth_file" 2>/dev/null || true)"
  if [ -z "$backup_path" ]; then
    backup_path="$CODEX_DIR/auth_backup_$(date '+%Y%m%d_%H%M%S').json"
  fi

  if [ -f "$backup_path" ] && ! cmp -s "$backup_path" "$auth_file"; then
    backup_path="$CODEX_DIR/auth_backup_$(date '+%Y%m%d_%H%M%S').json"
  fi

  cp "$auth_file" "$backup_path"
  printf '%s\n' "$backup_path"
}

cache_auth_snapshot() {
  cache_file="$1"
  auth_file="$2"
  fallback_plan="${3:-}"
  fallback_left="${4:-}"
  fallback_updated_at="${5:-0}"
  fallback_primary_resets_at="${6:-0}"
  fallback_secondary_resets_at="${7:-0}"

  if [ ! -f "$auth_file" ] || ! command -v python3 >/dev/null 2>&1; then
    return
  fi

  python3 - "$cache_file" "$auth_file" "$fallback_plan" "$fallback_left" "$fallback_updated_at" "$fallback_primary_resets_at" "$fallback_secondary_resets_at" <<'PY'
import base64
import json
import pathlib
import re
import sys

cache_file = pathlib.Path(sys.argv[1])
auth_file = pathlib.Path(sys.argv[2])
fallback_plan = sys.argv[3]
fallback_left = sys.argv[4]
fallback_updated_at = sys.argv[5]
fallback_primary_resets_at = sys.argv[6]
fallback_secondary_resets_at = sys.argv[7]

for prefix in ("last ", "历史 "):
    if fallback_left.startswith(prefix):
        fallback_left = fallback_left[len(prefix):]

cache = {}
if cache_file.exists():
    try:
        loaded = json.loads(cache_file.read_text())
        if isinstance(loaded, dict):
            cache = loaded
    except Exception:
        cache = {}

email = "?"
plan = "?"
account_id = ""

try:
    obj = json.loads(auth_file.read_text())
    tokens = obj.get("tokens", {})
    token = tokens.get("id_token") or tokens.get("access_token")
    if token:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        auth = data.get("https://api.openai.com/auth", {})
        profile = data.get("https://api.openai.com/profile", {})
        email = data.get("email") or profile.get("email") or "?"
        plan = auth.get("chatgpt_plan_type") or "?"
        account_id = auth.get("chatgpt_account_id") or ""
except Exception:
    pass

key = account_id or email
if not key or key == "?":
    raise SystemExit(0)

entry = cache.get(key, {})
entry["email"] = email

if fallback_plan and fallback_plan != "?":
    entry["plan"] = fallback_plan
elif plan and plan != "?":
    entry["plan"] = plan

try:
    updated_at = int(fallback_updated_at)
except Exception:
    updated_at = 0

try:
    activated_at = int(entry.get("activated_at") or 0)
except Exception:
    activated_at = 0

is_fresh_after_activation = not (updated_at > 0 and activated_at > 0 and updated_at < activated_at)

looks_like_left = bool(
    fallback_left
    and fallback_left != "unknown"
    and (
        re.match(r"^5小时\s+[0-9.]+%\s+\|\s+7天\s+[0-9.]+%$", fallback_left)
        or re.match(r"^近5小时\s+[0-9.]+%\s+\|\s+近7天\s+[0-9.]+%$", fallback_left)
        or re.match(r"^5h\s+[0-9.]+%\s+\|\s+7d\s+[0-9.]+%$", fallback_left)
    )
)
if looks_like_left and is_fresh_after_activation:
    entry["left"] = fallback_left

if updated_at > 0 and activated_at > 0 and updated_at < activated_at:
    updated_at = 0

if updated_at > 0:
    entry["updated_at"] = updated_at

for field, value in (
    ("primary_resets_at", fallback_primary_resets_at),
    ("secondary_resets_at", fallback_secondary_resets_at),
):
    try:
        reset_value = int(value)
    except Exception:
        reset_value = 0
    if reset_value > 0:
        entry[field] = reset_value

cache[key] = entry

cache_file.write_text(json.dumps(cache, ensure_ascii=False, indent=2, sort_keys=True))
PY
}

mark_auth_activation() {
  cache_file="$1"
  auth_file="$2"
  fallback_plan="${3:-}"
  activated_at="${4:-0}"

  if [ ! -f "$auth_file" ] || ! command -v python3 >/dev/null 2>&1; then
    return
  fi

  python3 - "$cache_file" "$auth_file" "$fallback_plan" "$activated_at" <<'PY'
import base64
import json
import pathlib
import sys

cache_file = pathlib.Path(sys.argv[1])
auth_file = pathlib.Path(sys.argv[2])
fallback_plan = sys.argv[3]
activated_at = sys.argv[4]

cache = {}
if cache_file.exists():
    try:
        loaded = json.loads(cache_file.read_text())
        if isinstance(loaded, dict):
            cache = loaded
    except Exception:
        cache = {}

email = "?"
plan = "?"
account_id = ""

try:
    obj = json.loads(auth_file.read_text())
    tokens = obj.get("tokens", {})
    token = tokens.get("id_token") or tokens.get("access_token")
    if token:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        auth = data.get("https://api.openai.com/auth", {})
        profile = data.get("https://api.openai.com/profile", {})
        email = data.get("email") or profile.get("email") or "?"
        plan = auth.get("chatgpt_plan_type") or "?"
        account_id = auth.get("chatgpt_account_id") or ""
except Exception:
    pass

key = account_id or email
if not key or key == "?":
    raise SystemExit(0)

entry = cache.get(key, {})
entry["email"] = email

if fallback_plan and fallback_plan != "?":
    entry["plan"] = fallback_plan
elif plan and plan != "?":
    entry["plan"] = plan

try:
    activated_value = int(activated_at)
except Exception:
    activated_value = 0

if activated_value > 0:
    entry["activated_at"] = activated_value

cache[key] = entry
cache_file.write_text(json.dumps(cache, ensure_ascii=False, indent=2, sort_keys=True))
PY
}

build_rows() {
  list_file="$1"
  rows_file="$2"
  current_auth_file="$3"
  cache_file="$4"
  sessions_dir="${SESSIONS_DIR:-$HOME/.codex/sessions}"

  if ! command -v python3 >/dev/null 2>&1; then
    awk '
      { printf "%s\t\t?\t?\tunknown\n", NR }
    ' "$list_file" > "$rows_file"
    return
  fi

  python3 - "$list_file" "$rows_file" "$current_auth_file" "$cache_file" "$sessions_dir" <<'PY'
import base64
import datetime as dt
import json
import pathlib
import re
import time
import sys

list_file = pathlib.Path(sys.argv[1])
rows_file = pathlib.Path(sys.argv[2])
current_auth_file = pathlib.Path(sys.argv[3])
cache_file = pathlib.Path(sys.argv[4])
sessions_dir = pathlib.Path(sys.argv[5])


def parse_auth(path: pathlib.Path):
    email = "?"
    plan = "?"
    account_id = ""
    user_id = ""
    try:
        obj = json.loads(path.read_text())
        tokens = obj.get("tokens", {})
        token = tokens.get("id_token") or tokens.get("access_token")
        if token:
            payload = token.split(".")[1]
            payload += "=" * (-len(payload) % 4)
            data = json.loads(base64.urlsafe_b64decode(payload))
            auth = data.get("https://api.openai.com/auth", {})
            profile = data.get("https://api.openai.com/profile", {})
            email = data.get("email") or profile.get("email") or "?"
            plan = auth.get("chatgpt_plan_type") or "?"
            account_id = auth.get("chatgpt_account_id") or ""
            user_id = auth.get("user_id") or ""
    except Exception:
        pass
    return {
        "path": str(path),
        "email": email,
        "plan": plan,
        "account_id": account_id,
        "user_id": user_id,
        "current": current_auth_file.exists() and path.resolve() == current_auth_file.resolve(),
    }


def fmt_remaining(value):
    if value is None:
        return "?"
    try:
        remaining = max(0.0, 100.0 - float(value))
    except Exception:
        return "?"
    if remaining.is_integer():
        return str(int(remaining))
    return f"{remaining:.1f}"


def left_from_rate_limits(rate_limits):
    primary = rate_limits.get("primary") or {}
    secondary = rate_limits.get("secondary") or {}
    return (
        f"5小时 {fmt_remaining(primary.get('used_percent'))}%"
        f" | 7天 {fmt_remaining(secondary.get('used_percent'))}%"
    )


def reset_timestamp(value):
    try:
        parsed = int(value)
    except Exception:
        return 0
    return parsed if parsed > 0 else 0


def render_left(left_text, updated_at, plan, history=False):
    if not left_text or left_text == "unknown":
        return "unknown"

    normalized = left_text.strip()
    normalized = re.sub(r"^last\s+", "", normalized)
    normalized = re.sub(r"^历史\s+", "", normalized)
    normalized = normalized.replace("5h ", "5小时 ").replace("7d ", "7天 ")
    normalized = normalized.replace("近5小时 ", "5小时 ").replace("近7天 ", "7天 ")

    match = re.match(r"^5小时\s+([0-9.]+)%\s+\|\s+7天\s+([0-9.]+)%$", normalized)
    if not match:
        return normalized

    return normalized


def render_reset(value):
    try:
        timestamp = int(value)
    except Exception:
        return "-"
    if timestamp <= 0:
        return "-"
    try:
        reset_at = dt.datetime.fromtimestamp(timestamp).astimezone()
    except Exception:
        return "-"
    return reset_at.strftime("%Y-%m-%d %H:%M")


def pick_plan(*candidates):
    for value in candidates:
        if value and value != "?":
            return value
    return "?"


auth_paths = [pathlib.Path(line.strip()) for line in list_file.read_text().splitlines() if line.strip()]
accounts = [parse_auth(path) for path in auth_paths]
current_auth_mtime = current_auth_file.stat().st_mtime if current_auth_file.exists() else 0
current_index = next((index for index, account in enumerate(accounts) if account["current"]), None)

cache = {}
if cache_file.exists():
    try:
        loaded = json.loads(cache_file.read_text())
        if isinstance(loaded, dict):
            cache = loaded
    except Exception:
        cache = {}

latest_current = None
latest_session_overall = None
history_by_index = {}

if sessions_dir.is_dir():
    for session_path in sorted(sessions_dir.rglob("*.jsonl")):
        try:
            text = session_path.read_text(errors="ignore")
        except Exception:
            continue

        last_rate_limits = None
        for line in text.splitlines():
            try:
                obj = json.loads(line)
            except Exception:
                continue
            payload = obj.get("payload")
            if not isinstance(payload, dict):
                continue
            if obj.get("type") != "event_msg" or payload.get("type") != "token_count":
                continue
            rate_limits = payload.get("rate_limits")
            if isinstance(rate_limits, dict):
                last_rate_limits = rate_limits

        if not last_rate_limits:
            continue

        session_meta = {
            "plan": last_rate_limits.get("plan_type") or "?",
            "left": left_from_rate_limits(last_rate_limits),
            "primary_resets_at": reset_timestamp((last_rate_limits.get("primary") or {}).get("resets_at")),
            "secondary_resets_at": reset_timestamp((last_rate_limits.get("secondary") or {}).get("resets_at")),
            "mtime": session_path.stat().st_mtime,
        }

        if not latest_session_overall or session_meta["mtime"] >= latest_session_overall["mtime"]:
            latest_session_overall = session_meta

        matched_indexes = []
        for index, account in enumerate(accounts):
            identifiers = [account["account_id"], account["user_id"]]
            if any(identifier and identifier in text for identifier in identifiers):
                matched_indexes.append(index)

        matched_indexes = sorted(set(matched_indexes))
        if len(matched_indexes) == 1:
            matched_index = matched_indexes[0]
            previous = history_by_index.get(matched_index)
            if not previous or session_meta["mtime"] >= previous["mtime"]:
                history_by_index[matched_index] = session_meta
            if matched_index == current_index:
                latest_current = session_meta

current_account = next((account for account in accounts if account["current"]), None)
if (
    current_account
    and latest_session_overall
    and latest_session_overall["mtime"] >= current_auth_mtime
):
    latest_current = latest_session_overall

if (
    current_account
    and latest_current
    and latest_current["mtime"] >= current_auth_mtime
):
    cache_key = current_account["account_id"] or current_account["email"]
    if cache_key:
        existing = cache.get(cache_key, {})
        cache[cache_key] = {
            "email": current_account["email"],
            "plan": latest_current.get("plan") or current_account["plan"],
            "left": latest_current["left"],
            "primary_resets_at": latest_current.get("primary_resets_at") or existing.get("primary_resets_at", 0),
            "secondary_resets_at": latest_current.get("secondary_resets_at") or existing.get("secondary_resets_at", 0),
            "updated_at": int(latest_current["mtime"]),
            "activated_at": existing.get("activated_at", int(current_auth_mtime)),
        }

try:
    cache_file.write_text(json.dumps(cache, ensure_ascii=False, indent=2, sort_keys=True))
except Exception:
    pass

with rows_file.open("w") as fh:
    for index, account in enumerate(accounts, start=1):
        marker = "*" if account["current"] else ""
        plan = account["plan"]
        left = "unknown"
        primary_reset = "-"
        secondary_reset = "-"
        primary_reset_ts = 0
        secondary_reset_ts = 0
        checked_ts = 0
        cache_key = account["account_id"] or account["email"]
        cached = cache.get(cache_key) if cache_key else None
        cached_plan = cached.get("plan") if isinstance(cached, dict) else None

        if account["current"]:
            if latest_current and latest_current["mtime"] >= current_auth_mtime:
                plan = pick_plan(latest_current.get("plan"), cached_plan, account["plan"])
                left = render_left(latest_current["left"], latest_current["mtime"], plan, history=False)
                primary_reset_ts = latest_current.get("primary_resets_at") or 0
                secondary_reset_ts = latest_current.get("secondary_resets_at") or 0
                primary_reset = render_reset(primary_reset_ts)
                secondary_reset = render_reset(secondary_reset_ts)
                checked_ts = int(latest_current["mtime"])
            elif isinstance(cached, dict):
                plan = pick_plan(cached_plan, account["plan"])
                if cached.get("left"):
                    left = render_left(cached["left"], cached.get("updated_at"), plan, history=False)
                primary_reset_ts = cached.get("primary_resets_at") or 0
                secondary_reset_ts = cached.get("secondary_resets_at") or 0
                primary_reset = render_reset(primary_reset_ts)
                secondary_reset = render_reset(secondary_reset_ts)
                if left != "unknown":
                    checked_ts = int(cached.get("updated_at") or 0)
        else:
            history = history_by_index.get(index - 1)
            history_updated_at = int(history["mtime"]) if history else 0
            cached_updated_at = int(cached.get("updated_at") or 0) if isinstance(cached, dict) else 0
            if history and history_updated_at >= cached_updated_at:
                plan = pick_plan(history.get("plan"), cached_plan, account["plan"])
                left = render_left(history["left"], history["mtime"], plan, history=True)
                primary_reset_ts = history.get("primary_resets_at") or 0
                secondary_reset_ts = history.get("secondary_resets_at") or 0
                primary_reset = render_reset(primary_reset_ts)
                secondary_reset = render_reset(secondary_reset_ts)
                checked_ts = int(history["mtime"])
            elif isinstance(cached, dict):
                plan = pick_plan(cached_plan, account["plan"])
                if cached.get("left"):
                    left = render_left(cached["left"], cached.get("updated_at"), plan, history=True)
                primary_reset_ts = cached.get("primary_resets_at") or 0
                secondary_reset_ts = cached.get("secondary_resets_at") or 0
                primary_reset = render_reset(primary_reset_ts)
                secondary_reset = render_reset(secondary_reset_ts)
                if left != "unknown":
                    checked_ts = int(cached.get("updated_at") or 0)

        fh.write(
            f"{index}\t{marker}\t{account['email']}\t{plan}\t{left}\t"
            f"{primary_reset}\t{secondary_reset}\t{checked_ts}\t"
            f"{primary_reset_ts}\t{secondary_reset_ts}\n"
        )
PY
}

rebuild_auth_list() {
  list_file="$1"

  if [ -f "$CURRENT_AUTH" ]; then
    printf '%s\n' "$CURRENT_AUTH" > "$list_file"
  else
    : > "$list_file"
  fi

  find "$CODEX_DIR" -maxdepth 1 -type f -name 'auth*.json' ! -name 'auth.json' | sort | while IFS= read -r file; do
    if [ -f "$CURRENT_AUTH" ] && cmp -s "$file" "$CURRENT_AUTH"; then
      continue
    fi
    printf '%s\n' "$file"
  done >> "$list_file"
}

render_account_table() {
  printf 'Codex 认证目录: %s\n' "$CODEX_DIR"
  printf '可切换账号列表:\n'

  awk -F '	' '
    {
      row_count++
      rows[row_count] = $0
      if (length($1) > w1) w1 = length($1)
      if (length($2) > w2) w2 = length($2)
      if (length($3) > w3) w3 = length($3)
      if (length($4) > w4) w4 = length($4)
      if (length($5) > w5) w5 = length($5)
      if (length($6) > w6) w6 = length($6)
      if (length($7) > w7) w7 = length($7)
    }
    END {
      if (w1 < length("No")) w1 = length("No")
      if (w2 < length("Now")) w2 = length("Now")
      if (w3 < length("Email")) w3 = length("Email")
      if (w4 < length("Plan")) w4 = length("Plan")
      if (w5 < length("Left")) w5 = length("Left")
      if (w6 < length("5h Reset")) w6 = length("5h Reset")
      if (w7 < length("7d Reset")) w7 = length("7d Reset")

      fmt = "  %-" w1 "s  %-" w2 "s  %-" w3 "s  %-" w4 "s  %-" w5 "s  %-" w6 "s  %-" w7 "s\n"
      printf fmt, "No", "Now", "Email", "Plan", "Left", "5h Reset", "7d Reset"
      printf fmt, "--", "---", "-----", "----", "-----", "--------", "--------"

      for (i = 1; i <= row_count; i++) {
        split(rows[i], cols, FS)
        printf fmt, cols[1], cols[2], cols[3], cols[4], cols[5], cols[6], cols[7]
      }
    }
  ' "$TMP_ROWS"
}

if [ ! -d "$CODEX_DIR" ]; then
  printf '目录不存在: %s\n' "$CODEX_DIR" >&2
  exit 1
fi

TMP_LIST="$(mktemp)"
TMP_ROWS="$(mktemp)"
trap 'rm -f "$TMP_LIST" "$TMP_ROWS"' EXIT HUP INT TERM
CACHE_FILE="${CACHE_FILE:-$CODEX_DIR/account_usage_cache.json}"

while :; do
  rebuild_auth_list "$TMP_LIST"

  if [ ! -s "$TMP_LIST" ]; then
    printf '在 %s 下没有找到可切换的 auth*.json 文件。\n' "$CODEX_DIR" >&2
    exit 1
  fi

  build_rows "$TMP_LIST" "$TMP_ROWS" "$CURRENT_AUTH" "$CACHE_FILE"
  render_account_table

  printf '\n请输入要切换的序号，或输入 q 退出，输入 r 刷新: '
  IFS= read -r choice

  case "$choice" in
    q|Q)
      printf '已取消。\n'
      exit 0
      ;;
    r|R)
      printf '\n'
      continue
      ;;
    ''|*[!0-9]*)
      printf '输入无效: %s\n' "$choice" >&2
      exit 1
      ;;
  esac

  break
done

SELECTED_FILE="$(sed -n "${choice}p" "$TMP_LIST")"

if [ -z "$SELECTED_FILE" ]; then
  printf '序号超出范围: %s\n' "$choice" >&2
  exit 1
fi

CURRENT_ROW="$(awk -F '	' '$2=="*" {print; exit}' "$TMP_ROWS")"
SELECTED_ROW="$(sed -n "${choice}p" "$TMP_ROWS")"

OLD_CURRENT_PLAN=""
OLD_CURRENT_LEFT=""
OLD_CURRENT_PRIMARY_RESET="-"
OLD_CURRENT_SECONDARY_RESET="-"
OLD_CURRENT_PRIMARY_RESETS_AT="0"
OLD_CURRENT_SECONDARY_RESETS_AT="0"
OLD_CURRENT_CHECKED_TS="0"
if [ -n "$CURRENT_ROW" ]; then
  IFS='	' read -r OLD_CURRENT_NO OLD_CURRENT_NOW OLD_CURRENT_EMAIL OLD_CURRENT_PLAN OLD_CURRENT_LEFT OLD_CURRENT_PRIMARY_RESET OLD_CURRENT_SECONDARY_RESET OLD_CURRENT_CHECKED_TS OLD_CURRENT_PRIMARY_RESETS_AT OLD_CURRENT_SECONDARY_RESETS_AT <<EOF
$CURRENT_ROW
EOF
fi

SELECTED_PLAN=""
SELECTED_LEFT=""
SELECTED_CHECKED_TS="0"
if [ -n "$SELECTED_ROW" ]; then
  IFS='	' read -r SELECTED_NO SELECTED_NOW SELECTED_EMAIL SELECTED_PLAN SELECTED_LEFT SELECTED_PRIMARY_RESET SELECTED_SECONDARY_RESET SELECTED_CHECKED_TS SELECTED_PRIMARY_RESETS_AT SELECTED_SECONDARY_RESETS_AT <<EOF
$SELECTED_ROW
EOF
fi

if [ -f "$CURRENT_AUTH" ] && cmp -s "$SELECTED_FILE" "$CURRENT_AUTH"; then
  printf '当前已经是该账号: %s\n' "$(basename "$SELECTED_FILE")"
  exit 0
fi

stop_codex_app

if [ -f "$CURRENT_AUTH" ]; then
  cache_auth_snapshot "$CACHE_FILE" "$CURRENT_AUTH" "$OLD_CURRENT_PLAN" "$OLD_CURRENT_LEFT" "$OLD_CURRENT_CHECKED_TS" "$OLD_CURRENT_PRIMARY_RESETS_AT" "$OLD_CURRENT_SECONDARY_RESETS_AT"
fi

if [ -f "$CURRENT_AUTH" ]; then
  backup_file="$(ensure_saved_auth_copy "$CURRENT_AUTH")"
  printf '已确认当前账号副本: %s\n' "$(basename "$backup_file")"
fi

cp "$SELECTED_FILE" "$CURRENT_AUTH"

SWITCHED_AT="$(date +%s)"
mark_auth_activation "$CACHE_FILE" "$CURRENT_AUTH" "$SELECTED_PLAN" "$SWITCHED_AT"

printf '切换完成，当前账号文件: %s\n' "$CURRENT_AUTH"

if ! start_codex_app; then
  printf '账号已切换，但 Codex 未能自动启动。\n' >&2
  exit 1
fi
