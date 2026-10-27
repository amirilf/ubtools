#!/usr/bin/env bash
# ett — terminal time in the prompt. sourced, not executed.
#
#   [10/27 14:30:51] amir@ilf:~$ grep "find" .
#   [10/27 14:32:36] 12 amir@ilf:~$
#
# the stamp is when this prompt appeared, the number is how long the last
# command took. no number = no command ran before it.
#
# per prompt cost: a few bash builtins, no forks, no files.
# settings live in ett/.config, read once when the shell starts.

_ETT_CONF="${BASH_SOURCE[0]%/*}/.config"

# defaults, overridden by .config
ETT_ON=1        # 1 | 0
ETT_DATE=1      # 1 | 0   10/27
ETT_CLOCK=1     # 1 | 0   14:32:36
ETT_DUR=short   # short (12, 1:12, 1:21:23) | s (12s, 1m12s, 1h21m23s) | full (00:00:12) | off
[[ -r $_ETT_CONF ]] && . "$_ETT_CONF"

# PS0 is expanded right before a command runs. this prints nothing and saves
# the start time (microseconds) into __ett_t0 as a side effect of the arithmetic.
_ETT_PS0='${PS1:0:$((__ett_t0=${EPOCHREALTIME/[.,]/}, 0))}'

__ett_prompt() {
    local now=${EPOCHREALTIME/[.,]/} d h m s
    __ett_ps=
    [[ -n $_ETT_FMT ]] && printf -v __ett_ps "$_ETT_FMT" $(( now / 1000000 ))
    [[ -n $__ett_t0 ]] || return
    d=$(( (now - __ett_t0) / 1000000 ))
    __ett_t0=
    h=$(( d / 3600 )) m=$(( d % 3600 / 60 )) s=$(( d % 60 ))
    case $ETT_DUR in
        short) if   (( h )); then printf -v d '%d:%02d:%02d' $h $m $s
               elif (( m )); then printf -v d '%d:%02d' $m $s
               fi ;;
        s)     if   (( h )); then d="${h}h${m}m${s}s"
               elif (( m )); then d="${m}m${s}s"
               else d="${s}s"
               fi ;;
        full)  printf -v d '%02d:%02d:%02d' $h $m $s ;;
    esac
    __ett_ps+="$d "
}

_ett_on() {
    [[ -n $__ett_active ]] && return
    local f=
    (( ETT_DATE ))  && f='%m/%d'
    (( ETT_CLOCK )) && f+="${f:+ }%H:%M:%S"
    _ETT_FMT=${f:+[%($f)T] }
    __ett_ps1_orig=$PS1
    __ett_ps0_orig=$PS0
    PS1='\[\e[2m\]${__ett_ps}\[\e[0m\]'"$PS1"
    [[ $ETT_DUR != off ]] && PS0="$PS0$_ETT_PS0"
    PROMPT_COMMAND="__ett_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    __ett_t0=
    __ett_active=1
}

_ett_off() {
    [[ -n $__ett_active ]] || return
    PS1=$__ett_ps1_orig
    PS0=$__ett_ps0_orig
    PROMPT_COMMAND=${PROMPT_COMMAND#__ett_prompt}
    PROMPT_COMMAND=${PROMPT_COMMAND#; }
    unset __ett_active __ett_ps __ett_t0
}

# save settings and re-apply them to this shell
_ett_apply() {
    printf 'ETT_ON=%s\nETT_DATE=%s\nETT_CLOCK=%s\nETT_DUR=%s\n' \
        "$ETT_ON" "$ETT_DATE" "$ETT_CLOCK" "$ETT_DUR" > "$_ETT_CONF"
    _ett_off
    (( ETT_ON )) && _ett_on
}

_ett_bool() {
    case "$1" in
        on)  printf -v "$2" 1 ;;
        off) printf -v "$2" 0 ;;
        *)   echo "ett: expected on or off" >&2; return 1 ;;
    esac
}

ett() {
    case "${1:-}" in
        on)     ETT_ON=1; _ett_apply ;;
        off)    ETT_ON=0; _ett_apply ;;
        date)   _ett_bool "$2" ETT_DATE  && _ett_apply ;;
        clock)  _ett_bool "$2" ETT_CLOCK && _ett_apply ;;
        dur)
            case "$2" in
                short|s|full|off) ETT_DUR=$2; _ett_apply ;;
                *) echo "ett: dur is short (12) | s (12s) | full (00:00:12) | off" >&2; return 1 ;;
            esac ;;
        status)
            local b=(off on)
            echo "ett:   ${b[ETT_ON]}"
            echo "date:  ${b[ETT_DATE]}"
            echo "clock: ${b[ETT_CLOCK]}"
            echo "dur:   $ETT_DUR" ;;
        *)
            cat >&2 <<'EOF'
usage:
  ett on | off
  ett date  on | off           10/27
  ett clock on | off           14:32:36
  ett dur   short | s | full | off
                               12, 1:12  |  12s, 1m12s  |  00:00:12  |  hidden
  ett status
settings are saved and used by new terminals too
EOF
            return 1 ;;
    esac
}

[[ $- == *i* ]] && (( ETT_ON )) && _ett_on
