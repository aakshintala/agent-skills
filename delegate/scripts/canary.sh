#!/usr/bin/env bash
# canary.sh: run one ticket's brief on pi and Fiber side by side, with metrics.
#
# Usage:
#   canary.sh run <ticket> <brief file> --gate '<gate>' [--repo owner/name] [--clone <path>] [--out DIR]
#   canary.sh clean <ticket> [--out DIR]
#
# Exit codes: 0 both runs finished, whatever their gates did;
# 1 a run errored in the harness; 2 usage or setup error.
#
# The script never pushes, never opens a PR, and apart from the single
# `git fetch origin` in the clone it makes no network calls itself. The brief
# is wrapped with a line telling each agent to commit locally and not push.
set -uo pipefail

PI_MODEL="opencode-go/muse-spark-1.3-contributor"
FIBER_MODEL="fiber/opencode-go/muse-spark-1.3-contributor"
DEFAULT_REPO="aakshintala/fiber"

TAB="$(printf '\t')"

# TOK_QT matches one double-quoted, single-quoted, or bare token.
TOK_QT="\"[^\"]*\"|'[^']*'"

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/metrics.sh"

# Sandbox rules (see #223). Rows read class<TAB>tool<TAB>ERE, matched against
# "<tool> <command|path>" with ~, $HOME, $TMPDIR and $PWD expanded. needs_out
# rows are tried first, then unknown rows; anything else is contained.
# Writes to a path outside the allowed roots (the worktree, $TMPDIR, /tmp,
# /private/tmp, /dev/null) are judged by write_outside, next to the table.
SANDBOX_NEEDS_OUT="$(printf '%s\n' \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])(curl|wget)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])gh([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])git[[:space:]]+(fetch|push|clone|pull|ls-remote|submodule[[:space:]]+update)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])(npm|pnpm|yarn|bun)[[:space:]]+(install|i|ci|add|update)([^[:alnum:]_-]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])npx([^[:alnum:]_-]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])pip3?[[:space:]]+install([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])uv[[:space:]]+(pip[[:space:]]+install|sync|add)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])brew([^[:alnum:]_-]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])cargo[[:space:]]+(install|fetch|update|add|search)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])go[[:space:]]+(get|mod[[:space:]]+download)([^[:alnum:]_]|\$)" \
  "needs_out${TAB}bash${TAB}(^|[^[:alnum:]_])(ssh|scp|rsync|nc)([^[:alnum:]_-]|\$)")"

SANDBOX_UNKNOWN="$(printf '%s\n' \
  "unknown${TAB}*${TAB}(^|[^[:alnum:]_])\\.\\.([^[:alnum:]_]|\$)" \
  "unknown${TAB}*${TAB}\\\$[A-Za-z_0-9{?#*@!$]" \
  "unknown${TAB}bash${TAB}(^|[^[:alnum:]_])eval([^[:alnum:]_]|\$)" \
  "unknown${TAB}bash${TAB}(^|[^[:alnum:]_])(bash|sh|zsh)[[:space:]]+-c([^[:alnum:]_]|\$)" \
  "unknown${TAB}bash${TAB}(^|[^[:alnum:]_])xargs([^[:alnum:]_]|\$)" \
  "unknown${TAB}bash${TAB}[|][[:space:]]*(python3|python|sh|bash|node|perl)([^[:alnum:]_]|$)")"

err() {
  printf 'canary: %s\n' "$*" >&2
}

usage() {
  err "usage: canary.sh run <ticket> <brief file> --gate '<gate>' [--repo owner/name] [--clone <path>] [--out DIR]"
  err "       canary.sh clean <ticket> [--out DIR]"
}

now_ms() {
  printf '%d' "$(( $(date +%s) * 1000 ))"
}

# match_table TABLE TEXT TOOL: true when a row for TOOL (or *) matches TEXT.
match_table() {
  local table="$1" text="$2" tool="$3" line cls rest row_tool ere
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    cls="${line%%$TAB*}"; rest="${line#*$TAB}"
    row_tool="${rest%%$TAB*}"; ere="${rest#*$TAB}"
    if [ "$row_tool" = "*" ] || [ "$row_tool" = "$tool" ]; then
      if printf '%s' "$text" | grep -Eq "$ere"; then return 0; fi
    fi
  done <<<"$table"
  return 1
}

# expand_bare TEXT NAME VALUE: replace $NAME only when the next character
# is not [A-Za-z0-9_] (end of string counts as a boundary). A longer
# name such as $TMPDIR_BACKUP is left for the unknown rules.
expand_bare() {
  local text="$1" name="$2" value="$3"
  local needle="\$$name" out="" rest="$text" pre="" tail="" next=""
  while :; do
    case "$rest" in
      *"$needle"*)
        pre="${rest%%"$needle"*}"
        tail="${rest#*"$needle"}"
        next="${tail:0:1}"
        case "$next" in
          ""|[!A-Za-z0-9_]) out="$out$pre$value"; rest="$tail" ;;
          *) out="$out$pre$needle"; rest="$tail" ;;
        esac ;;
      *) out="$out$rest"; break ;;
    esac
  done
  printf '%s' "$out"
}

