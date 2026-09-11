#!/bin/bash
set -Eeuo pipefail

NUM_TESTS=5
LOG_FILE=/var/log/sbshell-latency.log
CONNECT_TIMEOUT=10
MAX_TIME=30
LOG_MAX_BYTES=5242880
PREDEFINED_TARGETS=(
    "www.google.com"
    "www.youtube.com"
    "www.cloudflare.com"
    "www.github.com"
    "www.baidu.com"
)
COLOR_GREEN=$'\033[0;32m'; COLOR_RED=$'\033[0;31m'; COLOR_YELLOW=$'\033[0;33m'; COLOR_BLUE=$'\033[0;34m'; COLOR_PURPLE=$'\033[0;35m'; COLOR_CYAN=$'\033[0;36m'; COLOR_BOLD=$'\033[1m'; COLOR_RESET=$'\033[0m'

install -d -o root -g root -m 0755 /var/log
if [ -e "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    echo "日志路径不是普通文件，拒绝继续。" >&2
    exit 1
fi
if [ ! -e "$LOG_FILE" ]; then
    install -o root -g root -m 0644 /dev/null "$LOG_FILE"
else
    chown root:root "$LOG_FILE"
    chmod 0644 "$LOG_FILE"
fi

# 日志无上限增长会一直吃掉 /var/log，这里在超过上限时保留表头 + 最近 1999 行数据。
rotate_log_if_needed() {
    [ -f "$LOG_FILE" ] || return 0
    [ "$(wc -c < "$LOG_FILE")" -gt "$LOG_MAX_BYTES" ] || return 0
    local tmp
    tmp=$(mktemp)
    # 先取表头，再从「第 2 行起」取最后 1999 行，避免 tail 把表头又带回来造成重复。
    { head -n1 "$LOG_FILE"; tail -n +2 "$LOG_FILE" | tail -n 1999; } > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$LOG_FILE"
    rm -f "$tmp"
}

run_test() {
    local TARGET_URL="$1" output avg_time_ms=0
    case "$TARGET_URL" in http://*|https://*) ;; *) TARGET_URL="https://$TARGET_URL";; esac
    output=$( {
        printf "============================================================\n"
        printf "  %s正在测试: %s%s%s\n" "$COLOR_BLUE" "$COLOR_BOLD" "$TARGET_URL" "$COLOR_RESET"
        printf "============================================================\n"
        local total_duration_ms=0 min_time_ms=999999 max_time_ms=0 successful_runs=0
        for i in $(seq 1 "$NUM_TESTS"); do
            local CACHE_BUST_URL CURL_FORMAT response
            CACHE_BUST_URL="${TARGET_URL}?_t=$(date +%s%N)"
            CURL_FORMAT='%{time_connect},%{time_pretransfer},%{time_total}'
            response=$(curl -fsS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -o /dev/null -w "$CURL_FORMAT" -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' "$CACHE_BUST_URL" || true)
            if [ -z "$response" ]; then
                printf "  第 %d/%d 次: %s❌ 测试失败 (无法连接或超时)%s\n" "$i" "$NUM_TESTS" "$COLOR_RED" "$COLOR_RESET"
                continue
            fi
            successful_runs=$((successful_runs + 1))
            local connect_time_s tls_time_s run_time_s connect_time_ms tls_time_ms run_time_ms
            IFS=',' read -r connect_time_s tls_time_s run_time_s <<< "$response"
            connect_time_ms=$(awk -v time="$connect_time_s" 'BEGIN { printf "%.0f", time * 1000 }')
            tls_time_ms=$(awk -v time="$tls_time_s" 'BEGIN { printf "%.0f", time * 1000 }')
            run_time_ms=$(awk -v time="$run_time_s" 'BEGIN { printf "%.0f", time * 1000 }')
            printf "  第 %d/%d 次: 总延迟 = %s%s ms%s (连接: %s ms, TLS: %s ms)\n" "$i" "$NUM_TESTS" "$COLOR_BOLD" "$run_time_ms" "$COLOR_RESET" "$connect_time_ms" "$tls_time_ms"
            printf '%s,%s,%s,%s,%s,%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$TARGET_URL" "$i" "$connect_time_s" "$tls_time_s" "$run_time_s" >> "$LOG_FILE"
            rotate_log_if_needed
            total_duration_ms=$((total_duration_ms + run_time_ms))
            [ "$run_time_ms" -lt "$min_time_ms" ] && min_time_ms=$run_time_ms
            [ "$run_time_ms" -gt "$max_time_ms" ] && max_time_ms=$run_time_ms
        done
        printf -- "------------------------------------------------------------\n"
        if [ "$successful_runs" -gt 0 ]; then
            avg_time_ms=$(awk -v total="$total_duration_ms" -v runs="$successful_runs" 'BEGIN { printf "%.2f", total / runs }')
            printf "  📊 %s统计结果 (基于 %d 次成功测试):%s\n" "$COLOR_BOLD" "$successful_runs" "$COLOR_RESET"
            printf "  - 最快 (Min): \t%s%s ms%s\n" "$COLOR_GREEN" "$min_time_ms" "$COLOR_RESET"
            printf "  - 最慢 (Max): \t%s%s ms%s\n" "$COLOR_RED" "$max_time_ms" "$COLOR_RESET"
            printf "  - 平均 (Avg): \t%s%s ms%s\n" "$COLOR_YELLOW" "$avg_time_ms" "$COLOR_RESET"
        else
            printf "  📊 %s所有测试均失败,无法生成统计数据。%s\n" "$COLOR_RED" "$COLOR_RESET"
        fi
        printf "%s\n" "$avg_time_ms"
    } | tee /dev/tty )
    echo "$output" | tail -n 1
}

run_batch_test() {
    local -a targets=("$@") results=() target_names=()
    printf "%s%s🚀 开始批量测试多个目标 🚀%s\n" "$COLOR_PURPLE" "$COLOR_BOLD" "$COLOR_RESET"
    printf -- "----------------------------------\n"
    for target in "${targets[@]}"; do
        printf "\n%s开始测试目标: %s%s\n" "$COLOR_BLUE" "$target" "$COLOR_RESET"
        sleep 1
        local result
        result=$(run_test "$target" | tail -n 1)
        if [[ "$result" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v v="$result" 'BEGIN {exit !(v > 0)}'; then
            results+=("$result"); target_names+=("$target")
        else
            printf "⚠️  忽略 %s，无效延迟值 '%s'\n" "$target" "$result"
        fi
    done
    if [ "${#results[@]}" -gt 0 ]; then show_batch_results "${target_names[@]}" "${results[@]}"; else printf "%s没有有效的测试结果可显示。%s\n" "$COLOR_RED" "$COLOR_RESET"; fi
}

show_batch_results() {
    local half=$(( $# / 2 ))
    local -a names=("${@:1:half}")
    local -a times=("${@:half+1}")
    printf "%s%s📊 批量测试结果汇总 📊%s\n" "$COLOR_PURPLE" "$COLOR_BOLD" "$COLOR_RESET"
    printf -- "----------------------------------\n"
    printf "%-20s %-15s %-10s\n" "目标域名" "平均延迟(ms)" "排名"
    printf -- "----------------------------------\n"
    declare -A time_map=()
    local i name time rank=1
    for i in "${!names[@]}"; do name="${names[$i]}"; time="${times[$i]}"; [[ "$time" =~ ^[0-9]+([.][0-9]+)?$ ]] && time_map["$name"]="$time"; done
    mapfile -t sorted < <(printf '%s\n' "${times[@]}" | sort -n)
    for time in "${sorted[@]}"; do
        for name in "${!time_map[@]}"; do
            if [ "${time_map[$name]}" = "$time" ]; then
                local color="$COLOR_RED"
                if awk -v v="$time" 'BEGIN {exit !(v < 200)}'; then color="$COLOR_GREEN"; elif awk -v v="$time" 'BEGIN {exit !(v < 500)}'; then color="$COLOR_YELLOW"; fi
                printf "%-20s ${color}%-15s${COLOR_RESET} %-10s\n" "$name" "$time" "$rank"
                unset 'time_map[$name]'; rank=$((rank + 1))
            fi
        done
    done
    printf -- "----------------------------------\n"
    printf "%s延迟越低表示连接速度越快%s\n" "$COLOR_CYAN" "$COLOR_RESET"
}

show_menu() {
    clear
    printf "%s%s🚀 外网真实延迟测试脚本 🚀%s\n" "$COLOR_PURPLE" "$COLOR_BOLD" "$COLOR_RESET"
    printf -- "----------------------------------\n"
    printf "%s请选择一个要测试的目标:%s\n" "$COLOR_CYAN" "$COLOR_RESET"
    local i
    for i in "${!PREDEFINED_TARGETS[@]}"; do printf "  %s%2d)%s %s\n" "$COLOR_YELLOW" $((i+1)) "$COLOR_RESET" "${PREDEFINED_TARGETS[$i]}"; done
    printf -- "----------------------------------\n"
    printf "  %sb)%s 测试谷歌、百度、github、youtube\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf "  %sm)%s 手动输入域名 (Manual Input)\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf "  %sq)%s 退出 (Quit)\n" "$COLOR_YELLOW" "$COLOR_RESET"
    printf -- "----------------------------------\n"
}

if [ ! -f "$LOG_FILE" ]; then
    printf '%s\n' 'Timestamp,Target,Run,Connect_Time_s,TLS_Time_s,Total_Time_s' > "$LOG_FILE"
fi

while true; do
    show_menu
    read -rp "请输入您的选择 [1-$((${#PREDEFINED_TARGETS[@]})), b, m, q]: " choice
    case "$choice" in
        [qQ]) printf "\n%s感谢使用,再见！%s\n" "$COLOR_GREEN" "$COLOR_RESET"; exit 0;;
        [bB]) run_batch_test www.google.com www.baidu.com www.github.com www.youtube.com;;
        [mM]) read -rp '请输入您想测试的域名: ' MANUAL_URL; [ -n "$MANUAL_URL" ] && run_test "$MANUAL_URL" || { printf '%s输入不能为空,请重试。%s\n' "$COLOR_RED" "$COLOR_RESET"; sleep 2; };;
        *)
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#PREDEFINED_TARGETS[@]}" ]; then run_test "${PREDEFINED_TARGETS[$((choice-1))]}"; else printf "%s无效的选择 '%s',请重试。%s\n" "$COLOR_RED" "$choice" "$COLOR_RESET"; sleep 2; fi
            ;;
    esac
    read -n 1 -s -r -p $'\n按任意键返回主菜单...'
done
