#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
compare_devices.py - 对比设备文件，找出离线设备
对比all_devices.txt和在线设备文件，输出离线设备列表
"""

import os
import sys
import argparse
from pathlib import Path
from typing import Set, List, Dict
from datetime import datetime


class DeviceComparator:
    """设备对比器"""
    
    def __init__(self):
        self.script_dir = Path(__file__).parent.absolute()
        self.all_devices_file = self.script_dir / "all_devices.txt"
        self.output_dir = self.script_dir / "device_online_output"
        
        # 在线设备文件列表
        self.online_files = [
            ("10001", self.output_dir / "online_devices_10001.txt"),
            ("10002", self.output_dir / "online_devices_10002.txt")
        ]
    
    def read_device_file(self, file_path: Path) -> Set[str]:
        """读取设备文件，返回设备序列号集合"""
        devices = set()
        
        if not file_path.exists():
            print(f"警告: 文件不存在 - {file_path}")
            return devices
        
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    # 跳过空行和注释行
                    if line and not line.startswith('#'):
                        devices.add(line)
            
            print(f"✓ 读取文件: {file_path.name} - {len(devices)} 个设备")
            return devices
            
        except Exception as e:
            print(f"✗ 读取文件失败: {file_path} - {e}")
            return devices
    
    def compare_devices(self) -> Dict[str, any]:
        """对比设备文件"""
        print("=" * 60)
        print("设备对比分析")
        print("=" * 60)
        
        # 读取所有设备文件
        print("\n1. 读取设备文件:")
        all_devices = self.read_device_file(self.all_devices_file)
        
        if not all_devices:
            print(f"✗ 无法读取总设备文件: {self.all_devices_file}")
            return None
        
        # 读取在线设备文件
        online_devices_by_app = {}
        all_online_devices = set()
        
        for app_id, file_path in self.online_files:
            online_devices = self.read_device_file(file_path)
            online_devices_by_app[app_id] = online_devices
            all_online_devices.update(online_devices)
        
        # 计算离线设备
        offline_devices = all_devices - all_online_devices
        
        # 统计结果
        result = {
            'all_devices': all_devices,
            'online_devices_by_app': online_devices_by_app,
            'all_online_devices': all_online_devices,
            'offline_devices': offline_devices,
            'stats': {
                'total_devices': len(all_devices),
                'total_online': len(all_online_devices),
                'total_offline': len(offline_devices),
                'online_by_app': {app_id: len(devices) for app_id, devices in online_devices_by_app.items()}
            }
        }
        
        return result
    
    def print_summary(self, result: Dict[str, any]):
        """打印统计摘要"""
        if not result:
            return
        
        stats = result['stats']
        
        print("\n2. 统计摘要:")
        print(f"   总设备数量: {stats['total_devices']}")
        print(f"   在线设备数量: {stats['total_online']}")
        print(f"   离线设备数量: {stats['total_offline']}")
        print(f"   离线率: {stats['total_offline']/stats['total_devices']*100:.1f}%")
        
        print("\n   各应用在线设备:")
        for app_id, count in stats['online_by_app'].items():
            percentage = count/stats['total_devices']*100 if stats['total_devices'] > 0 else 0
            print(f"     应用{app_id}: {count} 个 ({percentage:.1f}%)")
    
    def print_offline_devices(self, result: Dict[str, any], limit: int = None):
        """打印离线设备列表"""
        if not result:
            return
        
        offline_devices = sorted(result['offline_devices'])
        
        print(f"\n3. 离线设备列表 (共 {len(offline_devices)} 个):")
        print("-" * 50)
        
        if not offline_devices:
            print("   🎉 所有设备都在线！")
            return
        
        # 限制显示数量
        display_devices = offline_devices[:limit] if limit else offline_devices
        
        for i, device in enumerate(display_devices, 1):
            print(f"   {i:4d}. {device}")
        
        if limit and len(offline_devices) > limit:
            print(f"   ... 还有 {len(offline_devices) - limit} 个设备未显示")
            print(f"   使用 --all 参数查看完整列表")
    
    def save_offline_devices(self, result: Dict[str, any], output_file: str = None):
        """保存离线设备到文件"""
        if not result:
            return False
        
        if not output_file:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            output_file = f"offline_devices_{timestamp}.txt"
        
        output_path = self.script_dir / output_file
        offline_devices = sorted(result['offline_devices'])
        stats = result['stats']
        
        try:
            with open(output_path, 'w', encoding='utf-8') as f:
                # 写入头部信息
                f.write(f"# 离线设备列表 - 生成于 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write(f"# 总设备数量: {stats['total_devices']}\n")
                f.write(f"# 在线设备数量: {stats['total_online']}\n")
                f.write(f"# 离线设备数量: {stats['total_offline']}\n")
                f.write(f"# 离线率: {stats['total_offline']/stats['total_devices']*100:.1f}%\n")
                f.write("#\n")
                f.write("# 各应用在线设备统计:\n")
                for app_id, count in stats['online_by_app'].items():
                    percentage = count/stats['total_devices']*100 if stats['total_devices'] > 0 else 0
                    f.write(f"#   应用{app_id}: {count} 个 ({percentage:.1f}%)\n")
                f.write("#\n")
                f.write("# 离线设备序列号列表:\n")
                
                # 写入离线设备列表
                for device in offline_devices:
                    f.write(f"{device}\n")
            
            print(f"\n4. 离线设备列表已保存到: {output_path}")
            return True
            
        except Exception as e:
            print(f"✗ 保存文件失败: {e}")
            return False
    
    def check_files_exist(self) -> bool:
        """检查必要文件是否存在"""
        missing_files = []
        
        if not self.all_devices_file.exists():
            missing_files.append(str(self.all_devices_file))
        
        for app_id, file_path in self.online_files:
            if not file_path.exists():
                missing_files.append(str(file_path))
        
        if missing_files:
            print("✗ 以下文件不存在:")
            for file in missing_files:
                print(f"    {file}")
            print("\n建议:")
            print("  1. 确保 all_devices.txt 文件存在")
            print("  2. 先运行设备监控器生成在线设备文件:")
            print("     python3 monitor_device_online.py start")
            return False
        
        return True
    
    def run_comparison(self, show_all: bool = False, save_file: str = None, limit: int = 50):
        """运行设备对比"""
        # 检查文件是否存在
        if not self.check_files_exist():
            return False
        
        # 执行对比
        result = self.compare_devices()
        if not result:
            return False
        
        # 显示结果
        self.print_summary(result)
        
        # 显示离线设备
        display_limit = None if show_all else limit
        self.print_offline_devices(result, display_limit)
        
        # 保存到文件
        if save_file or result['stats']['total_offline'] > 0:
            self.save_offline_devices(result, save_file)
        
        return True


def main():
    """主函数"""
    parser = argparse.ArgumentParser(
        description="设备对比工具 - 找出离线设备",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
使用示例:
  python3 compare_devices.py                    # 基本对比，显示前50个离线设备
  python3 compare_devices.py --all              # 显示所有离线设备
  python3 compare_devices.py --limit 100        # 显示前100个离线设备
  python3 compare_devices.py --save offline.txt # 保存结果到指定文件
  python3 compare_devices.py --all --save       # 显示所有设备并保存到默认文件

文件说明:
  all_devices.txt                    - 所有设备列表
  device_online_output/online_devices_10001.txt - 应用10001在线设备
  device_online_output/online_devices_10002.txt - 应用10002在线设备
        """
    )
    
    parser.add_argument('--all', action='store_true',
                       help='显示所有离线设备（默认只显示前50个）')
    parser.add_argument('--limit', type=int, default=50,
                       help='限制显示的离线设备数量（默认50）')
    parser.add_argument('--save', nargs='?', const='',
                       help='保存离线设备到文件（可指定文件名）')
    
    args = parser.parse_args()
    
    # 创建对比器
    comparator = DeviceComparator()
    
    # 确定保存文件名
    save_file = None
    if args.save is not None:
        save_file = args.save if args.save else None
    
    # 运行对比
    success = comparator.run_comparison(
        show_all=args.all,
        save_file=save_file,
        limit=args.limit
    )
    
    if not success:
        sys.exit(1)
    
    print("\n✓ 设备对比完成")


if __name__ == "__main__":
    main()