# normalize_text TEXT WORKTREE TMPDIR: expand ~, $HOME, $TMPDIR, $PWD.
normalize_text() {
  local t="$1" wt="$2" tmp="$3" home="${HOME:-/tmp}" esc
  tmp="${tmp%/}"; [ -n "$tmp" ] || tmp="/tmp"
  t="${t//\$\{HOME\}/$home}"
  t="$(expand_bare "$t" "HOME" "$home")"
  t="${t//\$\{TMPDIR\}/$tmp}"
  t="$(expand_bare "$t" "TMPDIR" "$tmp")"
  t="${t//\$\{PWD\}/$wt}"
  t="$(expand_bare "$t" "PWD" "$wt")"
  t="${t//\~\//$home/}"
  esc="$(printf '%s' "$home" | sed -e 's/[#\\/&]/\\&/g')"
  t="$(printf '%s' "$t" | sed -E "s#(^|[[:space:]\"'=])~([[:space:]\"']|\$)#\1${esc}\2#g")"
  printf '%s' "$t"
}

# path_outside PATH WORKTREE TMPDIR: true for an absolute path outside the
# allowed roots (the worktree, $TMPDIR, /tmp, /private/tmp, /dev/null).
path_outside() {
  local p="$1" wt="$2" tmp="$3" r
  tmp="${tmp%/}"; [ -n "$tmp" ] || tmp="/tmp"
  case "$p" in /*) ;; *) return 1 ;; esac
  for r in "$wt" "$tmp" /tmp /private/tmp /dev/null; do
    [ -n "$r" ] || continue
    if [ "$p" = "$r" ] || [[ "$p" == "$r"/* ]]; then return 1; fi
  done
  return 0
}

# write_targets_bash TEXT: redirect targets and write-verb operands of a bash
# command, one per line. Verb operands over-approximate (sources count too).
# operands_of CHUNK: whitespace-separated tokens, one per line, quotes stripped.
operands_of() {
  local chunk="$1" tok
  while IFS= read -r tok || [ -n "$tok" ]; do
    [ -n "$tok" ] || continue
    tok="${tok#\"}"; tok="${tok%\"}"; tok="${tok#\'}"; tok="${tok%\'}"
    printf '%s\n' "$tok"
  done < <(printf '%s' "$chunk" | grep -Eo "(${TOK_QT}|[^[:space:]]+)")
}

# write_targets_bash TEXT: redirect targets and write-verb operands of a bash
# command, one per line. Verb operands over-approximate (sources count too).
write_targets_bash() {
  local text="$1" m chunk op verbs verb
  verbs="tee cp mv rm mkdir touch ln install"
  while IFS= read -r m || [ -n "$m" ]; do
    [ -n "$m" ] || continue
    chunk="$(printf '%s' "$m" | sed -E 's/^[0-9]*>>?[[:space:]]*//')"
    operands_of "$chunk"
  done < <(printf '%s' "$text" | grep -Eo "[0-9]*>>?[[:space:]]*(${TOK_QT}|[^[:space:];|&()<>]+)")
  if printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_-])sed[[:space:]]+[^;&|]*(-[A-Za-z]*i|--in-place)([^[:alnum:]_]|$)'; then
    verbs="$verbs sed"
  fi
  for verb in $verbs; do
    while IFS= read -r m || [ -n "$m" ]; do
      [ -n "$m" ] || continue
      chunk="${m#*"$verb"}"
      chunk="${chunk#"${chunk%%[![:space:]]*}"}"
      while IFS= read -r op || [ -n "$op" ]; do
        [ -n "$op" ] || continue
        case "$op" in -*) ;; *) printf '%s\n' "$op" ;; esac
      done < <(operands_of "$chunk")
    done < <(printf '%s' "$text" | grep -Eo "(^|[[:space:];|&()])${verb}[[:space:]]+[^;|&]+")
  done
}

# write_outside TOOL NTEXT NARG WORKTREE TMPDIR: true when a write lands
# outside the allowed roots (redirect/verb targets for bash, the path for
# write/edit).
write_outside() {
  local name="$1" ntext="$2" narg="$3" wt="$4" tmp="$5" cand
  if [ "$name" = "write" ] || [ "$name" = "edit" ]; then
    path_outside "$narg" "$wt" "$tmp" && return 0
    return 1
  fi
  while IFS= read -r cand || [ -n "$cand" ]; do
    [ -n "$cand" ] || continue
    if path_outside "$cand" "$wt" "$tmp"; then return 0; fi
  done <<<"$(write_targets_bash "$ntext")"
  return 1
}

