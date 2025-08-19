#!/bin/bash
# monitor_device_online.sh - 监听设备在线状态变化并统计在线设备

# 获取输出文件参数（可选）
if [ "$1" = "start" ]; then
    OUTPUT_FILE="${2:-online_devices.txt}"
else
    OUTPUT_FILE="${1:-online_devices.txt}"
fi

# 配置文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/device_monitor.pid"
LOG_FILE="$SCRIPT_DIR/device_monitor.log"
OUTPUT_DIR="$SCRIPT_DIR/device_online_output"

# Kafka 配置
BOOTSTRAP_SERVERS="10.1.1.177:19092"
TOPIC="s17_dcs_dev_online_10001"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 启动函数
start_monitor() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "设备在线监控器已经在运行中 (PID: $pid)"
            return 1
        else
            rm -f "$PID_FILE"
        fi
    fi
    
    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    
    log "启动设备在线监控器"
    log "输出目录: $OUTPUT_DIR"
    log "输出文件: $OUTPUT_FILE"
    log "监听主题: $TOPIC"
    log "Kafka服务器: $BOOTSTRAP_SERVERS"
    
    # 检查Kafka客户端是否存在
    KAFKA_CLIENT="/iotp/cicd/cloud-toolbox/cloud_kafka_client/bin/kafka-console-consumer.sh"
    if [ -z "$KAFKA_CLIENT" ]; then
        log "错误: 未找到Kafka客户端，尝试的路径："
        for path in "${POSSIBLE_PATHS[@]}"; do
            log "  - $path"
        done
        echo "错误: 未找到Kafka客户端"
        echo "请检查以下路径是否存在Kafka客户端："
        for path in "${POSSIBLE_PATHS[@]}"; do
            echo "  - $path"
        done
        return 1
    fi
    
    log "Kafka客户端路径验证通过: $KAFKA_CLIENT"
    
    # 后台启动监控进程
    nohup bash -c '
        # 安全退出函数
        cleanup() {
            echo "[$(date \"+%Y-%m-%d %H:%M:%S\")] 收到退出信号，正在停止..." >> "'"$LOG_FILE"'"
            [[ -n $KAFKA_PID ]] && kill -TERM $KAFKA_PID 2>/dev/null
            rm -f "'"$PID_FILE"'"
            exit 0
        }
        
        trap cleanup SIGINT SIGTERM
        
        # 启动Kafka消费者并处理数据
        {
            "'"$KAFKA_CLIENT"'" \
                --bootstrap-server "'"$BOOTSTRAP_SERVERS"'" \
                --topic "'"$TOPIC"'" \
                --from-beginning 2>&1 &
            
            KAFKA_PID=$!
            echo $! > "'"$PID_FILE"'"
            echo "[$(date "+%Y-%m-%d %H:%M:%S")] Kafka消费者已启动 (PID: $!)" >> "'"$LOG_FILE"'"
            wait $KAFKA_PID
        } | awk -v output_dir="'"$OUTPUT_DIR"'" \
               -v output_file="'"$OUTPUT_FILE"'" \
               -v log_file="'"$LOG_FILE"'" '\''
          BEGIN {
            processed_count = 0
            online_count = 0
            offline_count = 0
            
            # 用于去重的关联数组
            delete online_devices
            
            # 输出文件路径
            online_devices_file = output_dir "/" output_file
            
            # 创建输出文件并写入表头
            print "# 在线设备列表 (devSn) - 自动生成于 " strftime("%Y-%m-%d %H:%M:%S") > online_devices_file
            print "# 格式: devSn" >> online_devices_file
            
            printf "[%s] 开始监控设备在线状态变化\n", strftime("%Y-%m-%d %H:%M:%S") >> log_file
          }
          
          {
            processed_count++
            
            # 每1000条消息记录一次日志
            if (processed_count % 1000 == 0) {
              printf "[%s] 已处理 %d 条消息，在线: %d 条，离线: %d 条，去重在线设备: %d 个\n", 
                     strftime("%Y-%m-%d %H:%M:%S"), processed_count, online_count, offline_count, length(online_devices) >> log_file
              fflush(log_file)
            }
            
            # 提取字段
            devSn = ""
            onlineStatus = ""
            changeTime = 0
            devId = ""
            plateNum = ""
            
            # 使用正则匹配提取字段
            if (match($0, /"devSn":\s*"([^"]*)"/, arr)) devSn = arr[1]
            if (match($0, /"onlineStatus":\s*"([^"]*)"/, arr)) onlineStatus = arr[1]
            if (match($0, /"changeTime":\s*([0-9]+)/, arr)) changeTime = arr[1] + 0
            if (match($0, /"devId":\s*"([^"]*)"/, arr)) devId = arr[1]
            if (match($0, /"plateNum":\s*"([^"]*)"/, arr)) plateNum = arr[1]
            
            # 只处理有效的消息（必须有devSn和onlineStatus）
            if (devSn != "" && onlineStatus != "") {
              if (onlineStatus == "ONLINE") {
                online_count++
                # 添加到在线设备集合（自动去重）
                if (!(devSn in online_devices)) {
                  online_devices[devSn] = 1
                  
                  # 实时更新输出文件
                  print devSn >> online_devices_file
                  fflush(online_devices_file)
                  
                  printf "[%s] 新增在线设备: %s (车牌: %s)\n", 
                         strftime("%Y-%m-%d %H:%M:%S"), devSn, plateNum >> log_file
                }
              } else if (onlineStatus == "OFFLINE") {
                offline_count++
                printf "[%s] 设备离线: %s (车牌: %s)\n", 
                       strftime("%Y-%m-%d %H:%M:%S"), devSn, plateNum >> log_file
              }
            }
          }
          
          END {
            printf "[%s] 监控结束 - 总处理: %d 条，在线: %d 条，离线: %d 条，去重在线设备: %d 个\n", 
                   strftime("%Y-%m-%d %H:%M:%S"), processed_count, online_count, offline_count, length(online_devices) >> log_file
            
            # 最终统计写入文件末尾
            print "" >> online_devices_file
            print "# 统计信息:" >> online_devices_file
            print "# 总处理消息数: " processed_count >> online_devices_file
            print "# 在线消息数: " online_count >> online_devices_file
            print "# 离线消息数: " offline_count >> online_devices_file
            print "# 去重在线设备数: " length(online_devices) >> online_devices_file
            print "# 统计时间: " strftime("%Y-%m-%d %H:%M:%S") >> online_devices_file
          }
        '\''
    ' >> "$LOG_FILE" 2>&1 &
    
    # 等待PID文件创建
    echo "正在启动监控进程，请稍候..."
    sleep 3
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        # 检查进程是否真的在运行
        if kill -0 "$pid" 2>/dev/null; then
            echo "✓ 设备在线监控器已启动 (PID: $pid)"
            echo "✓ 日志文件: $LOG_FILE"
            echo "✓ 输出目录: $OUTPUT_DIR"
            echo "✓ 输出文件: $OUTPUT_DIR/$OUTPUT_FILE"
            echo ""
            echo "功能说明:"
            echo "  - 监听主题: $TOPIC"
            echo "  - 统计所有 onlineStatus=ONLINE 的设备"
            echo "  - 自动去重设备序列号 (devSn)"
            echo "  - 实时写入到输出文件"
            echo ""
            echo "输出格式:"
            echo "  每行一个设备序列号 (devSn)"
            echo "  文件末尾包含统计信息"
            echo ""
            echo "监控状态检查:"
            echo "  使用 '$0 status' 查看运行状态"
            echo "  使用 '$0 show' 查看在线设备列表"
            echo "  日志文件: tail -f $LOG_FILE"
        else
            echo "✗ 启动失败: 进程未正常运行"
            echo "✗ 请检查日志文件: $LOG_FILE"
            if [ -f "$LOG_FILE" ]; then
                echo ""
                echo "最近的错误日志:"
                tail -10 "$LOG_FILE"
            fi
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo "✗ 启动失败: PID文件未创建"
        echo "✗ 请检查日志文件: $LOG_FILE"
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "最近的错误日志:"
            tail -10 "$LOG_FILE"
        fi
        return 1
    fi
}

