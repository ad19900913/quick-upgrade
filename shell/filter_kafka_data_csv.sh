#!/bin/bash
# filter_kafka_data.sh - 过滤 Kafka 数据并只保留指定状态(0,2,3,6,8)

TARGET_DATE=${1:-$(date +%Y-%m-%d)}
OUTPUT_FILE=${2:-"${TARGET_DATE//-/}_filtered.tsv"}
DEBUG_LOG=${3:-"filter_debug_${TARGET_DATE//-/}.log"}

# Kafka 配置
BOOTSTRAP_SERVERS="10.160.10.26:19092,10.160.10.27:19092,10.160.10.28:19092"
TOPIC="base_evidence_state_change_10001"

# 目标状态集合
TARGET_STATES="0,2,3,6,8"

# 时间范围计算
START_TS=$(date -d "$TARGET_DATE" +%s)
END_TS=$(($START_TS + 86400))

# 初始化日志
{
echo "====== Kafka数据过滤开始: $(date '+%Y-%m-%d %H:%M:%S') ======"
echo "目标日期: $TARGET_DATE (时间戳范围: $START_TS-$END_TS)"
echo "目标状态: $TARGET_STATES"
echo "输出文件: $OUTPUT_FILE"
} | tee "$DEBUG_LOG"

# 安全退出函数
cleanup() {
  echo "强制退出: 正在终止Kafka消费者..." | tee -a "$DEBUG_LOG"
  [[ -n $KAFKA_PID ]] && kill -TERM $KAFKA_PID 2>/dev/null
  exit 1
}

trap cleanup SIGINT SIGTERM

# 启动Kafka消费者并处理数据
{
  /iotp/cloud-toolbox/cloud_kafka_client/bin/kafka-console-consumer.sh \
    --bootstrap-server "$BOOTSTRAP_SERVERS" \
    --topic "$TOPIC" \
    --from-beginning \
    --timeout-ms 60000 \
    --max-messages 1000000 2>&1 &
  
  KAFKA_PID=$!
  wait $KAFKA_PID
} | awk -v start_ts="$START_TS" -v end_ts="$END_TS" \
       -v target_states="$TARGET_STATES" \
       -v debug_log="$DEBUG_LOG" '
  BEGIN {
    total_count = 0
    filtered_count = 0
    state_filtered_count = 0
    print "开始过滤消息..." > debug_log
    
    # 解析目标状态
    split(target_states, states_arr, ",")
    for (i in states_arr) {
      state = states_arr[i] + 0
      target_states_set[state] = 1
    }
  }
  
  {
    total_count++
    
    # 每100条消息打印进度
    if (total_count % 100 == 0) {
      printf "[原始] 已处理 %d 条消息\n", total_count > debug_log
    }
    
    # 尝试提取字段
    taskId = ""
    createTime = 0
    state = -1
    
    # 使用正则匹配提取字段
    if (match($0, /"s17TaskId":\s*"([^"]+)"/, arr)) taskId = arr[1]
    if (match($0, /"createTime":\s*([0-9]+)/, arr)) createTime = arr[1] + 0
    if (match($0, /"state":\s*([0-9]+)/, arr)) state = arr[1] + 0
    
    # 日期范围过滤
    if (createTime >= start_ts && createTime < end_ts && taskId != "") {
      # 状态过滤：只保留目标状态
      if (state in target_states_set) {
        # 输出简化格式: taskId<tab>createTime<tab>state
        printf "%s\t%d\t%d\n", taskId, createTime, state
        state_filtered_count++
      }
      
      filtered_count++
      
      # 每100条过滤消息打印进度
      if (filtered_count % 100 == 0) {
        printf "[过滤] %s: 已保存 %d 条消息 (其中 %d 条为目标状态)\n", 
               strftime("%H:%M:%S"), filtered_count, state_filtered_count > debug_log
      }
    }
  }
  
  END {
    print "====== 过滤完成 ======" > debug_log
    print "原始消息总数: " total_count > debug_log
    print "日期过滤消息数: " filtered_count > debug_log
    print "状态过滤消息数: " state_filtered_count > debug_log
  }
' > "$OUTPUT_FILE"

# 结果报告
{
echo "====== 过滤完成: $(date '+%Y-%m-%d %H:%M:%S') ======"
echo "输出文件: $OUTPUT_FILE"
echo "文件大小: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo "消息数量: $(wc -l < "$OUTPUT_FILE")"
echo "开始时间: $(date -d @$START_TS '+%Y-%m-%d %H:%M:%S')"
echo "结束时间: $(date -d @$END_TS '+%Y-%m-%d %H:%M:%S')"

if [ -s "$OUTPUT_FILE" ]; then
  echo "第一条消息:"
  head -1 "$OUTPUT_FILE" | awk -F'\t' '{printf "TaskId: %s, 时间: %s, 状态: %d\n", $1, strftime("%Y-%m-%d %H:%M:%S", $2), $3}'
  echo "最后一条消息:"
  tail -1 "$OUTPUT_FILE" | awk -F'\t' '{printf "TaskId: %s, 时间: %s, 状态: %d\n", $1, strftime("%Y-%m-%d %H:%M:%S", $2), $3}'
  
  # 状态分布统计
  echo "状态分布:"
  awk -F'\t' '
    {
      state_count[$3]++
      total++
    }
    END {
      for (state in state_count) {
        printf "状态 %d: %d 条 (%.2f%%)\n", 
               state, state_count[state], (state_count[state] * 100) / total
      }
    }
  ' "$OUTPUT_FILE"
else
  echo "警告: 没有过滤到任何消息!"
fi
} | tee -a "$DEBUG_LOG"

echo "数据过滤完成! 结果已保存到: $OUTPUT_FILE"