# cd_outside TEXT WORKTREE TMPDIR: true when cd/pushd leaves the allowed
# roots (or its target cannot be settled: bare, `-`, or relative).
cd_outside() {
  local text="$1" wt="$2" tmp="$3" m verb chunk tgt
  while IFS= read -r m || [ -n "$m" ]; do
    [ -n "$m" ] || continue
    verb="cd"
    case "$m" in *pushd*) verb="pushd" ;; esac
    chunk="${m#*"$verb"}"
    tgt="$(operands_of "$chunk" | head -n 1)"
    if [ -z "$tgt" ]; then return 0; fi
    case "$tgt" in -*) return 0 ;; esac
    if path_outside "$tgt" "$wt" "$tmp"; then return 0; fi
    case "$tgt" in /*) ;; *) return 0 ;; esac
  done < <(printf '%s' "$text" | grep -Eo "(^|[[:space:];|&()])(cd|pushd)([[:space:];|&]|$)[^;|&]*")
  return 1
}

# abs_outside TEXT WORKTREE TMPDIR: true when any absolute path in TEXT lies
# outside the allowed roots.
abs_outside() {
  local text="$1" wt="$2" tmp="$3" tok
  while IFS= read -r tok || [ -n "$tok" ]; do
    [ -n "$tok" ] || continue
    case "$tok" in /*)
      if path_outside "$tok" "$wt" "$tmp"; then return 0; fi ;;
    esac
  done < <(operands_of "$text")
  return 1
}
emit_decision() {
  local file="$1" cls="$2" text="$3"
  text="$(printf '%s' "$text" | cut -c1-200)"
  jq -n --arg class "$cls" --arg command "$text" '{class:$class,command:$command}' >>"$file"
}

# classify_side EVENTS WORKTREE TMPDIR DECISIONS: judge every reviewed call
# (permission_resolved with decided_by == reviewer, joined to its
# tool_call_requested) into DECISIONS as JSONL.
classify_side() {
  local ev="$1" wt="$2" tmp="$3" decisions="$4"
  local aid req name argstype arg text ntext narg
  : >"$decisions"
  while IFS= read -r aid || [ -n "$aid" ]; do
    [ -n "$aid" ] || continue
    req="$(jq -c --arg a "$aid" 'select(.kind=="tool_call_requested" and .action_id==$a)
      | .payload' "$ev" 2>/dev/null | head -n 1)"
    if [ -z "$req" ]; then
      emit_decision "$decisions" "unknown" "unknown"
      continue
    fi
    name="$(printf '%s' "$req" | jq -r '.name // ""' 2>/dev/null)"
    argstype="$(printf '%s' "$req" | jq -r '.arguments | type' 2>/dev/null)"
    if [ "$argstype" != "object" ]; then
      arg="$(printf '%s' "$req" | jq -c '.arguments' 2>/dev/null)"
      emit_decision "$decisions" "unknown" "$name $arg"
      continue
    fi
    case "$name" in
      bash)
        arg="$(printf '%s' "$req" | jq -r '.arguments.command
          | if type=="string" then . else tojson end' 2>/dev/null)"
        text="bash $arg" ;;
      write|edit)
        arg="$(printf '%s' "$req" | jq -r '.arguments.path
          | if type=="string" then . else tojson end' 2>/dev/null)"
        text="$name $arg" ;;
      *)
        arg="$(printf '%s' "$req" | jq -c '.arguments' 2>/dev/null)"
        emit_decision "$decisions" "unknown" "$name $arg"
        continue ;;
    esac
    ntext="$(normalize_text "$text" "$wt" "$tmp")"
    narg="$(normalize_text "$arg" "$wt" "$tmp")"
    if match_table "$SANDBOX_NEEDS_OUT" "$ntext" "$name"; then
      emit_decision "$decisions" "needs_out" "$ntext"
    elif write_outside "$name" "$ntext" "$narg" "$wt" "$tmp"; then
      emit_decision "$decisions" "needs_out" "$ntext"
    elif match_table "$SANDBOX_UNKNOWN" "$ntext" "$name"; then
      emit_decision "$decisions" "unknown" "$ntext"
    elif [ "$name" = "bash" ] \
      && { cd_outside "$ntext" "$wt" "$tmp" || abs_outside "$ntext" "$wt" "$tmp"; }; then
      emit_decision "$decisions" "unknown" "$ntext"
    else
      emit_decision "$decisions" "contained" "$ntext"
    fi
  done <<<"$(jq -r 'select(.kind=="permission_resolved" and .payload.decided_by=="reviewer")
    | .action_id // ""' "$ev" 2>/dev/null)"
}

# write_prompt BRIEF WORKTREE BRANCH: the brief plus the no-push wrapper line.
write_prompt() {
  local brief="$1" wt="$2" branch="$3"
  { cat "$brief"
    printf '\n%s\n' "Canary run: work only in $wt. Commit your work locally on branch $branch. Do not push, and do not open a PR."
  }
}

# canary_worktree CLONE TICKET SIDE: the worktree path for one side, next
# to the clone and named after it.
canary_worktree() {
  local clone="$1" ticket="$2" side="$3"
  printf '%s/%s-canary-%s-%s' "$(dirname "$clone")" "$(basename "$clone")" "$ticket" "$side"
}

# clean_ticket CLONE TICKET OUT [--force]: remove whatever exists of the
# ticket's two worktrees and two branches, then the <side>/worktree files.
# Without --force a dirty worktree refuses (git's message, return 1).
# Idempotent: with nothing left it returns 0.
clean_ticket() {
  local clone="$1" ticket="$2" out="$3" force="${4:-}" side wt branch
  for side in pi fiber; do
    wt="$(canary_worktree "$clone" "$ticket" "$side")"
    [ -e "$wt" ] || continue
    if [ "$force" = "--force" ]; then
      git -C "$clone" worktree remove --force "$wt" || return 1
    else
      git -C "$clone" worktree remove "$wt" || return 1
    fi
  done
  git -C "$clone" worktree prune || return 1
  for side in pi fiber; do
    branch="canary/$ticket-$side"
    if git -C "$clone" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$clone" branch -D "$branch" >/dev/null || return 1
    fi
  done
  rm -f "$out/pi/worktree" "$out/fiber/worktree"
  return 0
}

cmd_run() {
  [ $# -ge 2 ] || { usage; return 2; }
  local ticket="$1" brief="$2"
  shift 2
  local gate="" repo="$DEFAULT_REPO" clone="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --gate) [ $# -ge 2 ] || { err "--gate needs a value"; return 2; }; gate="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || { err "--repo needs a value"; return 2; }; repo="$2"; shift 2 ;;
      --clone) [ $# -ge 2 ] || { err "--clone needs a value"; return 2; }; clone="$2"; shift 2 ;;
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  [[ "$ticket" =~ ^[0-9A-Za-z._-]+$ ]] || { err "bad ticket '$ticket'"; return 2; }
  [ -n "$gate" ] || { err "--gate is required"; return 2; }
  [ -f "$brief" ] || { err "brief file $brief missing"; return 2; }
  local repo_name="${repo##*/}"
  [ -n "$repo_name" ] || { err "bad --repo '$repo'"; return 2; }
  [ -z "$clone" ] && clone="$HOME/work/$repo_name"
  [ -z "$out" ] && out="$HOME/.cache/agents/canary/$ticket"
  git -C "$clone" rev-parse --git-common-dir >/dev/null 2>&1 \
    || { err "clone $clone is not a git checkout"; return 2; }
  clone="$(cd "$clone" && pwd)"
  local pi_branch="canary/$ticket-pi" fiber_branch="canary/$ticket-fiber"
  local pi_wt fiber_wt
  pi_wt="$(canary_worktree "$clone" "$ticket" pi)"
  fiber_wt="$(canary_worktree "$clone" "$ticket" fiber)"
  local b
  for b in "$pi_branch" "$fiber_branch"; do
    if git -C "$clone" show-ref --verify --quiet "refs/heads/$b"; then
      err "branch $b exists; run 'canary.sh clean $ticket' first"
      return 2
    fi
  done
  if [ -e "$pi_wt" ] || [ -e "$fiber_wt" ]; then
    err "a worktree path exists; run 'canary.sh clean $ticket' first"
    return 2
  fi
  if [ -f "$out/pi/worktree" ] || [ -f "$out/fiber/worktree" ]; then
    err "a previous run exists in $out; run 'canary.sh clean $ticket' first"
    return 2
  fi
  # Record the clone before any git mutation, so clean can always find it.
  mkdir -p "$out"
  printf '%s\n' "$clone" >"$out/clone"
  git -C "$clone" fetch origin >/dev/null 2>&1 \
    || { err "git fetch origin failed in $clone"; return 2; }
  local base
  base="$(git -C "$clone" rev-parse origin/main 2>/dev/null)" \
    || { err "no origin/main in $clone"; return 2; }
  local side
  for side in pi fiber; do
    if [ -d "$out/$side" ] && [ ! -f "$out/$side/worktree" ]; then
      rm -rf "$out/$side"
    fi
    mkdir -p "$out/$side"
  done
  mkdir -p "$(dirname "$clone")"
  for side in pi fiber; do
    local wt branch
    wt="$(canary_worktree "$clone" "$ticket" "$side")"
    branch="canary/$ticket-$side"
    if ! git -C "$clone" worktree add -b "$branch" "$wt" "$base" >/dev/null 2>&1; then
      err "worktree add failed for $wt"
      clean_ticket "$clone" "$ticket" "$out" --force \
        || err "cleanup failed; run 'canary.sh clean $ticket' after fixing the cause"
      return 2
    fi
    printf '%s' "$wt" >"$out/$side/worktree"
  done
  write_prompt "$brief" "$pi_wt" "$pi_branch" >"$out/pi/prompt.md"
  write_prompt "$brief" "$fiber_wt" "$fiber_branch" >"$out/fiber/prompt.md"

  local delegate_bin="${DELEGATE_BIN:-delegate}"
  FIBER_EVENTS_ROOT="${FIBER_HOME:-$HOME/.fiber}"
  local jobs_dir="${TMPDIR:-/tmp}/delegate-jobs"
  local tmp_root="${TMPDIR:-/tmp}"
  : >"$out/pi/delegate.log"
  : >"$out/fiber/delegate.log"

  # Launch barrier: both runs in the foreground (each returns a job id at
  # once); only then do the watches start, each in its own background job.
  local pi_start pi_out pi_rc pi_id pi_run_ok=1 pi_note=""
  local fiber_start fiber_out fiber_rc fiber_id fiber_run_ok=1 fiber_note=""
  pi_start="$(now_ms)"
  pi_out="$("$delegate_bin" run --model "$PI_MODEL" --cwd "$pi_wt" \
    --prompt-file "$out/pi/prompt.md" 2>>"$out/pi/delegate.log")"
  pi_rc=$?
  pi_id="$(printf '%s' "$pi_out" | tail -n 1 | tr -d '[:space:]')"
  if [ "$pi_rc" -ne 0 ]; then pi_run_ok=0; pi_note="delegate run failed (exit $pi_rc)";
  elif [ -z "$pi_id" ]; then pi_run_ok=0; pi_note="delegate run printed no job id"; fi
  fiber_start="$(now_ms)"
  fiber_out="$("$delegate_bin" run --model "$FIBER_MODEL" --cwd "$fiber_wt" \
    --prompt-file "$out/fiber/prompt.md" 2>>"$out/fiber/delegate.log")"
  fiber_rc=$?
  fiber_id="$(printf '%s' "$fiber_out" | tail -n 1 | tr -d '[:space:]')"
  if [ "$fiber_rc" -ne 0 ]; then fiber_run_ok=0; fiber_note="delegate run failed (exit $fiber_rc)";
  elif [ -z "$fiber_id" ]; then fiber_run_ok=0; fiber_note="delegate run printed no job id"; fi

  local pi_wp="" fiber_wp=""
  local pi_wrc_file="$out/pi/.watch_rc" fiber_wrc_file="$out/fiber/.watch_rc"
  local pi_end_file="$out/pi/.watch_end" fiber_end_file="$out/fiber/.watch_end"
  if [ "$pi_run_ok" -eq 1 ]; then
    ( "$delegate_bin" watch "$pi_id" >>"$out/pi/delegate.log" 2>&1
      echo "$?" >"$pi_wrc_file"; now_ms >"$pi_end_file" ) &
    pi_wp=$!
  fi
  if [ "$fiber_run_ok" -eq 1 ]; then
    ( "$delegate_bin" watch "$fiber_id" >>"$out/fiber/delegate.log" 2>&1
      echo "$?" >"$fiber_wrc_file"; now_ms >"$fiber_end_file" ) &
    fiber_wp=$!
  fi
  local pi_end fiber_end pi_wrc=0 fiber_wrc=0
  if [ -n "$pi_wp" ]; then wait "$pi_wp"; fi
  if [ -f "$pi_wrc_file" ]; then pi_wrc="$(cat "$pi_wrc_file")"; fi
  if [ -f "$pi_end_file" ]; then pi_end="$(cat "$pi_end_file")"; else pi_end="$(now_ms)"; fi
  if [ -n "$fiber_wp" ]; then wait "$fiber_wp"; fi
  if [ -f "$fiber_wrc_file" ]; then fiber_wrc="$(cat "$fiber_wrc_file")"; fi
  if [ -f "$fiber_end_file" ]; then fiber_end="$(cat "$fiber_end_file")"; else fiber_end="$(now_ms)"; fi
  rm -f "$pi_wrc_file" "$pi_end_file" "$fiber_wrc_file" "$fiber_end_file"

  # Gates run in each worktree once both jobs end.
  local pi_gate_exit fiber_gate_exit
  ( cd "$pi_wt" && bash -c "$gate" ) >"$out/pi/gate.log" 2>&1
  pi_gate_exit=$?
  printf '%s' "$pi_gate_exit" >"$out/pi/gate.exit"
  ( cd "$fiber_wt" && bash -c "$gate" ) >"$out/fiber/gate.log" 2>&1
  fiber_gate_exit=$?
  printf '%s' "$fiber_gate_exit" >"$out/fiber/gate.exit"

  run_side_metrics pi "$pi_wt" "$pi_id" "$PI_MODEL" "$pi_run_ok" "$pi_note" \
    "$pi_wrc" "$pi_start" "$pi_end" "$out" "$base" "$jobs_dir" "$tmp_root"
  run_side_metrics fiber "$fiber_wt" "$fiber_id" "$FIBER_MODEL" "$fiber_run_ok" "$fiber_note" \
    "$fiber_wrc" "$fiber_start" "$fiber_end" "$out" "$base" "$jobs_dir" "$tmp_root"

  write_summary "$ticket" "$base" "$out"

  if [ -f "$out/pi/.harness" ] || [ -f "$out/fiber/.harness" ]; then
    rm -f "$out/pi/.harness" "$out/fiber/.harness"
    return 1
  fi
  return 0
}

