#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
monitor_device_online.py - 监听设备在线状态变化并统计在线设备
支持后台守护进程运行
"""

import os
import sys
import json
import time
import signal
import logging
import argparse
import subprocess
import threading
from datetime import datetime
from pathlib import Path
from typing import Dict, Set, List, Tuple
import re


class DeviceMonitor:
    """设备在线监控器"""
    
    def __init__(self):
        # 配置文件路径
        self.script_dir = Path(__file__).parent.absolute()
        self.pid_file = self.script_dir / "device_monitor.pid"
        self.log_file = self.script_dir / "device_monitor.log"
        self.output_dir = self.script_dir / "device_online_output"
        
        # Kafka配置
        self.bootstrap_servers = "10.1.1.177:19092"
        self.kafka_client = "/iotp/cicd/cloud-toolbox/cloud_kafka_client/bin/kafka-console-consumer.sh"
        
        # 支持多个主题，格式：主题名:应用ID
        self.topics = [
            ("s17_dcs_dev_online_10001", "10001"),
            ("s17_dcs_dev_online_10002", "10002")
        ]
        
        # 统计数据
        self.online_devices: Dict[str, Set[str]] = {}  # app_id -> set of device_sn
        self.online_count: Dict[str, int] = {}
        self.offline_count: Dict[str, int] = {}
        self.processed_count = 0
        self.business_msg_count = 0
        
        # 控制标志
        self.running = False
        self.kafka_processes = []
        
        # 初始化统计数据
        self.init_stats()
    
    def setup_logging(self):
        """设置日志配置"""
        # 清除现有的handlers
        for handler in logging.root.handlers[:]:
            logging.root.removeHandler(handler)
        
        logging.basicConfig(
            level=logging.INFO,
            format='[%(asctime)s] %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S',
            handlers=[
                logging.FileHandler(self.log_file, encoding='utf-8')
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def init_stats(self):
        """初始化统计数据"""
        for topic_name, app_id in self.topics:
            self.online_devices[app_id] = set()
            self.online_count[app_id] = 0
            self.offline_count[app_id] = 0
    
    def create_output_files(self):
        """创建输出文件"""
        self.output_dir.mkdir(exist_ok=True)
        
        for topic_name, app_id in self.topics:
            output_file = self.output_dir / f"online_devices_{app_id}.txt"
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(f"# 应用 {app_id} 在线设备列表 (devSn) - 自动生成于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write("# 格式: devSn\n")
    
    def is_running(self) -> bool:
        """检查监控器是否正在运行"""
        if not self.pid_file.exists():
            return False
        
        try:
            with open(self.pid_file, 'r') as f:
                pid = int(f.read().strip())
            
            # 检查进程是否存在
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            # 进程不存在或PID文件损坏
            self.pid_file.unlink(missing_ok=True)
            return False
    
    def save_pid(self):
        """保存进程PID"""
        with open(self.pid_file, 'w') as f:
            f.write(str(os.getpid()))
    
    def remove_pid(self):
        """删除PID文件"""
        self.pid_file.unlink(missing_ok=True)
    
    def daemonize(self):
        """将进程转为守护进程"""
        try:
            # 第一次fork
            pid = os.fork()
            if pid > 0:
                # 父进程退出
                sys.exit(0)
        except OSError as e:
            print(f"第一次fork失败: {e}")
            sys.exit(1)
        
        # 脱离父进程环境
        os.chdir("/")
        os.setsid()
        os.umask(0)
        
        try:
            # 第二次fork
            pid = os.fork()
            if pid > 0:
                # 父进程退出
                sys.exit(0)
        except OSError as e:
            print(f"第二次fork失败: {e}")
            sys.exit(1)
        
        # 重定向标准输入输出
        sys.stdout.flush()
        sys.stderr.flush()
        
        # 重定向到/dev/null
        with open('/dev/null', 'r') as f:
            os.dup2(f.fileno(), sys.stdin.fileno())
        with open('/dev/null', 'w') as f:
            os.dup2(f.fileno(), sys.stdout.fileno())
            os.dup2(f.fileno(), sys.stderr.fileno())
    
    def signal_handler(self, signum, frame):
        """信号处理器"""
        if hasattr(self, 'logger'):
            self.logger.info(f"收到退出信号 {signum}，正在停止...")
        self.stop_monitoring()
    
    def extract_fields(self, message: str) -> Dict[str, str]:
        """从JSON消息中提取字段"""
        fields = {}
        
        # 使用正则表达式提取字段
        patterns = {
            'devSn': r'"devSn":\s*"([^"]*)"',
            'onlineStatus': r'"onlineStatus":\s*"([^"]*)"',
            'changeTime': r'"changeTime":\s*([0-9]+)',
            'devId': r'"devId":\s*"([^"]*)"',
            'plateNum': r'"plateNum":\s*"([^"]*)"',
            'appId': r'"appId":\s*"([^"]*)"'
        }
        
        for field, pattern in patterns.items():
            match = re.search(pattern, message)
            if match:
                fields[field] = match.group(1)
        
        return fields
    
    def determine_app_id(self, fields: Dict[str, str]) -> str:
        """确定应用ID"""
        # 方法1: 从消息中直接提取appId字段
        if 'appId' in fields:
            return fields['appId']
        
        # 方法2: 根据设备ID或序列号的特征来推断应用ID
        dev_id = fields.get('devId', '')
        dev_sn = fields.get('devSn', '')
        
        if dev_id or dev_sn:
            if '10001' in dev_id or '10001' in dev_sn:
                return '10001'
            elif '10002' in dev_id or '10002' in dev_sn:
                return '10002'
        
        # 方法3: 默认分配到10001
        return '10001'
    
    def is_system_message(self, message: str) -> bool:
        """判断是否为系统消息"""
        system_patterns = [
            r'^Processed a total of',
            r'^WARNING',
            r'^INFO',
            r'^ERROR',
            r'^\['
        ]
        
        for pattern in system_patterns:
            if re.match(pattern, message):
                return True
        
        # 检查是否包含JSON格式
        return not ('{' in message and '}' in message)
    
    def process_message(self, message: str, topic_app_id: str = None):
        """处理单条消息"""
        self.processed_count += 1
        
        # 跳过系统消息
        if self.is_system_message(message):
            if self.processed_count <= 20:
                self.logger.info(f"跳过系统消息{self.processed_count}: {message[:100]}")
            return
        
        self.business_msg_count += 1
        
        # 每100条业务消息记录一次日志
        if self.business_msg_count % 100 == 0:
            stats = []
            for app_id in self.online_count:
                stats.append(f"应用{app_id} - 在线:{self.online_count[app_id]} "
                           f"离线:{self.offline_count[app_id]} "
                           f"去重设备:{len(self.online_devices[app_id])}")
            
            self.logger.info(f"已处理 {self.business_msg_count} 条业务消息, {', '.join(stats)}")
        
        # 提取字段
        fields = self.extract_fields(message)
        dev_sn = fields.get('devSn', '')
        online_status = fields.get('onlineStatus', '')
        plate_num = fields.get('plateNum', '')
        
        if not dev_sn or not online_status:
            if self.business_msg_count <= 20:
                self.logger.info(f"跳过无效业务消息{self.business_msg_count}: {message[:100]}")
            return
        
        # 确定应用ID - 优先使用主题对应的应用ID
        if topic_app_id:
            app_id = topic_app_id
        else:
            app_id = self.determine_app_id(fields)
        
        # 调试信息（仅前10条业务消息）
        if self.business_msg_count <= 10:
            self.logger.info(f"调试 - 业务消息{self.business_msg_count}: "
                           f"devSn={dev_sn}, status={online_status}, app_id={app_id}")
        
        # 确保应用ID的统计数据已初始化
        if app_id not in self.online_count:
            self.online_devices[app_id] = set()
            self.online_count[app_id] = 0
            self.offline_count[app_id] = 0
            self.create_app_output_file(app_id)
        
        # 处理在线状态
        if online_status == "ONLINE":
            self.online_count[app_id] += 1
            
            # 添加到对应应用的在线设备集合（自动去重）
            if dev_sn not in self.online_devices[app_id]:
                self.online_devices[app_id].add(dev_sn)
                
                # 实时更新对应应用的输出文件
                self.append_to_output_file(app_id, dev_sn)
                
                self.logger.info(f"应用{app_id}新增在线设备: {dev_sn} (车牌: {plate_num})")
        
        elif online_status == "OFFLINE":
            self.offline_count[app_id] += 1
            self.logger.info(f"应用{app_id}设备离线: {dev_sn} (车牌: {plate_num})")
    
    def create_app_output_file(self, app_id: str):
        """创建应用专用输出文件"""
        output_file = self.output_dir / f"online_devices_{app_id}.txt"
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(f"# 应用 {app_id} 在线设备列表 (devSn) - 自动生成于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write("# 格式: devSn\n")
    
    def append_to_output_file(self, app_id: str, dev_sn: str):
        """追加设备到输出文件"""
        output_file = self.output_dir / f"online_devices_{app_id}.txt"
        with open(output_file, 'a', encoding='utf-8') as f:
            f.write(f"{dev_sn}\n")
    
    def write_final_stats(self):
        """写入最终统计信息"""
        for app_id in self.online_count:
            output_file = self.output_dir / f"online_devices_{app_id}.txt"
            
            self.logger.info(f"应用{app_id} - 在线: {self.online_count[app_id]} 条，"
                           f"离线: {self.offline_count[app_id]} 条，"
                           f"去重在线设备: {len(self.online_devices[app_id])} 个")
            
            # 写入统计信息到文件末尾
            with open(output_file, 'a', encoding='utf-8') as f:
                f.write("\n")
                f.write("# 统计信息:\n")
                f.write(f"# 应用ID: {app_id}\n")
                f.write(f"# 在线消息数: {self.online_count[app_id]}\n")
                f.write(f"# 离线消息数: {self.offline_count[app_id]}\n")
                f.write(f"# 去重在线设备数: {len(self.online_devices[app_id])}\n")
                f.write(f"# 统计时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    
    def start_single_kafka_consumer(self, topic_name: str, app_id: str):
        """启动单个主题的Kafka消费者"""
        while self.running:
            try:
                self.logger.info(f"启动/重启Kafka消费者 - 主题: {topic_name}, 应用ID: {app_id}")
                
                # 启动Kafka消费者进程
                cmd = [
                    self.kafka_client,
                    "--bootstrap-server", self.bootstrap_servers,
                    "--topic", topic_name,
                    "--from-beginning"
                ]
                
                process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    universal_newlines=True,
                    bufsize=1
                )
                
                self.kafka_processes.append(process)
                
                # 读取并处理消息
                for line in process.stdout:
                    if not self.running:
                        break
                    
                    line = line.strip()
                    if line:
                        self.process_message(line, app_id)
                
                # 等待进程结束
                exit_code = process.wait()
                
                if not self.running:
                    break
                
                self.logger.info(f"Kafka消费者退出 - 主题: {topic_name} (退出码: {exit_code})")
                
                # 根据退出码决定等待时间
                if exit_code == 0:
                    self.logger.info(f"主题 {topic_name} 正常退出，等待30秒后重启以监听新消息...")
                    time.sleep(30)
                else:
                    self.logger.info(f"主题 {topic_name} 异常退出，等待10秒后重启...")
                    time.sleep(10)
                    
            except Exception as e:
                self.logger.error(f"Kafka消费者异常 - 主题: {topic_name}, 错误: {e}")
                if self.running:
                    time.sleep(10)
    
    def start_kafka_consumers(self):
        """启动所有Kafka消费者"""
        # 检查Kafka客户端是否存在
        if not os.path.exists(self.kafka_client):
            self.logger.error(f"未找到Kafka客户端: {self.kafka_client}")
            return False
        
        self.logger.info(f"Kafka客户端路径验证通过: {self.kafka_client}")
        
        # 为每个主题启动独立的线程
        threads = []
        for topic_name, app_id in self.topics:
            thread = threading.Thread(
                target=self.start_single_kafka_consumer,
                args=(topic_name, app_id),
                name=f"kafka-consumer-{topic_name}"
            )
            thread.daemon = True
            thread.start()
            threads.append(thread)
            self.logger.info(f"已启动消费者线程: {topic_name} -> 应用{app_id}")
        
        # 等待所有线程结束
        try:
            for thread in threads:
                thread.join()
        except KeyboardInterrupt:
            self.logger.info("收到中断信号，正在停止所有消费者...")
            self.running = False
            for thread in threads:
                thread.join(timeout=5)
    
    def start_monitoring(self, daemon=True):
        """启动监控"""
        if self.is_running():
            print("设备在线监控器已经在运行中")
            return False
        
        if daemon:
            # 守护进程模式 - 先显示启动信息
            topic_list = ",".join([topic for topic, _ in self.topics])
            print("✓ 设备在线监控器正在后台启动")
            print(f"✓ 日志文件: {self.log_file}")
            print(f"✓ 输出目录: {self.output_dir}")
            print("")
            print("功能说明:")
            print(f"  - 监听多个主题: {topic_list}")
            print("  - 统计所有 onlineStatus=ONLINE 的设备")
            print("  - 按应用ID分别输出到不同文件")
            print("  - 自动去重设备序列号 (devSn)")
            print("  - 实时写入到输出文件")
            print("  - 智能重启机制，持续监控新消息")
            print("")
            print("输出文件:")
            for topic_name, app_id in self.topics:
                print(f"  - 应用{app_id}: {self.output_dir}/online_devices_{app_id}.txt")
            print("")
            print("监控状态检查:")
            print(f"  使用 'python3 {os.path.basename(sys.argv[0])} status' 查看运行状态")
            print(f"  使用 'python3 {os.path.basename(sys.argv[0])} show [应用ID]' 查看在线设备列表")
            print(f"  日志文件: tail -f {self.log_file}")
            
            # 转为守护进程
            self.daemonize()
        
        # 设置日志（守护进程模式下重新设置）
        self.setup_logging()
        
        # 创建输出目录和文件
        self.create_output_files()
        
        # 构建主题列表和应用ID映射
        topic_list = ",".join([topic for topic, _ in self.topics])
        app_id_map = ",".join([f"{topic}:{app_id}" for topic, app_id in self.topics])
        
        self.logger.info("启动设备在线监控器")
        self.logger.info(f"输出目录: {self.output_dir}")
        self.logger.info(f"监听主题: {topic_list}")
        self.logger.info(f"应用ID映射: {app_id_map}")
        self.logger.info(f"Kafka服务器: {self.bootstrap_servers}")
        
        # 保存PID
        self.save_pid()
        
        # 设置信号处理器
        signal.signal(signal.SIGINT, self.signal_handler)
        signal.signal(signal.SIGTERM, self.signal_handler)
        
        # 启动监控
        self.running = True
        
        try:
            self.start_kafka_consumers()
        except KeyboardInterrupt:
            self.logger.info("收到中断信号，正在停止...")
        finally:
            self.stop_monitoring()
        
        return True
    
    def stop_monitoring(self):
        """停止监控"""
        self.running = False
        
        # 终止所有Kafka进程
        for process in self.kafka_processes:
            try:
                process.terminate()
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            except Exception:
                pass
        
        self.kafka_processes.clear()
        self.remove_pid()
        
        if hasattr(self, 'logger'):
            self.logger.info("设备在线监控器已停止")
    
    def stop(self):
        """停止监控器"""
        if not self.is_running():
            print("设备在线监控器未运行")
            return False
        
        try:
            with open(self.pid_file, 'r') as f:
                pid = int(f.read().strip())
            
            print(f"正在停止设备在线监控器 (PID: {pid})...")
            
            # 发送TERM信号
            os.kill(pid, signal.SIGTERM)
            
            # 等待进程退出
            for i in range(10):
                try:
                    os.kill(pid, 0)
                    time.sleep(1)
                    if i == 4:
                        print("等待进程退出...")
                except OSError:
                    break
            else:
                # 如果进程仍在运行，强制杀死
                try:
                    print("强制终止进程...")
                    os.kill(pid, signal.SIGKILL)
                    time.sleep(1)
                except OSError:
                    pass
            
            self.remove_pid()
            print("✓ 设备在线监控器已停止")
            return True
            
        except (OSError, ValueError) as e:
            print(f"停止监控器失败: {e}")
            self.remove_pid()
            return False
    
    def status(self):
        """查看监控器状态"""
        if not self.is_running():
            print("状态: 未运行")
            return False
        
        with open(self.pid_file, 'r') as f:
            pid = int(f.read().strip())
        
        print(f"状态: 运行中 (PID: {pid})")
        print(f"日志文件: {self.log_file}")
        print(f"输出目录: {self.output_dir}")
        
        # 显示最近的日志
        if self.log_file.exists():
            print("\n最近日志:")
            try:
                with open(self.log_file, 'r', encoding='utf-8') as f:
                    lines = f.readlines()
                    for line in lines[-5:]:
                        print(line.rstrip())
            except Exception as e:
                print(f"读取日志文件失败: {e}")
        
        # 显示输出文件统计
        if self.output_dir.exists():
            print("\n输出文件统计:")
            for output_file in self.output_dir.glob("online_devices_*.txt"):
                if output_file.is_file():
                    app_id = output_file.stem.replace("online_devices_", "")
                    try:
                        with open(output_file, 'r', encoding='utf-8') as f:
                            count = sum(1 for line in f if line.strip() and not line.startswith('#'))
                        print(f"  应用{app_id} ({output_file.name}): {count} 个在线设备")
                    except Exception as e:
                        print(f"  应用{app_id} ({output_file.name}): 读取失败 - {e}")
        
        return True
    
    def show_devices(self, app_id: str = "10001"):
        """显示在线设备列表"""
        output_file = self.output_dir / f"online_devices_{app_id}.txt"
        
        if not output_file.exists():
            print(f"输出文件不存在: {output_file}")
            print("请先启动监控器或检查应用ID是否正确")
            print("可用的输出文件:")
            for file in self.output_dir.glob("online_devices_*.txt"):
                if file.is_file():
                    print(f"  {file.name}")
            return False
        
        print(f"应用{app_id} 在线设备列表 ({output_file}):")
        print("=" * 50)
        
        try:
            device_count = 0
            with open(output_file, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        device_count += 1
                        print(f"{device_count}. {line}")
            
            print("=" * 50)
            print(f"总计: {device_count} 个在线设备")
            
            # 显示统计信息
            print("\n统计信息:")
            with open(output_file, 'r', encoding='utf-8') as f:
                stats_lines = [line.rstrip() for line in f if line.startswith('# ')]
                for line in stats_lines[-6:]:
                    print(line)
            
            return True
            
        except Exception as e:
            print(f"读取文件失败: {e}")
            return False


def main():
    """主函数"""
    parser = argparse.ArgumentParser(description="设备在线监控器")
    parser.add_argument('command', choices=['start', 'stop', 'status', 'show'],
                       help='操作命令')
    parser.add_argument('app_id', nargs='?', default='10001',
                       help='应用ID (仅用于show命令)')
    
    args = parser.parse_args()
    
    monitor = DeviceMonitor()
    
    if args.command == 'start':
        if monitor.start_monitoring(daemon=True):
            # 守护进程模式下，父进程会在这里退出
            pass
        else:
            sys.exit(1)
    
    elif args.command == 'stop':
        if not monitor.stop():
            sys.exit(1)
    
    elif args.command == 'status':
        if not monitor.status():
            sys.exit(1)
    
    elif args.command == 'show':
        if not monitor.show_devices(args.app_id):
            sys.exit(1)


if __name__ == "__main__":
    main()