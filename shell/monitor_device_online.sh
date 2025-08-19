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
# 支持多个主题，格式：主题名:应用ID
TOPICS=(
    "s17_dcs_dev_online_10001:10001"
    "s17_dcs_dev_online_10002:10002"
)

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
    
    # 构建主题列表和应用ID映射
    TOPIC_LIST=""
    APP_ID_MAP=""
    for topic_config in "${TOPICS[@]}"; do
        topic_name="${topic_config%%:*}"
        app_id="${topic_config##*:}"
        
        if [ -z "$TOPIC_LIST" ]; then
            TOPIC_LIST="$topic_name"
            APP_ID_MAP="$topic_name:$app_id"
        else
            TOPIC_LIST="$TOPIC_LIST,$topic_name"
            APP_ID_MAP="$APP_ID_MAP,$topic_name:$app_id"
        fi
    done
    
    log "启动设备在线监控器"
    log "输出目录: $OUTPUT_DIR"
    log "输出文件: $OUTPUT_FILE"
    log "监听主题: $TOPIC_LIST"
    log "应用ID映射: $APP_ID_MAP"
    log "Kafka服务器: $BOOTSTRAP_SERVERS"
    
    # 检查Kafka客户端是否存在
    KAFKA_CLIENT="/iotp/cicd/cloud-toolbox/cloud_kafka_client/bin/kafka-console-consumer.sh"
    if [ ! -f "$KAFKA_CLIENT" ]; then
        log "错误: 未找到Kafka客户端: $KAFKA_CLIENT"
        echo "错误: 未找到Kafka客户端: $KAFKA_CLIENT"
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
        
        # 记录启动信息
        echo "[$(date \"+%Y-%m-%d %H:%M:%S\")] 启动Kafka消费者，主题: '"$TOPIC_LIST"'" >> "'"$LOG_FILE"'"
        
        # 启动Kafka消费者并处理数据
        while true; do
            echo "[$(date \"+%Y-%m-%d %H:%M:%S\")] 启动/重启Kafka消费者" >> "'"$LOG_FILE"'"
            
            "'"$KAFKA_CLIENT"'" \
                --bootstrap-server "'"$BOOTSTRAP_SERVERS"'" \
                --topic "'"$TOPIC_LIST"'" \
                --from-beginning 2>&1 | awk -v output_dir="'"$OUTPUT_DIR"'" \
                   -v output_file="'"$OUTPUT_FILE"'" \
                   -v log_file="'"$LOG_FILE"'" \
                   -v app_id_map="'"$APP_ID_MAP"'" '\''
              BEGIN {
                processed_count = 0
                
                # 解析应用ID映射
                split(app_id_map, map_pairs, ",")
                for (i in map_pairs) {
                  split(map_pairs[i], kv, ":")
                  if (length(kv) == 2) {
                    topic_to_app[kv[1]] = kv[2]
                  }
                }
                
                # 为每个应用ID初始化统计
                for (topic in topic_to_app) {
                  app_id = topic_to_app[topic]
                  online_count[app_id] = 0
                  offline_count[app_id] = 0
                  delete online_devices[app_id]
                  
                  # 创建应用专用输出文件
                  app_output_file = output_dir "/online_devices_" app_id ".txt"
                  print "# 应用 " app_id " 在线设备列表 (devSn) - 自动生成于 " strftime("%Y-%m-%d %H:%M:%S") > app_output_file
                  print "# 格式: devSn" >> app_output_file
                  close(app_output_file)
                }
                
                printf "[%s] 开始监控多主题设备在线状态变化\n", strftime("%Y-%m-%d %H:%M:%S") >> log_file
                printf "[%s] 监听主题映射: %s\n", strftime("%Y-%m-%d %H:%M:%S"), app_id_map >> log_file
                fflush(log_file)
              }
              
              {
                processed_count++
                
                # 每1000条消息记录一次日志
                if (processed_count % 1000 == 0) {
                  log_msg = sprintf("[%s] 已处理 %d 条消息", strftime("%Y-%m-%d %H:%M:%S"), processed_count)
                  for (app_id in online_count) {
                    log_msg = log_msg sprintf(", 应用%s - 在线:%d 离线:%d 去重设备:%d", 
                                            app_id, online_count[app_id], offline_count[app_id], 
                                            length(online_devices[app_id]))
                  }
                  print log_msg >> log_file
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
                
                # 从消息中确定应用ID
                app_id = ""
                
                # 方法1: 从消息中直接提取appId字段
                if (match($0, /"appId":\s*"([^"]*)"/, arr)) {
                  app_id = arr[1]
                }
                # 方法2: 根据设备ID或序列号的特征来推断应用ID
                else if (devId != "" || devSn != "") {
                  # 根据设备ID或序列号的特征来推断应用ID
                  if (match(devId, /10001/) || match(devSn, /10001/)) {
                    app_id = "10001"
                  } else if (match(devId, /10002/) || match(devSn, /10002/)) {
                    app_id = "10002"
                  } else {
                    # 默认分配到10001
                    app_id = "10001"
                  }
                }
                # 方法3: 如果都无法确定，使用默认值
                else {
                  app_id = "10001"
                }
                
                # 调试信息：记录解析结果（仅前10条消息）
                if (processed_count <= 10) {
                  printf "[%s] 调试 - 消息%d: devSn=%s, status=%s, app_id=%s\n", 
                         strftime("%Y-%m-%d %H:%M:%S"), processed_count, devSn, onlineStatus, app_id >> log_file
                  fflush(log_file)
                }
                
                # 只处理有效的消息（必须有devSn和onlineStatus）
                if (devSn != "" && onlineStatus != "" && app_id != "") {
                  # 确保应用ID的统计数组已初始化
                  if (!(app_id in online_count)) {
                    online_count[app_id] = 0
                    offline_count[app_id] = 0
                    delete online_devices[app_id]
                    
                    # 创建应用专用输出文件
                    app_output_file = output_dir "/online_devices_" app_id ".txt"
                    print "# 应用 " app_id " 在线设备列表 (devSn) - 自动生成于 " strftime("%Y-%m-%d %H:%M:%S") > app_output_file
                    print "# 格式: devSn" >> app_output_file
                    close(app_output_file)
                  }
                  
                  if (onlineStatus == "ONLINE") {
                    online_count[app_id]++
                    
                    # 添加到对应应用的在线设备集合（自动去重）
                    if (!(devSn in online_devices[app_id])) {
                      online_devices[app_id][devSn] = 1
                      
                      # 实时更新对应应用的输出文件
                      app_output_file = output_dir "/online_devices_" app_id ".txt"
                      print devSn >> app_output_file
                      fflush(app_output_file)
                      
                      printf "[%s] 应用%s新增在线设备: %s (车牌: %s)\n", 
                             strftime("%Y-%m-%d %H:%M:%S"), app_id, devSn, plateNum >> log_file
                      fflush(log_file)
                    }
                  } else if (onlineStatus == "OFFLINE") {
                    offline_count[app_id]++
                    printf "[%s] 应用%s设备离线: %s (车牌: %s)\n", 
                           strftime("%Y-%m-%d %H:%M:%S"), app_id, devSn, plateNum >> log_file
                    fflush(log_file)
                  }
                } else {
                  # 记录无效消息用于调试（仅前20条）
                  if (processed_count <= 20) {
                    printf "[%s] 跳过无效消息%d: 原始内容前100字符: %.100s\n", 
                           strftime("%Y-%m-%d %H:%M:%S"), processed_count, $0 >> log_file
                    fflush(log_file)
                  }
                }
              }
              
              END {
                printf "[%s] Kafka消费者结束 - 总处理: %d 条消息\n", 
                       strftime("%Y-%m-%d %H:%M:%S"), processed_count >> log_file
                
                # 为每个应用写入最终统计
                for (app_id in online_count) {
                  app_output_file = output_dir "/online_devices_" app_id ".txt"
                  
                  printf "[%s] 应用%s - 在线: %d 条，离线: %d 条，去重在线设备: %d 个\n", 
                         strftime("%Y-%m-%d %H:%M:%S"), app_id, online_count[app_id], 
                         offline_count[app_id], length(online_devices[app_id]) >> log_file
                  
                  # 最终统计写入文件末尾
                  print "" >> app_output_file
                  print "# 统计信息:" >> app_output_file
                  print "# 应用ID: " app_id >> app_output_file
                  print "# 在线消息数: " online_count[app_id] >> app_output_file
                  print "# 离线消息数: " offline_count[app_id] >> app_output_file
                  print "# 去重在线设备数: " length(online_devices[app_id]) >> app_output_file
                  print "# 统计时间: " strftime("%Y-%m-%d %H:%M:%S") >> app_output_file
                  close(app_output_file)
                }
                fflush(log_file)
              }
            '\''
            
            # 如果Kafka消费者退出，等待5秒后重启
            echo "[$(date \"+%Y-%m-%d %H:%M:%S\")] Kafka消费者退出，5秒后重启..." >> "'"$LOG_FILE"'"
            sleep 5
        done &
        
        # 保存主进程PID
        echo $! > "'"$PID_FILE"'"
        echo "[$(date \"+%Y-%m-%d %H:%M:%S\")] 监控进程已启动 (PID: $!)" >> "'"$LOG_FILE"'"
        
        # 等待子进程
        wait
    ' >> "$LOG_FILE" 2>&1 &
    
    # 等待PID文件创建
    echo "正在启动监控进程，请稍候..."
    sleep 3
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        # 检查进程是否真的在运行
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "✓ 设备在线监控器已启动 (PID: $pid)"
            echo "✓ 日志文件: $LOG_FILE"
            echo "✓ 输出目录: $OUTPUT_DIR"
            echo ""
            echo "功能说明:"
            echo "  - 监听多个主题: $TOPIC_LIST"
            echo "  - 统计所有 onlineStatus=ONLINE 的设备"
            echo "  - 按应用ID分别输出到不同文件"
            echo "  - 自动去重设备序列号 (devSn)"
            echo "  - 实时写入到输出文件"
            echo "  - 自动重启机制，确保持续监控"
            echo ""
            echo "输出文件:"
            for topic_config in "${TOPICS[@]}"; do
                app_id="${topic_config##*:}"
                echo "  - 应用$app_id: $OUTPUT_DIR/online_devices_$app_id.txt"
            done
            echo ""
            echo "监控状态检查:"
            echo "  使用 '$0 status' 查看运行状态"
            echo "  使用 '$0 show [应用ID]' 查看在线设备列表"
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
    
    # 发送TERM信号给进程组
    kill -TERM -$pid 2>/dev/null
    
    # 等待进程退出
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        count=$((count + 1))
    done
    
    # 如果进程仍在运行，强制杀死
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -$pid 2>/dev/null
        log "强制停止进程组 (PID: $pid)"
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
    if ps -p "$pid" > /dev/null 2>&1; then
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
            for file in "$OUTPUT_DIR"/online_devices_*.txt; do
                if [ -f "$file" ]; then
                    local filename=$(basename "$file")
                    local app_id=$(echo "$filename" | sed 's/online_devices_\(.*\)\.txt/\1/')
                    local count=$(grep -v "^#" "$file" | grep -v "^$" | wc -l 2>/dev/null || echo "0")
                    echo "  应用$app_id ($filename): $count 个在线设备"
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
    local app_id="${2:-10001}"
    local output_file="online_devices_$app_id.txt"
    local full_path="$OUTPUT_DIR/$output_file"
    
    if [ ! -f "$full_path" ]; then
        echo "输出文件不存在: $full_path"
        echo "请先启动监控器或检查应用ID是否正确"
        echo "可用的输出文件:"
        for file in "$OUTPUT_DIR"/online_devices_*.txt; do
            if [ -f "$file" ]; then
                echo "  $(basename "$file")"
            fi
        done
        return 1
    fi
    
    echo "应用$app_id 在线设备列表 ($full_path):"
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
        echo "用法: $0 {start|stop|status|show} [应用ID]"
        echo "  start          - 启动设备在线监控器"
        echo "  stop           - 停止设备在线监控器"
        echo "  status         - 查看运行状态"
        echo "  show [应用ID]  - 显示指定应用的在线设备列表"
        echo ""
        echo "示例:"
        echo "  $0 start                    # 启动监控器"
        echo "  $0 show 10001              # 显示应用10001的设备列表"
        echo "  $0 show 10002              # 显示应用10002的设备列表"
        echo ""
        echo "功能说明:"
        echo "  - 监听多个主题: s17_dcs_dev_online_10001, s17_dcs_dev_online_10002"
        echo "  - 统计所有 onlineStatus=ONLINE 的设备"
        echo "  - 按应用ID分别输出到不同文件"
        echo "  - 自动去重设备序列号 (devSn)"
        echo "  - 实时写入到输出文件"
        echo "  - 从头开始消费所有历史消息"
        echo "  - 自动重启机制，确保持续监控"
        echo ""
        echo "输出文件:"
        echo "  - 应用10001: device_online_output/online_devices_10001.txt"
        echo "  - 应用10002: device_online_output/online_devices_10002.txt"
        exit 1
        ;;
esac