# run_side_metrics SIDE WORKTREE ID MODEL RUN_OK RUN_NOTE WATCH_RC START_MS
#   END_MS OUT BASE JOBS_DIR TMPROOT: diff, dirty flag and metrics.json.
run_side_metrics() {
  local side="$1" wt="$2" id="$3" model="$4" run_ok="$5" run_note="$6"
  local wrc="$7" start_ms="$8" end_ms="$9" out="${10}" base="${11}"
  local jobs_dir="${12}" tmp_root="${13}"
  local dir="$out/$side" rec="" outcome="" harness=0
  git -C "$wt" diff "$base...HEAD" >"$dir/diff.patch" 2>/dev/null || true
  local dirty="false"
  [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && dirty="true"
  local notes="$dir/.notes.txt" den_tsv="$dir/.denials.tsv" decisions="$dir/.decisions.jsonl"
  : >"$notes"; : >"$den_tsv"; : >"$decisions"
  [ -n "$run_note" ] && printf '%s\n' "$run_note" >>"$notes"
  if [ "$run_ok" -eq 1 ] && [ "$wrc" -ne 0 ]; then
    printf 'delegate watch failed (exit %s)\n' "$wrc" >>"$notes"
    harness=1
  fi
  if [ "$run_ok" -eq 0 ]; then harness=1; fi
  if [ -n "$id" ] && [ -f "$jobs_dir/$id.json" ]; then
    rec="$jobs_dir/$id.json"
  elif [ "$run_ok" -eq 1 ] && [ "$wrc" -eq 0 ]; then
    printf 'job record missing: %s/%s.json\n' "$jobs_dir" "$id" >>"$notes"
    harness=1
  fi
  if [ "$harness" -eq 1 ]; then
    outcome="harness_error"
    : >"$dir/.harness"
  elif [ -n "$rec" ]; then
    outcome="$(jq -r '.status // "unknown"' "$rec" 2>/dev/null)"
    [ "$outcome" = "null" ] && outcome="unknown"
  else
    outcome="harness_error"
    : >"$dir/.harness"
  fi
  local wall_ms=$((end_ms - start_ms))
  local m_in="" m_out="" m_cr="" m_total="" m_main="" m_reviewer=""
  local rc="" rt="" per="" split=""
  if [ "$side" = "pi" ]; then
    if [ -n "$rec" ]; then
      m_total="$(pi_metrics "$rec" "" | sed -n 3p)"
      m_in="$(pi_metrics "$rec" "" | sed -n 4p)"
      m_out="$(pi_metrics "$rec" "" | sed -n 5p)"
      m_cr="$(pi_metrics "$rec" "" | sed -n 6p)"
      m_main="$m_total"
    fi
    m_reviewer="0"
    rc="0"
  else
    if [ -n "$rec" ]; then
      m_total="$(fiber_metrics "$rec" | sed -n 3p)"
      m_in="$(fiber_metrics "$rec" | sed -n 4p)"
      m_out="$(fiber_metrics "$rec" | sed -n 5p)"
      m_cr="$(fiber_metrics "$rec" | sed -n 6p)"
      split="$(fiber_side_split "$rec" "$wt" "$tmp_root" "$notes" "$den_tsv" "$decisions")"
      m_main="$(printf '%s' "$split" | jq -r '.main_cost')"
      m_reviewer="$(printf '%s' "$split" | jq -r '.reviewer_cost')"
      rt="$(printf '%s' "$split" | jq -r '.reviewer_tokens')"
      rc="$(printf '%s' "$split" | jq -r '.reviewed_calls')"
    else
      printf 'fiber events unavailable without a job record\n' >>"$notes"
    fi
  fi
  if [ -n "$rt" ] && [ "$rt" != "null" ] && [ -n "$rc" ] && [ "$rc" != "null" ] && [ "$rc" != "0" ]; then
    per="$(jq -n --argjson a "$rt" --argjson b "$rc" '$a / $b' 2>/dev/null)"
  fi
  local denials_json sandbox_json notes_json
  denials_json="$(jq -R -s 'split("\n") | map(select(length > 0 and . != "EVENTS_MISSING")
    | split("\t") | {action_id: .[0], decided_by: .[1], reason: .[2], command: .[3]})' "$den_tsv")"
  sandbox_json="$(jq -s '{contained: {count: ([.[] | select(.class=="contained")] | length),
      commands: ([.[] | select(.class=="contained") | .command])},
    needs_out: {count: ([.[] | select(.class=="needs_out")] | length),
      commands: ([.[] | select(.class=="needs_out") | .command])},
    unknown: {count: ([.[] | select(.class=="unknown")] | length),
      commands: ([.[] | select(.class=="unknown") | .command])}}' "$decisions")"
  notes_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$notes")"
  jq -n --arg side "$side" --arg outcome "$outcome" --arg job_id "$id" \
    --arg model "$model" --arg base "$base" --argjson dirty "$dirty" \
    --arg wall "$wall_ms" --arg in "$m_in" --arg o "$m_out" --arg cr "$m_cr" \
    --arg total "$m_total" --arg main "$m_main" --arg reviewer "$m_reviewer" \
    --arg rc "$rc" --arg per "$per" \
    --argjson denials "$denials_json" --argjson sandbox "$sandbox_json" \
    --argjson notes "$notes_json" \
    'def n: if . == "" or . == "null" then null else tonumber end;
    {side: $side, outcome: $outcome,
     job_id: (if $job_id == "" then null else $job_id end),
     model: $model, base: $base, dirty: $dirty, wall_ms: ($wall | tonumber),
     tokens: {input: ($in | n), output: ($o | n), cache_read: ($cr | n)},
     cost: {total: ($total | n), main: ($main | n), reviewer: ($reviewer | n)},
     reviewed_calls: ($rc | n), denials: $denials, sandbox: $sandbox,
     per_review_tokens_est: ($per | n), notes: $notes}' >"$dir/metrics.json"
  rm -f "$notes" "$den_tsv" "$decisions"
}

