#!/bin/bash
# filter_kafka_data_csv.sh - 持续从 Kafka 读取数据并按日期分类输出

# 配置文件
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/kafka_filter.pid"
LOG_FILE="$SCRIPT_DIR/kafka_filter.log"
OUTPUT_DIR="$SCRIPT_DIR/kafka_data_output"

# Kafka 配置
BOOTSTRAP_SERVERS="10.160.10.26:19092,10.160.10.27:19092,10.160.10.28:19092"
TOPIC="base_evidence_state_change_10001"

# 目标状态集合
TARGET_STATES="0,2,3,6,8"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 启动函数
start_filter() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Kafka过滤器已经在运行中 (PID: $pid)"
            return 1
        else
            rm -f "$PID_FILE"
        fi
    fi
    
    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"
    
    log "启动Kafka数据过滤器"
    log "输出目录: $OUTPUT_DIR"
    log "目标状态: $TARGET_STATES"
    
    # 后台启动过滤进程
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
            /iotp/cloud-toolbox/cloud_kafka_client/bin/kafka-console-consumer.sh \
                --bootstrap-server "'"$BOOTSTRAP_SERVERS"'" \
                --topic "'"$TOPIC"'" \
                --from-beginning 2>&1 &
            
            KAFKA_PID=$!
            echo $! > "'"$PID_FILE"'"
            echo "[$(date \"+%Y-%m-%d %H:%M:%S\")] Kafka消费者已启动 (PID: $!)" >> "'"$LOG_FILE"'"
            wait $KAFKA_PID
        } | awk -v output_dir="'"$OUTPUT_DIR"'" \
               -v target_states="'"$TARGET_STATES"'" \
               -v log_file="'"$LOG_FILE"'" '\''
          BEGIN {
            # 解析目标状态
            split(target_states, states_arr, ",")
            for (i in states_arr) {
              state = states_arr[i] + 0
              target_states_set[state] = 1
            }
            
            # TSV表头
            header = "taskId\talarmId\tauthId\tdeviceId\tvehicleId\tevidenceId\tevidenceType\talarmTime\talarmType\texecutedCode\texecutedMsg\tfailCode\tfailMessage\tcreateTime\tstate"
            
            processed_count = 0
            filtered_count = 0
          }
          
          {
            processed_count++
            
            # 每10000条消息记录一次日志
            if (processed_count % 10000 == 0) {
              printf "[%s] 已处理 %d 条消息，已过滤 %d 条\n", 
                     strftime("%Y-%m-%d %H:%M:%S"), processed_count, filtered_count >> log_file
              fflush(log_file)
            }
            
            # 提取所有字段
            taskId = ""
            alarmId = ""
            authId = ""
            deviceId = ""
            vehicleId = ""
            evidenceId = ""
            evidenceType = ""
            alarmTime = 0
            alarmType = ""
            executedCode = ""
            executedMsg = ""
            failCode = ""
            failMessage = ""
            createTime = 0
            state = -1
            
            # 使用正则匹配提取字段
            if (match($0, /"s17TaskId":\s*"([^"]*)"/, arr)) taskId = arr[1]
            if (match($0, /"alarmId":\s*"([^"]*)"/, arr)) alarmId = arr[1]
            if (match($0, /"authId":\s*"([^"]*)"/, arr)) authId = arr[1]
            if (match($0, /"deviceId":\s*"([^"]*)"/, arr)) deviceId = arr[1]
            if (match($0, /"vehicleId":\s*"([^"]*)"/, arr)) vehicleId = arr[1]
            if (match($0, /"evidenceId":\s*"([^"]*)"/, arr)) evidenceId = arr[1]
            if (match($0, /"evidenceType":\s*"([^"]*)"/, arr)) evidenceType = arr[1]
            if (match($0, /"alarmTime":\s*([0-9]+)/, arr)) alarmTime = arr[1] + 0
            if (match($0, /"alarmType":\s*"([^"]*)"/, arr)) alarmType = arr[1]
            if (match($0, /"executedCode":\s*"([^"]*)"/, arr)) executedCode = arr[1]
            if (match($0, /"executedMsg":\s*"([^"]*)"/, arr)) executedMsg = arr[1]
            if (match($0, /"failCode":\s*"([^"]*)"/, arr)) failCode = arr[1]
            if (match($0, /"failMessage":\s*"([^"]*)"/, arr)) failMessage = arr[1]
            if (match($0, /"createTime":\s*([0-9]+)/, arr)) createTime = arr[1] + 0
            if (match($0, /"state":\s*([0-9]+)/, arr)) state = arr[1] + 0
            
            # 只处理有效的消息（必须有taskId和createTime）
            if (taskId != "" && createTime > 0) {
              # 状态过滤：只保留目标状态
              if (state in target_states_set) {
                # 计算UTC日期
                utc_date = strftime("%Y-%m-%d", createTime, 1)  # 1表示UTC时区
                output_file = output_dir "/" utc_date "_filtered.tsv"
                
                # 检查文件是否存在，不存在则创建并写入表头
                if (!(output_file in file_created)) {
                  print header > output_file
                  file_created[output_file] = 1
                  printf "[%s] 创建新文件: %s\n", 
                         strftime("%Y-%m-%d %H:%M:%S"), output_file >> log_file
                }
                
                # 输出数据行
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\n", 
                       taskId, alarmId, authId, deviceId, vehicleId, evidenceId, evidenceType,
                       alarmTime, alarmType, executedCode, executedMsg, failCode, failMessage,
                       createTime, state >> output_file
                
                filtered_count++
              }
            }
          }
          
          END {
            printf "[%s] 处理完成 - 总处理: %d 条，已过滤: %d 条\n", 
                   strftime("%Y-%m-%d %H:%M:%S"), processed_count, filtered_count >> log_file
          }
        '\''
    ' > /dev/null 2>&1 &
    
    # 等待PID文件创建
    sleep 2
    
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        echo "Kafka过滤器已启动 (PID: $pid)"
        echo "日志文件: $LOG_FILE"
        echo "输出目录: $OUTPUT_DIR"
    else
        echo "启动失败，请检查日志文件: $LOG_FILE"
        return 1
    fi
}

# 停止函数
stop_filter() {
    if [ ! -f "$PID_FILE" ]; then
        echo "Kafka过滤器未运行"
        return 1
    fi
    
    local pid=$(cat "$PID_FILE")
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "进程已不存在，清理PID文件"
        rm -f "$PID_FILE"
        return 1
    fi
    
    log "停止Kafka数据过滤器 (PID: $pid)"
    
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
    echo "Kafka过滤器已停止"
}

# 状态函数
status_filter() {
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
            echo "输出文件:"
            for file in "$OUTPUT_DIR"/*.tsv; do
                if [ -f "$file" ]; then
                    local filename=$(basename "$file")
                    local count=$(tail -n +2 "$file" | wc -l 2>/dev/null || echo "0")
                    echo "  $filename: $count 条记录"
                fi
            done
        fi
    else
        echo "状态: 进程已停止，清理PID文件"
        rm -f "$PID_FILE"
        return 1
    fi
}

# 主函数
case "$1" in
    start)
        start_filter
        ;;
    stop)
        stop_filter
        ;;
    status)
        status_filter
        ;;
    *)
        echo "用法: $0 {start|stop|status}"
        echo "  start  - 启动Kafka数据过滤器"
        echo "  stop   - 停止Kafka数据过滤器"
        echo "  status - 查看运行状态"
        exit 1
        ;;
esac