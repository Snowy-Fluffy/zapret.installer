#!/usr/bin/env python3
"""
Zapret Strategy Tester (Hybrid V2.1 - Parallel)
UI: Classic V1 style (Detailed tables)
Core: Optimized V2 + Parallel Network Checks (No more 7s hangs)
"""

import sys
import os
import time
import subprocess
import re
import json
import argparse
import shutil
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Tuple
from collections import OrderedDict

# --- Constants ---
ZAPRET_BASE = Path("/opt/zapret")
ZAPRET_CONFIG_PATH = ZAPRET_BASE / "config"
ZAPRET_HOSTLIST_PATH = ZAPRET_BASE / "ipset" / "zapret-hosts-user.txt"

# Таймауты стали жестче для скорости
TIMEOUT_PING = 1.5
TIMEOUT_CURL = 3.0 
RESTART_DELAY = 1
TEST_PAUSE = 0.5 # Пауза между стратегиями

# --- Colors ---
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    END = '\033[0m'

# --- State Management ---
class SystemState:
    """Сохраняет и восстанавливает состояние системы."""
    
    def __init__(self):
        self.original_config = None
        self.original_hostlist = None
        self.was_active = False
        self.should_restore = True

    def backup(self):
        # 1. Service State
        res = subprocess.run(["systemctl", "is-active", "zapret"], capture_output=True, text=True)
        self.was_active = (res.returncode == 0)

        # 2. Config
        if ZAPRET_CONFIG_PATH.exists():
            try: self.original_config = ZAPRET_CONFIG_PATH.read_bytes()
            except: pass

        # 3. Hostlist
        if ZAPRET_HOSTLIST_PATH.exists():
            try: self.original_hostlist = ZAPRET_HOSTLIST_PATH.read_bytes()
            except: pass

    def restore(self, log_func):
        if not self.should_restore: return
        log_func(f"\n{Colors.YELLOW}[State] Восстановление исходного состояния...{Colors.END}", to_file=False)

        if self.original_config:
            try: ZAPRET_CONFIG_PATH.write_bytes(self.original_config)
            except: pass
        if self.original_hostlist:
            try: ZAPRET_HOSTLIST_PATH.write_bytes(self.original_hostlist)
            except: pass
        elif ZAPRET_HOSTLIST_PATH.exists():
            try: os.remove(ZAPRET_HOSTLIST_PATH)
            except: pass
        
        if self.was_active:
            subprocess.run(["systemctl", "restart", "zapret"], capture_output=True)
        else:
            subprocess.run(["systemctl", "stop", "zapret"], capture_output=True)

    def commit(self):
        self.should_restore = False