# fiber_side_split RECORD WORKTREE TMPROOT NOTES DEN_TSV DECISIONS: print the
# reviewer_split JSON for the fiber side; denials and sandbox classes go to
# DEN_TSV and DECISIONS, notes appended to NOTES.
fiber_side_split() {
  local rec="$1" wt="$2" tmp_root="$3" notes="$4" den_tsv="$5" decisions="$6"
  local sid ev split
  sid="$(jq -r '.resume.sessionId // ""' "$rec" 2>/dev/null)"
  ev=""
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    ev="$(fiber_events "$sid")"
  fi
  if [ -z "$ev" ] || ! jq empty "$ev" >/dev/null 2>&1; then
    printf 'fiber events missing or unparsable; cost split unknown\n' >>"$notes"
    printf '{"main_cost":null,"reviewer_cost":null,"reviewer_tokens":null,"reviewed_calls":null}'
    return 0
  fi
  split="$(reviewer_split "$ev")"
  printf '%s' "$split"
  denials_for "$rec" >"$den_tsv" 2>/dev/null || true
  if grep -qx 'EVENTS_MISSING' "$den_tsv" 2>/dev/null; then
    : >"$den_tsv"
    printf 'fiber events missing or unparsable; cost split unknown\n' >>"$notes"
  fi
  classify_side "$ev" "$wt" "$tmp_root" "$decisions"
}

