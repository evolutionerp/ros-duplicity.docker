#!/bin/false
# bash-utils.lib.sh
# Copyright (C) 2017  evolution.it
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License
# along with this program. If not, see <http://www.gnu.org/licenses/>.

#@func Report log message
log() {
  #echo "$*" >&2
  local ts="$(date -u +'%Y-%m-%d %H:%M:%S %Z')"
  local msg_g=
  local tag=
  local exec=
  local debug=
  while [ "${1:0:1}" = "-" ]; do
    case "$1" in
      "-d"|"--debug")
        debug=1;
        ;;
      "-D"|"--diag")
        msg_g="D:"
        ;;
      "-I"|"--info")
        msg_g="I:"
        ;;
      "-W"|"--warn")
        msg_g="W:"
        ;;
      "-E"|"--error"|"--fail")
        msg_g="E:"
        ;;
      "--execute")
        exec=1
        ;;
      "--tag")
        tag="$2"
        shift
        ;;
      "--"|"--msg"|"--message")
        shift
        break
        ;;
      *)
        break;
        ;;
    esac
    shift
  done
  local IFS=$' \n'
  {
    local msg_raw="$*"
    local msg="$msg_raw"
    [ "$msg_g" ] || { msg_g="${msg_raw:0:2}"; msg="${msg_raw:2}"; }
    [ "${msg:0:1}" = " " ] && msg="${msg:1}"
    case "$msg_g" in
      "W:"|"w:")
        printf '\033[1;37m[ \033[1;33mWARN \033[1;37m] \033[0;33m%s' "$ts"
        [ "$tag" ] && printf '\033[0;97m @\033[0;93m%s' "$tag";
        ;;
      "E:"|"e:")
        printf '\033[1;37m[ \033[1;31mFAIL \033[1;37m] \033[0;31m%s' "$ts"
        [ "$tag" ] && printf '\033[0;97m @\033[0;91m%s' "$tag";
        ;;
      "D:"|"d:")
        debug=1;
        if [ "$DEBUG" ]; then
          printf '\033[1;37m[ \033[1;35mDIAG \033[1;37m] \033[0;35m%s' "$ts"
          [ "$tag" ] && printf '\033[0;97m @\033[0;95m%s' "$tag";
        fi
        ;;
      *)
        [ "$msg_g" = "I:" -o "$msg_g" = "i:" ] || msg="$msg_raw"
        printf '\033[1;37m[ \033[1;32mINFO \033[1;37m] \033[0;32m%s' "$ts"
        [ "$tag" ] && printf '\033[0;97m @\033[0;92m%s' "$tag";
        ;;
    esac
    # Print message
    [ -z "$debug" -o "$DEBUG" ] && printf '\033[0;97m: %s\033[0m\n' "$msg"
  } >&2
  if [ "$exec" ]; then
    # Execute
    "$@"
    local ec="$?"
    log --diag " -> $ec"
    return "$ec"
  else
    return 0
  fi
}
#@func Print values as different lines
each() {
  local cc= i=
  while [ $# -gt 0 ]; do
    case "$1" in
      "-c"|"--count"|"--max")
        cc="$2"
        shift
        ;;
      "--")
        shift
        break
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  [ "$cc" ] || cc=$#
  # One argument per line, until $cc is reached
  for ((i=1; i<cc; i++)) do
    [ "$i" -gt "$cc" ] 2>/dev/null && break
    echo "$1"
    shift
  done
  # Remaining arguments in single line
  local cterm= # If 1, print '\n' at the end.
  while [ "$#" -gt 0 ]; do
    cterm=1
    printf "%s" "$1"
    shift
  done
  [ -z "$cterm" ] || printf '\n'
}
#@func Split input string(s)
explode() {
  local IFS;
  local cc=$#;
  while [ $# -gt 0 ]; do
    case "$1" in
      "-F"|"--token")
        IFS="$2"
        shift
        ;;
      "-c"|"--count"|"--max")
        cc="$2"
        shift
        ;;
      "--")
        shift
        break
        ;;
      *)
        break
        ;;
    esac
    shift
  done
  each -c "$cc" $*;
}
#@override builtin
#@func Exit with log support
exit() {
  local ec="$1"; shift
  [ $# -gt 0 ] && log "$@"
  builtin exit "$ec";
}
