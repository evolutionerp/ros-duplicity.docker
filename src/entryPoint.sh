#!/bin/bash
# ros-duplicity.docker
# Copyright (C) 2017  evolution.it
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

export IFS=$'\n'

## Lib ##
source /lib/utils.lib.sh
source /lib/ros-duplicity.lib.sh

## Core ##
#@func Process pipe command line
# @syn  <JSON>
# @par  JSON: { "pid": "<pid>", "op":"<op>", "mode":"<mode>", "args":[...] }
__bk_run() {
  local json="$*"
  pid="$(echo "$json"|jq -r '.pid')"
  [ "$pid" ] || { log --error "Invalid PID in $json."; return 1; }
  local mode="$(echo "$json"|jq -r '.mode')"
  [ "$mode" ] || { log --error "Invalid mode in $json."; return 1; }
  local op="$(echo "$json"|jq -r '.op')"
  local args=($(echo "$json"|jq -r '.args|values[]'))
  declare -ax __BK_duplicity_overrides __BK_duplicity_overrides_env
  local BK_MODE="$mode"
  local BK_LOCAL_OUTPUT
  local BK_LOCAL_INPUT
  local incl_policy= #blacklist|whitelist
  local incl_list=()
  _argscan() {
    while [ $# -gt 0 ]; do
      case "$1" in
        "-d"|"--duplicity-arg")
          if [ "$2" = '{' ]; then
            while shift; [ "$2" != "}" -a "$#" -gt 0 ]; do
              log --diag -- "--duplicity-arg $2"
              __BK_duplicity_overrides+=("$2")
            done
          else
            log --diag -- "--duplicity-arg $2"
            __BK_duplicity_overrides+=("$2")
          fi
          shift
          ;;
        "-D"|"--duplicity-env")
          if [ "$2" = '{' ]; then
            while shift; [ "$2" != "}" -a "$#" -gt 0 ]; do
              log --diag -- "--duplicity-env $2"
              __BK_duplicity_overrides_env+=("$2")
            done
          else
            log --diag -- "--duplicity-env $2"
            __BK_duplicity_overrides_env+=("$2")
          fi
          shift
          ;;
        "-i"|"--include")
          [ "$incl_policy" = "blacklist" ] && {
            log --error "Argument --include cannot be used together with --exclude."
            return 2
          }
          incl_policy=whitelist
          if [ "$2" = '{' ]; then
            while shift; [ "$2" != "}" -a "$#" -gt 0 ]; do
              log --diag -- "--include $2"
              incl_list+=("$2")
            done
          else
            log --diag -- "--include $2"
            incl_list+=("$2")
          fi
          shift
          ;;
        "-e"|"--exclude")
          [ "$incl_policy" = "whitelist" ] && {
            log --error "Argument --exclude cannot be used together with --include."
            return 2
          }
          incl_policy=blacklist
          if [ "$2" = '{' ]; then
            while shift; [ "$2" != "}" -a "$#" -gt 0 ]; do
              log --diag -- "--exclude $2"
              incl_list+=("$2")
            done
          else
            log --diag -- "--exclude $2"
            incl_list+=("$2")
          fi
          shift
          ;;
        "--cron")
          log --diag -- '--cron'
          ;;
        "--debug")
          DEBUG=1
          log --diag -- '--debug'
          ;;
        *)
          log --error "Unsupported argument: $1"
          return 2
          ;;
      esac
      shift
    done
  }
  _argscan "${args[@]}" || return $?
  rm -Rf '/tmp/bk.d'; mkdir -p '/tmp/bk.d' || { log --error "Unable to initialize temporary workspace! Maybe /tmp isn't writable?"; return 1; }
  case "$op" in
    'b')
      # Perform backup
      BK_LOCAL_OUTPUT="/tmp/bk.d"
      log "--- Backup started ---"
      ;;
    'r')
      # Perform restore
      BK_LOCAL_INPUT="/tmp/bk.d"
      log "--- Restore started ---"
      log "Freezing running containers ..."
      __docker freeze
      ;;
    *)
      log --error "Invalid operation requested."
      return 1;
      ;;
  esac
  if [ "$BK_LOCAL_INPUT" -o "$BK_LOCAL_OUTPUT" ]; then
    local err=
    for c in $(__docker ps); do
      (
        #log --diag "$c"
        local c_strategy
        export BK_MODE
        declare -ax __BK_duplicity_targets __BK_duplicity_envs;
        declare -Ax __BK_strategies __BK_strategies_C __BK_strategies_I;
        local BK_CONTAINER="$(__docker 'get-name' "$c")"
        local BK_CONTAINER_IMAGE="$(__docker 'get-image' "$c")"
        local BK_CONTAINER_UUID="$c"
        # Init environment
        __init_conf
        __init_strategies
        # Skip?
        local c_skip="$(__docker get-label "$c" 'it.evolution.bk.skip')"
        [ -z "$c_skip" -o "$c_skip" = "0" -o "$c_skip" = "false" ] || { bk_log "This container has been excluded via label."; continue; }
        # Alias
        local BK_CONTAINER_ALIAS="$(__docker get-label "$c" 'it.evolution.bk.alias')"
        # Evaluate policies
        [ "$BK_CONTAINER_ALIAS" ] \
          && bk_log "Has alias: $BK_CONTAINER_ALIAS" \
          || BK_CONTAINER_ALIAS="$BK_CONTAINER"
        if [ "$incl_policy" = "blacklist" ]; then
          bk_log --diag "Evaluating exclusion policy"
          for i in ${incl_list[@]}; do
            [ "$i" = "${c:0:${#1}}" -o "$i" = "$BK_CONTAINER_ALIAS" ] && {
              bk_log "This container has been excluded via exclusion policy."
              continue
            }  
          done
        elif [ "$incl_policy" = "whitelist" ]; then
          bk_log --diag "Evaluating inclusion policy"
          incl_c=
          for i in ${incl_list[@]}; do
            [ "$i" = "${c:0:${#1}}" -o "$i" = "$BK_CONTAINER_ALIAS" ] \
              && incl_c=1
          done
          [ "$incl_c" ] || {
            bk_log "This container has been excluded via inclusion policy."
            continue
          }
        fi
        # Get strategy..
        #  .. from label
        c_strategy="$(__docker get-label "$c" 'it.evolution.bk.strategy')"
        #  .. from container
        [ "$c_strategy" ] || c_strategy="${__BK_strategies_C["$BK_CONTAINER"]}"
        #  .. from image
        [ "$c_strategy" ] || c_strategy="${__BK_strategies_I["$BK_CONTAINER_IMAGE"]}"
        # Or fallback to default strategy:
        [ "$c_strategy" ] || c_strategy="-"
        #
        local c_tag="${BK_CONTAINER_UUID:0:12} $BK_CONTAINER"
        if [ "$BK_LOCAL_INPUT" ]; then
          __cleanup() {
            bk_log "Cleaning up..."
            docker stop "$BK_CONTAINER_UUID" &>/dev/null
            rm -Rf "$BK_LOCAL_INPUT" || bk_log --warn "Cleanup failure. Disk usage might've increased."
          }
          trap "__cleanup" EXIT;
          # Restoring
          export BK_LOCAL_INPUT="$BK_LOCAL_INPUT/$BK_CONTAINER_UUID"
          # .. from duplicity
          bk_log "Downloading from the first valid duplicity target..."
          __duplicity || { bk_log --error "Download failed."; exit 1; }
          [ "$DEBUG" ] && find "$BK_LOCAL_INPUT"
          # Invoking restoration strategy
          bk_strategy "$c_strategy" || exit 2;
        else
          __cleanup() {
            bk_log "Cleaning up..."
            rm -Rf "$BK_LOCAL_OUTPUT" || bk_log --warn "Cleanup failure. Disk usage might've increased."
          }
          trap "__cleanup" EXIT;
          # Backing up
          export BK_LOCAL_OUTPUT="$BK_LOCAL_OUTPUT/$BK_CONTAINER_UUID"
          mkdir -p "$BK_LOCAL_OUTPUT"
          # Invoking backup strategy
          bk_strategy "$c_strategy" || exit 2;
          # Pushing to duplicity
          bk_log "Uploading to duplicity target(s)..."
          [ "$DEBUG" ] && find "$BK_LOCAL_OUTPUT"
          __duplicity || { bk_log --error "Upload failed"; exit 1; }
        fi
      )
      [ "$?" = 0 ] || err=1
    done
    if [ "$BK_LOCAL_INPUT" ]; then
        log "Restarting frozen containers ..."
        __docker unfreeze || { log --warn "Error(s) restarting frozen containers. A whole system reboot is advised."; err=1; }
        log "-- Restore completed (errors: ${err:-0}) --"
    else
        log "-- Backup completed (errors: ${err:-0}) --"
    fi
    sleep 2 # Permit log syncing
    [ "$err" ] && return 1 || return 0
  fi
}
#@main
readonly __BK_LOG='/var/log/bk.log'
readonly __BK_PIPE='/tmp/bk.in'
__main() {
  local op=d #b, r
  local args=()
  export BK_MODE=auto
  while [ $# -gt 0 ]; do
      case "$1" in
        "--backup")
          op=b #BK_LOCAL_OUTPUT=/tmp/bk.d
          ;;
        "--restore")
          op=r #BK_LOCAL_INPUT=/tmp/bk.d
          ;;
        "--mode")
          BK_MODE="$2"
          shift
          ;;
        "--sh")
          return 0
          ;;
        *)
          args+=("$1")
          ;;
      esac
      shift
  done
  log --info "ros-duplicity " "$@"
  log --diag "--> SHA-1: " "$(sha1sum "$0")"
  if [ "$op" != d ]; then
    # Command mode
    [ -p "$__BK_PIPE" ] || exit 10 "E: The daemon is not running."
    [ "$2" ] && BK_MODE="$2"
    local json="{}"
    tail -Fc0 -s1 "$__BK_LOG" &
    local tail_pid=$!
    json="$(echo "$json"|jq --arg val "${tail_pid}" -c '. + {pid: $val}')" # $$
    json="$(echo "$json"|jq --arg val "$op" -c '. + {op: $val}')"
    json="$(echo "$json"|jq --arg val "$BK_MODE" -c '. + {mode: $val}')"
    for a in ${args[@]}; do
      json="$(echo "$json"|jq --arg val "$a" -c '. + {args: (.args+[$val])}')"
    done
    echo "$json" >"$__BK_PIPE"
    wait "$tail_pid" &>/dev/null #tail --pid=$tail_pid -f /dev/null # -s30
    [ "$?" = 138 ] && exit 0 || exit 1
  else
    # Daemon mode
    {
      [ "$$" != 1 ] && exit 10 "E: The daemon is already running."
      trap "log --info 'Daemon is being shut down'; rm -f '$__BK_PIPE'" EXIT
      # Re/initialize comunication pipe
      rm -f "$__BK_PIPE"
      mkfifo "$__BK_PIPE"
      crontab -r
      # Init configuration
      __BK_daemon=1 __init_conf
      # Init cron in background, log to STDOUT
      crond -b -d 8 2>&1
      ### Daemoniac loop ###
      local json=
      local pid=
      while true; do
        read json <"$__BK_PIPE"
        if [ "$json" ]; then
          log --diag "<< $json" # JSON
          __bk_run "$json" && log --diag --execute /bin/kill -10 "$pid" || log --diag --execute /bin/kill -12 "$pid"
          echo "" >"$__BK_LOG" # Reset internal log buffer
        else
          sleep 5
        fi
      done
    } 2>&1|tee "$__BK_LOG" >&2;
  fi
}
# Regenerate aliases
for i in $(find /bin/ -name '*.sh'); do
  ln -fs "$i" "${i:0:$((${#i}-3))}";
done
# Initialize main
__main "$@"