# load_side SIDE OUT: set S_* display fields for the summary table.
load_side() {
  local side="$1" out="$2" metrics
  metrics="$out/$side/metrics.json"
  S_outcome="$(jq -r .outcome "$metrics")"
  if [ "$(cat "$out/$side/gate.exit")" = "0" ]; then S_gate="pass"; else S_gate="fail"; fi
  S_wall="$(fmt_wall "$(jq -r .wall_ms "$metrics")")"
  S_in="$(jq -r '.tokens.input // "unknown"' "$metrics")"
  S_out="$(jq -r '.tokens.output // "unknown"' "$metrics")"
  S_cr="$(jq -r '.tokens.cache_read // "unknown"' "$metrics")"
  S_main="$(fmt_money "$(jq -r '.cost.main // "null"' "$metrics")")"
  S_rev="$(fmt_money "$(jq -r '.cost.reviewer // "null"' "$metrics")")"
  S_rc="$(jq -r '.reviewed_calls // "unknown"' "$metrics")"
  S_den="$(jq -r '.denials | length' "$metrics")"
  S_con="$(jq -r '.sandbox.contained.count' "$metrics")"
  S_need="$(jq -r '.sandbox.needs_out.count' "$metrics")"
  S_unk="$(jq -r '.sandbox.unknown.count' "$metrics")"
  S_per="$(jq -r '.per_review_tokens_est // "unknown"' "$metrics")"
}