# --- UI Layer ---
class ConsoleUI:
    def __init__(self, log_path: str):
        self.log_file = None
        try:
            self.log_file = open(log_path, 'w', encoding='utf-8')
            self.log_file.write('\ufeff')
        except: pass
        self.status_lock = threading.Lock()

    def close(self):
        if self.log_file: self.log_file.close()

    def log(self, message, color="", to_file=True, end="\n"):
        if self.log_file and to_file:
            self.log_file.write(message + end)
            self.log_file.flush()
        print(f"{color}{message}{Colors.END}", end=end)

    def update_status(self, strategy, phase, domain, progress):
        with self.status_lock:
            # Обрезаем длинные строки для статуса
            d_short = (domain[:28] + '..') if len(domain) > 28 else domain
            s_short = (strategy[:15] + '..') if len(strategy) > 15 else strategy
            
            status_line = f"\r\033[K{Colors.CYAN}strategy:{Colors.END} {s_short:17} | " \
                          f"{Colors.CYAN}status:{Colors.END} {phase:10} " \
                          f"{d_short:30} | " \
                          f"{Colors.CYAN}progress:{Colors.END} {progress:10}"
            sys.stderr.write(status_line)
            sys.stderr.flush()

    def clear_status(self):
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()

    def colorize_result(self, result):
        if result == "FAIL": 
            return f"{Colors.RED}{result}{Colors.END}"
        
        if "ms" in result:
            try:
                ms = float(result.replace("ms", ""))
                if ms < 50: 
                    return f"{Colors.GREEN}{result}{Colors.END}"
                elif ms < 200: 
                    return f"{Colors.YELLOW}{result}{Colors.END}"
                return f"{Colors.RED}{result}{Colors.END}"
            except: 
                return f"{Colors.WHITE}{result}{Colors.END}"
        
        # Check for status codes in format like "HTTP:301" or "TLS1.2:200"
        # Extract the status code part (everything after the colon)
        if ":" in str(result):
            # Split by colon and get the last part (status code)
            parts = str(result).split(":")
            if len(parts) > 1:
                status_code = parts[-1]
                
                # Check if it's a numeric status code
                if status_code.isdigit():
                    # Get the first digit (hundreds place)
                    first_digit = status_code[0] if len(status_code) >= 1 else ""
                    
                    # 2xx or 3xx status codes are green, others yellow
                    if first_digit in ["2", "3"]:
                        return f"{Colors.GREEN}{result}{Colors.END}"
                    else:
                        return f"{Colors.YELLOW}{result}{Colors.END}"
        
        if result == "N/A": 
            return f"{Colors.BLUE}{result}{Colors.END}"
        
        return f"{Colors.YELLOW}{result}{Colors.END}"

    def print_results_table(self, strategy_name, results, total_tested, total_available, google_ping):
        self.clear_status()
        separator = f"{Colors.CYAN}{'='*90}{Colors.END}"
        
        self.log(f"\n{separator}")
        self.log(f"{Colors.BOLD}{Colors.CYAN}РЕЗУЛЬТАТЫ СТРАТЕГИИ: {strategy_name}{Colors.END}")
        
        if google_ping < float('inf'):
            ping_color = Colors.GREEN if google_ping < 50 else Colors.YELLOW
            self.log(f"{Colors.CYAN}Базовая задержка (google.com): {ping_color}{google_ping:.1f}ms{Colors.END}")
        
        self.log(separator)
        self.log(f"{Colors.BOLD}{Colors.WHITE}{'Домен/IP':<40} {'Ping':<10} {'HTTP':<10} {'TLS1.2':<10} {'TLS1.3':<10}{Colors.END}")
        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}")
        
        display_items = list(results.items())
        if len(results) > 30:
            self._print_rows(display_items[:20])
            self.log(f"\n{Colors.YELLOW}... пропущено {len(results) - 30} результатов ...{Colors.END}", to_file=True)
            self._print_rows(display_items[-10:])
        else:
            self._print_rows(display_items)
        
        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}")
        
        percentage = (total_available / total_tested * 100) if total_tested > 0 else 0
        if percentage > 70: status_color, status_icon = Colors.GREEN, "✓"
        elif percentage > 30: status_color, status_icon = Colors.YELLOW, "⚠"
        else: status_color, status_icon = Colors.RED, "✗"
        
        stats_msg = f"{status_color}{status_icon} {Colors.BOLD}Доступно:{Colors.END} " \
                    f"{status_color}{total_available}/{total_tested}{Colors.END} " \
                    f"{Colors.BOLD}доменов/IP ({percentage:.1f}%){Colors.END}"
        self.log(stats_msg, to_file=True)
        self.log(f"{Colors.CYAN}{'='*90}{Colors.END}\n")

    def _print_rows(self, items):
        for domain, metrics in items:
            display_domain = domain[:38] + "..." if len(domain) > 38 else domain
            row = f"{Colors.WHITE}{display_domain:<40}{Colors.END} " \
                  f"{self.colorize_result(metrics[0]):<10} " \
                  f"{self.colorize_result(metrics[1]):<10} " \
                  f"{self.colorize_result(metrics[2]):<10} " \
                  f"{self.colorize_result(metrics[3]):<10}"
            self.log(row, to_file=True)

    def print_final_summary(self, stats_list, total_domains):
        self.clear_status()
        self.log(f"\n{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
        self.log(f"{Colors.BOLD}{Colors.CYAN}ИТОГИ ТЕСТИРОВАНИЯ ВСЕХ СТРАТЕГИЙ{Colors.END}", to_file=True)
        self.log(f"{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
        
        self.log(f"{Colors.BOLD}{Colors.WHITE}{'№':<3} {'Стратегия':<30} {'Доступно':>10} {'%':>8} {'Google Ping':>12} {'Рейтинг':<10}{Colors.END}", to_file=True)
        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}", to_file=True)
        
        # Take only first 10 items from stats_list
        top_ten = stats_list[:10]
        
        for idx, (strategy, available, ping) in enumerate(top_ten, 1):
            percentage = (available / total_domains * 100) if total_domains > 0 else 0
            
            if idx == 1: color, rating = Colors.GREEN, "ЛУЧШАЯ"
            elif percentage > 80: color, rating = Colors.GREEN, "ОТЛИЧНО"
            elif percentage > 60: color, rating = Colors.YELLOW, "ХОРОШО"
            elif percentage > 40: color, rating = Colors.YELLOW, "СРЕДНЕ"
            else: color, rating = Colors.RED, "ПЛОХО"
            
            ping_display = f"{ping:.1f}ms" if ping < 999 else "N/A"
            s_disp = strategy[:28] + "..." if len(strategy) > 28 else strategy
            
            row = f"{color}{idx:<3}{Colors.END} " \
                f"{color}{s_disp:<30}{Colors.END} " \
                f"{color}{available:>10}{Colors.END} " \
                f"{color}{percentage:>7.1f}%{Colors.END} " \
                f"{ping_display:>12} " \
                f"{color}{rating:<10}{Colors.END}"
            self.log(row, to_file=True)
        
        # Optional: Add a note that we're only showing top 10
        if len(stats_list) > 10:
            self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}", to_file=True)
            self.log(f"{Colors.YELLOW}Показаны только топ-10 стратегий из {len(stats_list)}{Colors.END}", to_file=True)

