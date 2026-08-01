#!/usr/bin/env bash

ts() { date '+%F %T'; }

log_info()  { printf "[%s] [INFO] %s\n"  "$(ts)" "$*"; }
log_warn()  { printf "[%s] [WARN] %s\n"  "$(ts)" "$*" >&2; }
log_error() { printf "[%s] [ERROR] %s\n" "$(ts)" "$*" >&2; }
log_debug() { 
    [[ "$LOG_LEVEL" != "DEBUG" ]] && return
    printf "[%s] [DEBUG] %s\n" "$(ts)" "$*"; 
    }