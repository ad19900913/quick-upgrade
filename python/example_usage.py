#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
example_usage.py - 设备监控和对比的使用示例
"""

import os
import time
import subprocess
from pathlib import Path


def run_command(cmd, description):
    """运行命令并显示结果"""
    print(f"\n{'='*60}")
    print(f"执行: {description}")
    print(f"命令: {cmd}")
    print('='*60)
    
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    
    if result.stdout:
        print("输出:")
        print(result.stdout)
    
    if result.stderr:
        print("错误:")
        print(result.stderr)
    
    return result.returncode == 0


def main():
    """主函数 - 演示完整的使用流程"""
    script_dir = Path(__file__).parent
    
    print("设备监控和对比工具使用示例")
    print("="*60)
    
    # 1. 检查文件状态
    print("\n1. 检查当前文件状态:")
    files_to_check = [
        "all_devices.txt",
        "device_online_output/online_devices_10001.txt",
        "device_online_output/online_devices_10002.txt"
    ]
    
    for file_name in files_to_check:
        file_path = script_dir / file_name
        if file_path.exists():
            with open(file_path, 'r') as f:
                lines = sum(1 for line in f if line.strip() and not line.startswith('#'))
            print(f"   ✓ {file_name}: {lines} 个设备")
        else:
            print(f"   ✗ {file_name}: 文件不存在")
    
    # 2. 启动设备监控器（如果未运行）
    print("\n2. 检查设备监控器状态:")
    if run_command("python3 monitor_device_online.py status", "检查监控器状态"):
        print("   监控器正在运行")
    else:
        print("   监控器未运行，正在启动...")
        if run_command("python3 monitor_device_online.py start", "启动设备监控器"):
            print("   ✓ 监控器已启动")
            print("   等待10秒让监控器收集数据...")
            time.sleep(10)
        else:
            print("   ✗ 监控器启动失败")
            return
    
    # 3. 运行设备对比
    print("\n3. 运行设备对比分析:")
    
    # 基本对比
    run_command("python3 compare_devices.py", "基本设备对比")
    
    # 显示更多离线设备
    run_command("python3 compare_devices.py --limit 100", "显示前100个离线设备")
    
    # 保存结果到文件
    run_command("python3 compare_devices.py --save", "保存离线设备到文件")
    
    # 4. 显示生成的文件
    print("\n4. 生成的文件:")
    output_files = list(script_dir.glob("offline_devices_*.txt"))
    if output_files:
        latest_file = max(output_files, key=lambda f: f.stat().st_mtime)
        print(f"   最新的离线设备文件: {latest_file.name}")
        
        # 显示文件前几行
        with open(latest_file, 'r', encoding='utf-8') as f:
            lines = f.readlines()[:10]
        
        print("   文件内容预览:")
        for line in lines:
            print(f"     {line.rstrip()}")
        
        if len(lines) == 10:
            print("     ...")
    else:
        print("   没有找到离线设备文件")
    
    print("\n" + "="*60)
    print("使用示例完成！")
    print("\n常用命令:")
    print("  python3 monitor_device_online.py start    # 启动设备监控")
    print("  python3 monitor_device_online.py status   # 查看监控状态")
    print("  python3 compare_devices.py               # 对比设备文件")
    print("  python3 compare_devices.py --all         # 显示所有离线设备")
    print("  python3 compare_devices.py --save        # 保存结果到文件")


if __name__ == "__main__":
    main()