# --- Optimized Parallel Network Logic ---
class NetworkTester:
    @staticmethod
    def test_ping(domain):
        """Быстрый пинг"""
        try:
            # -c 1 для скорости, -W таймаут
            cmd = ["ping", "-c", "1", "-W", str(TIMEOUT_PING), domain]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_PING + 1)
            
            if res.returncode == 0:
                match = re.search(r"time=([\d\.]+)", res.stdout)
                if match:
                    ms = float(match.group(1))
                    return f"{ms:.0f}ms", True, ms
            return "FAIL", False, float('inf')
        except:
            return "FAIL", False, float('inf')

    @staticmethod
    def full_test_domain_parallel(domain):
        """
        Ключевое исправление: Параллельный запуск CURL.
        Это предотвращает зависание на 7+ секунд (сумма таймаутов).
        """
        domain = domain.strip()
        if not domain or domain.startswith('#'): 
            return domain, ["FAIL"]*4 + [0], float('inf')
        
        # 1. Ping (последовательно, так как быстро и отсекает мертвые IP)
        ping_res, ping_ok, ping_time = NetworkTester.test_ping(domain)
        
        is_ip = bool(re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', domain))
        
        # Если это IP и он не пингуется - считаем мертвым сразу
        if is_ip:
             if not ping_ok:
                 return domain, ["FAIL", "FAIL", "FAIL", "FAIL", 0], float('inf')
             return domain, [ping_res, "N/A", "N/A", "N/A", 1], ping_time

        # 2. Параллельный запуск CURL (HTTP, TLS1.2, TLS1.3)
        # Формируем команды. Используем -I (HEAD) и -m (max-time)
        t_out = TIMEOUT_CURL
        
        # --connect-timeout ограничивает именно соединение, -m общее время
        base_curl = ["curl", "-I", "-s", "-o", "/dev/null", "-w", "%{http_code}", 
                     "-m", str(t_out), "--connect-timeout", str(t_out)]
        
        cmd_http = base_curl + [f"http://{domain}"]
        cmd_t12 = base_curl + ["--tlsv1.2", f"https://{domain}"]
        cmd_t13 = base_curl + ["--tlsv1.3", f"https://{domain}"]

        # Запускаем процессы НЕ блокируясь
        try:
            p_http = subprocess.Popen(cmd_http, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            p_t12 = subprocess.Popen(cmd_t12, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            p_t13 = subprocess.Popen(cmd_t13, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            # Если система перегружена
            time.sleep(1)
            p_http = subprocess.Popen(cmd_http, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            p_t12 = subprocess.Popen(cmd_t12, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            p_t13 = subprocess.Popen(cmd_t13, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

        def get_proc_res(proc, label):
            try:
                # Ждем с таймаутом чуть больше чем у curl
                out, _ = proc.communicate(timeout=t_out + 0.5)
                if proc.returncode == 0 and out.strip().isdigit():
                    return f"{label}:{out.strip()}"
            except subprocess.TimeoutExpired:
                proc.kill()
            except Exception:
                pass
            return "FAIL"

        # Собираем результаты. Время ожидания = max(всех таймаутов), а не sum()
        res_http = get_proc_res(p_http, "HTTP")
        res_t12 = get_proc_res(p_t12, "TLS1.2")
        res_t13 = get_proc_res(p_t13, "TLS1.3")

        # Критерий доступности: хотя бы один успешный TLS или HTTP
        def is_success(r): return "FAIL" not in r and "ERR" not in r
        available = 1 if (is_success(res_t12) or is_success(res_t13) or is_success(res_http)) else 0
        
        return domain, [ping_res, res_http, res_t12, res_t13, available], ping_time

    @staticmethod
    def test_google():
        return NetworkTester.test_ping("google.com")[2]

# --- Manager ---
class ZapretManager:
    @staticmethod
    def apply_config(config_path, hostlist_path, fwtype):
        try:
            shutil.copy(config_path, ZAPRET_CONFIG_PATH)
            # Patch FWTYPE
            with open(ZAPRET_CONFIG_PATH, 'r') as f: lines = f.readlines()
            with open(ZAPRET_CONFIG_PATH, 'w') as f:
                for line in lines:
                    if line.startswith("FWTYPE="): f.write(f"FWTYPE={fwtype}\n")
                    else: f.write(line)
            
            # Hostlist injection
            ZAPRET_HOSTLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(hostlist_path, ZAPRET_HOSTLIST_PATH)

            subprocess.run(["systemctl", "restart", "zapret"], check=True, capture_output=True)
            time.sleep(RESTART_DELAY)
            return True
        except: return False

# --- Runner ---
def run_tests(configs, hostlist_path, threads, ui, state):
    try:
        with open(hostlist_path) as f: domains = [l.strip() for l in f if l.strip() and not l.startswith('#')]
    except: return None, "nftables"

    # Detect FW
    fwtype = "nftables"
    try:
        r = subprocess.run(["iptables", "--version"], capture_output=True, text=True)
        if "legacy" in r.stdout: fwtype = "iptables"
    except: pass
    
    ui.log(f"Обнаружен фаервол: {Colors.BOLD}{fwtype}{Colors.END}", Colors.WHITE, to_file=True)
    
    executor = ThreadPoolExecutor(max_workers=threads)
    stats = []
    best_score = 0
    total_domains = len(domains)
    margin = int(total_domains * 0.2) # 20% margin for smart exit

    try:
        for i, (name, path) in enumerate(configs.items(), 1):
            time.sleep(TEST_PAUSE)
            ui.log(f"\n{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
            ui.log(f"Стратегия [{i}/{len(configs)}]: {Colors.BOLD}{name}{Colors.END}", Colors.YELLOW, to_file=True)
            
            if not ZapretManager.apply_config(path, hostlist_path, fwtype):
                ui.log(f"{Colors.RED}Ошибка применения стратегии, пропускаю...{Colors.END}", to_file=True)
                continue

            ui.update_status(name, "init", "google.com", "ping...")
            google_ping = NetworkTester.test_google()
            if google_ping == float('inf'):
                ui.log(f"{Colors.RED}Google недоступен! Пропуск стратегии.{Colors.END}", to_file=True)
                stats.append((name, 0, float('inf')))
                continue

            results = OrderedDict()
            available = 0
            futures = {executor.submit(NetworkTester.full_test_domain_parallel, d): d for d in domains}
            completed = 0
            aborted = False

            for f in as_completed(futures):
                completed += 1
                try:
                    d, metrics, t = f.result()
                    results[d] = metrics
                    if metrics[4]: available += 1
                    
                    pct = int(completed / total_domains * 100)
                    ui.update_status(name, "testing", d, f"{pct}% ({completed}/{total_domains})")
                    
                    # Smart Exit Logic
                    remaining = total_domains - completed
                    max_possible = available + remaining
                    if best_score > 0 and max_possible < (best_score - margin):
                        aborted = True
                        ui.update_status(name, "ABORTED", "Low efficiency", "STOPPING")
                        for fut in futures: fut.cancel()
                        break
                except: pass
                
            if aborted:
                ui.log(f"\n{Colors.YELLOW}Стратегия прервана: эффективность слишком низкая.{Colors.END}", to_file=True)
            
            ui.print_results_table(name, results, total_domains, available, google_ping)
            stats.append((name, available, google_ping))
            if available > best_score: best_score = available

    except KeyboardInterrupt:
        ui.log(f"\n{Colors.RED}Тестирование прервано пользователем{Colors.END}", to_file=True)
    finally:
        executor.shutdown(wait=False)
        ui.clear_status()

    # Final Summary
    if stats:
        sorted_stats = sorted(stats, key=lambda x: (-x[1], x[2]))
        ui.print_final_summary(sorted_stats, total_domains)
        return sorted_stats, fwtype
    return None, fwtype

# --- Main ---
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("configs_json", help="JSON конфиг")
    parser.add_argument("hostlist", help="Файл хостлиста")
    parser.add_argument("--threads", "-t", type=int, default=500)
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("Run as root!")
        sys.exit(1)

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    ui = ConsoleUI(f"/tmp/zapret_test_{ts}.log")
    state = SystemState()

    try:
        with open(args.configs_json) as f: configs = json.load(f)
    except:
        print("JSON Error")
        sys.exit(1)

    state.backup()
    
    ui.log(f"{Colors.BOLD}{Colors.CYAN}Тестирование стратегий Zapret (Hybrid V2.1){Colors.END}", to_file=True)
    ui.log(f"Лог: /tmp/zapret_test_{ts}.log", Colors.WHITE, to_file=True)
    ui.log(f"Количество потоков: {args.threads}", Colors.WHITE, to_file=True)

    results, fwtype = run_tests(configs, args.hostlist, args.threads, ui, state)

    # Interactive Menu
    if results:
        top_10 = results[:10]
        print(f"\n{Colors.BOLD}Выберите действие:{Colors.END}")
        print(f"  {Colors.GREEN}1-{len(top_10)}{Colors.END}: Применить стратегию из списка{Colors.END}")
        print(f"  {Colors.RED}0{Colors.END}: Выйти и восстановить как было")
        
        try:
            choice = input(f"\nВаш выбор [{Colors.GREEN}1{Colors.END}]: ").strip()
            if not choice: choice = "1"
            idx = int(choice)
            
            if 1 <= idx <= len(top_10):
                selected_name = top_10[idx-1][0]
                ui.log(f"\n{Colors.YELLOW}Применяю стратегию: {selected_name}...{Colors.END}", to_file=True)
                state.commit() # Don't restore on exit
                
                path = configs[selected_name]
                if ZapretManager.apply_config(path, args.hostlist, fwtype):
                    ui.log(f"{Colors.GREEN}✓ Стратегия успешно применена{Colors.END}", to_file=True)
                else:
                    ui.log(f"{Colors.RED}✗ Ошибка применения{Colors.END}", to_file=True)
        except ValueError: pass

    state.restore(ui.log)
    ui.close()

if __name__ == "__main__":
    main()