# 停止函数
stop_monitor() {
    if [ ! -f "$PID_FILE" ]; then
        echo "设备在线监控器未运行"
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "进程已不存在，清理PID文件"
        rm -f "$PID_FILE"
        return 1
    fi
    
    log "停止设备在线监控器 (PID: $pid)"
    
    # 发送TERM信号
    kill -TERM "$pid" 2>/dev/null
    
    # 等待进程退出
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done
    
    # 如果进程仍在运行，强制杀死
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null
        log "强制停止进程 (PID: $pid)"
    fi
    
    rm -f "$PID_FILE"
    echo "设备在线监控器已停止"
}

# 状态函数
status_monitor() {
    if [ ! -f "$PID_FILE" ]; then
        echo "状态: 未运行"
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
        echo "状态: 运行中 (PID: $pid)"
        echo "日志文件: $LOG_FILE"
        echo "输出目录: $OUTPUT_DIR"
        
        # 显示最近的日志
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "最近日志:"
            tail -5 "$LOG_FILE"
        fi
        
        # 显示输出文件统计
        if [ -d "$OUTPUT_DIR" ]; then
            echo ""
            echo "输出文件统计:"
            for file in "$OUTPUT_DIR"/*.txt; do
                if [ -f "$file" ]; then
                    local filename=$(basename "$file")
                    local count=$(grep -v "^#" "$file" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
                    echo "  $filename: $count 个在线设备"
                fi
            done
        fi
    else
        echo "状态: 进程已停止，清理PID文件"
        rm -f "$PID_FILE"
        return 1
    fi
}

# 查看在线设备列表函数
show_devices() {
    local output_file="${2:-online_devices.txt}"
    local full_path="$OUTPUT_DIR/$output_file"
    
    if [ ! -f "$full_path" ]; then
        echo "输出文件不存在: $full_path"
        echo "请先启动监控器或检查文件路径"
        return 1
    fi
    
    echo "在线设备列表 ($full_path):"
    echo "================================"
    
    # 显示设备列表（排除注释行和空行）
    local device_count=0
    while IFS= read -r line; do
        if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]]; then
            device_count=$((device_count + 1))
            echo "$device_count. $line"
        fi
    done < "$full_path"
    
    echo "================================"
    echo "总计: $device_count 个在线设备"
    
    # 显示统计信息
    echo ""
    echo "统计信息:"
    grep "^# " "$full_path" | tail -6
}

# 主函数
case "$1" in
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    status)
        status_monitor
        ;;
    show)
        show_devices "$@"
        ;;
    *)
        echo "用法: $0 {start|stop|status|show} [输出文件名]"
        echo "  start [文件名] - 启动设备在线监控器，可选指定输出文件名"
        echo "  stop           - 停止设备在线监控器"
        echo "  status         - 查看运行状态"
        echo "  show [文件名]  - 显示在线设备列表"
        echo ""
        echo "示例:"
        echo "  $0 start                    # 启动监控器，输出到 online_devices.txt"
        echo "  $0 start my_devices.txt     # 启动监控器，输出到 my_devices.txt"
        echo "  $0 show                     # 显示 online_devices.txt 中的设备列表"
        echo "  $0 show my_devices.txt      # 显示 my_devices.txt 中的设备列表"
        echo ""
        echo "功能说明:"
        echo "  - 监听 s17_dcs_dev_online_10001 主题"
        echo "  - 统计所有 onlineStatus=ONLINE 的设备"
        echo "  - 自动去重设备序列号 (devSn)"
        echo "  - 实时写入到输出文件"
        echo "  - 从头开始消费所有历史消息"
        exit 1
        ;;
esac
