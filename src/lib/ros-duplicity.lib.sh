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

readonly __BK_self="$(basename "$(head '/proc/1/cgroup')")"
#@func Initialize conf environment
#@in   __BK_daemon=    Daemon configuration (only cron rules)
__init_conf() {  
  log --diag "__init_conf: begin"
  # @func Add cron rule for daemon
  # @op   daemon
  cron_add() { # <time> [<mode="backup">]
    log --diag "$FUNCNAME" "$@"
    [ $# -ge 1 -a $# -le 2 ] || { log --tag "conf" --error "$FUNCNAME: expected at least 1 and at most 2 parameters (time, [mode]), but called with '$*'"; return 1; }
    [ "$__BK_daemon" ] \
      && printf '%s\n\n' "$(crontab -l 2>/dev/null|head -n-1; echo "$1 /entryPoint.sh --cron --backup --mode $(printf "%q" "${2-auto}")")"|crontab - 2>/dev/null;
  }
  # @func Declare duplicity target
  # @param  flags:
  #         -E <var> <value>  : Environment for duplicity
  # @param  url:      Duplicity target URL
  # @param  options:  Options for duplicity
  duplicity_target() { # [[<flags>|--]] <url> [[<<options>]]
    log --diag "$FUNCNAME" "$@"
    [ $# -ge 1 ] || { log --tag "conf" --error "$FUNCNAME: expected 1+ parameters, but called with '$*'"; return 1; }
    if ! [ "$__BK_daemon" ]; then
      local row=
      local erow=
      while [ $# -gt 0 ]; do
          case "$1" in
            "-E")
              [ "$erow" ] && erow="$(printf '%s\n%s=%q' "$erow" "$2" "$3")" || erow="$(printf '%s=%q' "$2" "$3")";
              shift 2
              ;;
            "--")
              shift; break;
              ;;
            *)
              break;
              ;;
          esac
          shift
      done
      while [ $# -gt 0 ]; do
        [ "$row" ] && row="$(printf '%s\n%s' "$row" "$1")" || row="$1"
        shift
      done
      __BK_duplicity_envs+=("$erow") #("$(echo "$erow"|tail -n -1)")
      __BK_duplicity_targets+=("$row") #("$(echo "$row"|tail -n -1)")
    fi
  }
  # @func Import and trust PGP key
  gpg_key() {
    log --diag "$FUNCNAME" "$@"
    # Import all keys...
    gpg --batch --quiet --armor --import \
      || log --warn "$FUNCNAME: error importing key!"
    # Trust all imported keys
    for i in $(gpg --list-keys --fingerprint --batch|tr -d ' '|egrep -o '[0-9a-fA-F]{40}\b'); do
      log --diag "+ gpg.trust: $i"
      echo "${i}:6:"|gpg --import-ownertrust
    done
  }
  # @func Define a backup/restore strategy, whose code is in the passed function.
  strategy_add() { # <name> <func>
    log --diag "$FUNCNAME" "$@"
    [ "$#" = 2 ] || { log --tag "conf" --error "$FUNCNAME: expected 2 parameters (name, func_name), but called with '$*'"; return 1; }
    [ "$1" = "-" -a -z "$override" ] \
      && { log --tag "conf" --error "$FUNCNAME: unable to override the default strategy"; return 1; }
    [ "$(type -t "$2")" = "function" ] \
      || { log --tag "conf" --error "$FUNCNAME: cannot resolve function '$2'"; return 1; }
    [ "$__BK_daemon" ] || __BK_strategies["$1"]="$2"
  }
  # @func Map a strategy for an image.
  strategy_for_image() { # <image> <strategy>
    log --diag "$FUNCNAME" "$@"
    [ $# = 2 ] \
      || { log --tag "conf" --error "$FUNCNAME: expected 2 parameters (image, strategy), but called with '$*'"; return 1; }
    if ! [ "$__BK_daemon" ]; then
      [ "${__BK_strategies[$2]}" ] \
        || { log --tag "conf" --error "$FUNCNAME: unregistered strategy name; please invoke 'strategy_add $2' before."; return 1; }
      __BK_strategies_I["$1"]="$2" 
    fi
  }
  # @func Map a strategy for a container.
  strategy_for_container() { # <container> <strategy>
    log --diag "$FUNCNAME" "$@"
    [ $# = 2 ] \
      || { log --tag "conf" --error "$FUNCNAME: expected 2 parameters (container, strategy), but called with '$*'"; return 1; }
    if ! [ "$__BK_daemon" ]; then
      [ "${__BK_strategies[$2]}" ] \
        || { log --tag "conf" --error "$FUNCNAME: unregistered strategy name; please invoke 'strategy_add $2' before."; return 1; }
      __BK_strategies_C["$1"]="$2" 
    fi
  }
    ## Initialization ##
  # Default strategy
  __S() {
    for v in $(bk_volumes); do
      [ "${v:0:1}" = "/" ] || v="/$v"
      if [ "$BK_LOCAL_OUTPUT" ]; then
        # Extract volume from container
        bk_log "Reading $v"
        local target="$BK_LOCAL_OUTPUT/$(dirname "${v:1}")"
        bk_log --diag "target: $target"
        mkdir -p "$target"
        bk_pull "$v" "$target/" || return 1
      elif [ "$BK_LOCAL_INPUT" ]; then
        # Force shutdown
        docker stop "$BK_CONTAINER" &>/dev/null
        local v_path="$(__docker get-external-path "$BK_CONTAINER" "$v")"
          bk_log --diag "v_path: $v_path"
        if [ "$v_path" ]; then
          # Use probe container
          local probe="bk_probe_${__BK_self}"
          local err=
          log --diag "Using probe container: $probe"
          docker run -dit --name "$probe" -v "$(dirname "$v_path"):/v" alpine
          bk_log "Erasing $v ($v_path)"
          docker exec "$probe" rm -Rf "/v/$(basename "$v_path")"
          bk_log "Writing $v"
          bk_log --diag --execute \
            docker cp "$BK_LOCAL_INPUT/${v:1}" "$probe:/v/$(basename "$v_path")" || err=1
          docker rm -f "$probe"
          [ "$err" ] && return 1
        else
          bk_log --error "Unable to mount volume in probe container: $v"
          return 2
        fi
      fi
    done
    return 0
  }
  __S_mysql() {
    local db_pswd=$(bk_env "MYSQL_ROOT_PASSWORD")
    docker start "$BK_CONTAINER" || { log --error "Cannot start container for provisioning."; return 2; }
    # Ping
    printf "Connecting " >&2
    for i in {1..5}; do
      echo "SHOW databases;"|docker exec -e MYSQL_PWD="$(bk_env 'MYSQL_ROOT_PASSWORD')" -i "$BK_CONTAINER" mysql -u root &>/dev/null \
        && break \
        || { printf "." >&2; sleep 2; }
    done
    printf "\n" >&2
    # Strategy
    if [ "$BK_LOCAL_OUTPUT" ]; then
      bk_log --diag --execute docker exec -e MYSQL_PWD="$(bk_env 'MYSQL_ROOT_PASSWORD')" -i "$BK_CONTAINER" mysqldump -u root --all-databases \
        > "$BK_LOCAL_OUTPUT/mysql.sql"
      local ec="$?"
      [ "$DEBUG" ] && cat "$BK_LOCAL_OUTPUT/mysql.sql"|head
      return $ec
    elif [ "$BK_LOCAL_INPUT" ]; then
      sleep 5
      [ "$DEBUG" ] && cat "$BK_LOCAL_INPUT/mysql.sql"|head
      bk_log --diag --execute docker exec -e MYSQL_PWD="$(bk_env 'MYSQL_ROOT_PASSWORD')" -i "$BK_CONTAINER" mysql -u root \
        < "$BK_LOCAL_INPUT/mysql.sql"
    fi
  }
  # Default strategies
  override=1 strategy_add '-' __S
  strategy_add 'mysql' __S_mysql; strategy_for_image 'mysql' 'mysql'
  
  # Reset PGP storage
  rm -Rf "$HOME/.gnupg"
  gpg --batch --quiet --delete-keys &>/dev/null
  
  # Initialize conf file
  [ -e '/conf/ros-duplicity.conf' ] && {
    log --diag "Sourcing conf file..."
    source "/conf/ros-duplicity.conf"
  }
  
  log --diag "__init_conf: end"
}
#@in $BK_CONTAINER, $BK_CONTAINER_UUID
__init_strategies() {
  log --diag "__init_strategies: begin"
  ## Print container environment keys, or get a specific env. value
  bk_env() { # [<var>]
    bk_log --diag "$FUNCNAME" "$@"
    [ "$#" -ge 0 -a "$#" -le 1 ] || bk_log "$FUNCNAME: expected at most 1 argument ([var]), but called with '$*'"
    if [ "$BK_CONTAINER" ]; then
      declare -A env;
      for e in $(docker inspect "$BK_CONTAINER"|jq -r '.[0]|.Config.Env|values[]'); do
        local e_key="$(echo "$e"|awk -F= '{print $1}')"
        local e_val="${e:$((${#e_key}+1))}"
        env["$e_key"]="$e_val"
      done
      if [ "$1" ]; then
        echo "${env[$1]}"
      else
        echo "${!env[@]}"
      fi
    fi
  }
  ## Append a message to the log
  bk_log() { # <message>
    [ "$BK_CONTAINER" ] && log --tag "$BK_CONTAINER" "$@"
  }
  ## Get all volumes, 
  bk_volumes() {
    bk_log --diag "$FUNCNAME" "$@"
    [ "$#" = 0 ] || bk_log "$FUNCNAME: no arguments expected, but called with '$*'"
    [ "$BK_CONTAINER" ] && __docker get-volumes "$BK_CONTAINER"
  }
  ## Pull file or directory from container
  bk_pull() { # <inner_path> <destination>
    bk_log --diag "$FUNCNAME" "$@"
    [ "$#" = 2 ] || bk_log "$FUNCNAME: 2 arguments expected (inner_path, destination), but called with '$*'"
    [ "$BK_CONTAINER" ] && docker cp "$BK_CONTAINER_UUID:$1" "$2"
  }
  ## Put file or directory into container
  bk_push() { # <path> <inner_destination>
    bk_log --diag "$FUNCNAME" "$@"
    [ "$#" = 2 ] || bk_log "$FUNCNAME: 2 arguments expected (path, inner_destination), but called with '$*'"
    [ "$BK_CONTAINER" ] && docker cp "$1" "$BK_CONTAINER_UUID:$2"
  }
  ## Invoke another strategy
  bk_strategy() { # <name>
    bk_log --diag "$FUNCNAME" "$@"
    [ "$#" = 1 ] || bk_log "$FUNCNAME: 1 argument expected (strategy), but called with '$*'"
    if [ "$BK_CONTAINER" ]; then
      # Check if strategy is valid
      [ "$(type -t "${__BK_strategies[$1]}")" = "function" ] ||
      {
        bk_log --error "Strategy function '${__BK_strategies[$1]}' not declared in the current context."
        return 127
      }
      # Invoke strategy
      bk_log "I: Applying strategy '$1'"
      ( c_strategy="$1" "${__BK_strategies["$1"]}" ) || {
        local ec=$?
        bk_log --error "Strategy '$1' failed with code $ec."
        return $ec
      }
    fi
  }
  log --diag "__init_strategies: end"
}
#@func Extended docker API/façade
__docker() {
  while [ "$#" -gt 0 -a "${1:0:1}" = "-" ]; do
    case "$1" in
      "--")
        break
        ;;
      *)
        echo "E: Invalid option '$1'." >&2
        ;;
    esac
    shift
  done
  case "$1" in
    "ps") #
      docker ps -qa --no-trunc|grep -v "$__BK_self"
      ;;
    "ps-running") #
      docker ps -q --no-trunc|grep -v "$__BK_self"
      ;;
    "is-running") # <container-id>
      [ "$(docker inspect "$2"|jq -r '.[0]|.State.Status')" = 'running' ] || return $?
      ;;
    "get-external-path") # <container> <file>
      for v in $(__docker get-volumes "$2"); do
        if [ "${3:0:${#v}}" = "$v" ]; then
          local v_path="$(docker inspect "$2"|jq -r $(printf '.[0]|.Mounts|values[]|if .Destination == "%s" then .Source else empty end' "$v"))"
          echo "$v_path/${3:${#v}}"
          return 0;
        fi
      done
      return 1
      ;;
    "get-name")
      local out="$(docker inspect "$2"|jq -r '.[0]|.Name//empty')"
      echo "${out:1}";
      ;;
    "get-image") # <container>
      docker inspect "$2"|jq -r '.[0]|.Config.Image//empty'
      ;;
    "get-labels") # <container>
      docker inspect "$2"|jq -r '.[0]|.Config.Labels|keys[]'
      ;;
    "get-label") # <container> <label>
      docker inspect "$2"|jq -r '.[0]|.Config.Labels|.["'$3'"]//empty'
      ;;
    "get-volumes") # <container>
      docker inspect "$2"|jq -r '.[0]|.Mounts|values[]|.Destination' \
        | grep -vxF "$(explode --token ':' -- '/var/run/' $(__docker get-label "$2" 'it.evolution.bk.volumes.exclude'))"
      ;;
    "get-links")
      for i in $(docker inspect "$2"|jq -r '.[0]|.HostConfig.Links|values[]'); do
        echo "$(echo "${i:1}"|awk -F: '{print $1}')"
      done
      ;;
    "freeze") #
      __BK_docker_frozen=($(__docker ps-running))
      docker stop "${__BK_docker_frozen[@]}" || return $?
      ;;
    "unfreeze") # [<container>]
      local err=
      if [ "$2" ]; then
        for i in $(__docker get-links "$2"); do
          __docker unfreeze "$i" || err=1 # Recurse until no more links
        done
        docker start "$2" && true || { log --warn "Unable to unfreeze '$2'"; return 1; }
        [ "$?" = 0 -a -z "$err" ] || false
      else
        #docker start "${__BK_docker_frozen[@]}" || return $?
        for i in "${__BK_docker_frozen[@]}"; do
          __docker unfreeze "$i" || err=1
        done
        [ -z "$err" ] || return 1
        __BK_docker_frozen=()
      fi
      ;;
    *)
      echo "E: Invalid sub-command '$1'." >&2
      return 2;
      ;;
  esac
}
__duplicity() {
  [ "$BK_CONTAINER" ] || return 1
  local err=0 
  for i in $(seq 0 "$((${#__BK_duplicity_targets[@]} - 1))"); do
    local url="$(echo "${__BK_duplicity_targets[$i]}"|head -n 1)/$BK_CONTAINER_ALIAS"
    local override=( "${__BK_duplicity_overrides[@]}" --archive-dir '/data' --name "$BK_CONTAINER_ALIAS" )
    local env=( ${__BK_duplicity_overrides_env[@]} ${__BK_duplicity_envs[$i]} )
    local options=$(echo "${__BK_duplicity_targets[$i]}"|tail -n +2)
    if [ "$BK_LOCAL_OUTPUT" ]; then
      # (Backup) Push to all duplicity targets
      bk_log --diag --execute \
        env ${__BK_duplicity_envs[$i]} \
          duplicity ${override[@]} ${options[@]} "$BK_LOCAL_OUTPUT" "$url" \
      || {
        log --warn "Error uploading to '$url', cleaning up remote files...";
        bk_log --diag --execute \
          env ${__BK_duplicity_envs[$i]} \
            duplicity ${override[@]} ${options[@]} cleanup --force "$url";
        err=1;
      }
    elif [ "$BK_LOCAL_INPUT" ]; then
      err=1
      # (Restore) Pull from the first (good) duplicity target
      # NOTICE $url is already part of $__BK_duplicity_targets here!
      bk_log --diag --execute \
        env ${__BK_duplicity_envs[$i]} \
          duplicity ${override[@]} ${options[@]} "$url" "$BK_LOCAL_INPUT" \
        && return 0 || { log --warn "Error downloading from '$url', cleaning up local files..."; rm -Rf "$BK_LOCAL_INPUT"; mkdir -p "$BK_LOCAL_INPUT"; }
    fi
  done
  return $err
}