# write_summary TICKET BASE OUT: the two-column comparison table.
write_summary() {
  local ticket="$1" base="$2" out="$3"
  local pi_outcome fiber_outcome pi_gate fiber_gate pi_wall fiber_wall
  local pi_in fiber_in pi_out fiber_out pi_cr fiber_cr
  local pi_main fiber_main pi_rev fiber_rev pi_rc fiber_rc
  local pi_den fiber_den pi_con fiber_con pi_need fiber_need pi_unk fiber_unk
  local pi_per fiber_per
  load_side pi "$out"
  pi_outcome="$S_outcome"; pi_gate="$S_gate"; pi_wall="$S_wall"
  pi_in="$S_in"; pi_out="$S_out"; pi_cr="$S_cr"
  pi_main="$S_main"; pi_rev="$S_rev"; pi_rc="$S_rc"; pi_den="$S_den"
  pi_con="$S_con"; pi_need="$S_need"; pi_unk="$S_unk"; pi_per="$S_per"
  load_side fiber "$out"
  fiber_outcome="$S_outcome"; fiber_gate="$S_gate"; fiber_wall="$S_wall"
  fiber_in="$S_in"; fiber_out="$S_out"; fiber_cr="$S_cr"
  fiber_main="$S_main"; fiber_rev="$S_rev"; fiber_rc="$S_rc"; fiber_den="$S_den"
  fiber_con="$S_con"; fiber_need="$S_need"; fiber_unk="$S_unk"; fiber_per="$S_per"
  {
    printf '# Canary %s\n\n' "$ticket"
    printf 'Base `%s`.\n\n' "$base"
    printf '| metric | pi | fiber |\n'
    printf '| --- | --- | --- |\n'
    printf '| outcome | %s | %s |\n' "$pi_outcome" "$fiber_outcome"
    printf '| gate | %s | %s |\n' "$pi_gate" "$fiber_gate"
    printf '| wall | %s | %s |\n' "$pi_wall" "$fiber_wall"
    printf '| tokens in/out/cache-read | %s/%s/%s | %s/%s/%s |\n' \
      "$pi_in" "$pi_out" "$pi_cr" "$fiber_in" "$fiber_out" "$fiber_cr"
    printf '| cost main | %s | %s |\n' "$pi_main" "$fiber_main"
    printf '| cost reviewer | %s | %s |\n' "$pi_rev" "$fiber_rev"
    printf '| reviewed calls | %s | %s |\n' "$pi_rc" "$fiber_rc"
    printf '| denials | %s | %s |\n' "$pi_den" "$fiber_den"
    printf '| contained | %s | %s |\n' "$pi_con" "$fiber_con"
    printf '| needs_out | %s | %s |\n' "$pi_need" "$fiber_need"
    printf '| unknown | %s | %s |\n' "$pi_unk" "$fiber_unk"
    printf '| per-review tokens est | %s | %s |\n' "$pi_per" "$fiber_per"
  } >"$out/summary.md"
}

cmd_clean() {
  [ $# -ge 1 ] || { usage; return 2; }
  local ticket="$1"
  shift
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || { err "--out needs a value"; return 2; }; out="$2"; shift 2 ;;
      --*) err "unknown flag $1"; return 2 ;;
      *) err "unexpected argument $1"; return 2 ;;
    esac
  done
  [[ "$ticket" =~ ^[0-9A-Za-z._-]+$ ]] || { err "bad ticket '$ticket'"; return 2; }
  [ -z "$out" ] && out="$HOME/.cache/agents/canary/$ticket"
  if [ ! -f "$out/clone" ]; then
    printf 'canary: nothing to clean for %s (no %s/clone)\n' "$ticket" "$out"
    return 0
  fi
  local clone
  clone="$(cat "$out/clone")"
  git -C "$clone" rev-parse --git-common-dir >/dev/null 2>&1 \
    || { err "clone $clone (from $out/clone) is not a git checkout"; return 1; }
  clean_ticket "$clone" "$ticket" "$out" || return 1
  return 0
}

cmd="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  run) cmd_run "$@" ;;
  clean) cmd_clean "$@" ;;
  *) usage; exit 2 ;;
esac
