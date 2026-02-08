#!/usr/bin/env python3
"""
Zapret Strategy Tester (Hybrid)
UI: Classic V1 style (Detailed tables)
Core: Optimized V2 (State restore, Thread reuse, Hostlist injection)
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

TIMEOUT_PING = 2
TIMEOUT_HTTP = 5
RESTART_DELAY = 1

# --- V1 Colors ---
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    MAGENTA = '\033[95m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'
    END = '\033[0m'
    GRAY = '\033[90m'

# --- State Management (Optimized Logic) ---
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

# --- UI Layer (V1 Style) ---
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
        """V1 Logger"""
        if self.log_file and to_file:
            self.log_file.write(message + end)
            self.log_file.flush()
        print(f"{color}{message}{Colors.END}", end=end)

    def update_status(self, strategy, phase, domain, progress):
        """V1 Status Bar"""
        with self.status_lock:
            status_line = f"\r\033[K{Colors.CYAN}strategy:{Colors.END} {strategy[:15]:15} | " \
                          f"{Colors.CYAN}status:{Colors.END} {phase:12} " \
                          f"{domain[:30]:30} | " \
                          f"{Colors.CYAN}progress:{Colors.END} {progress:10}"
            sys.stderr.write(status_line)
            sys.stderr.flush()

    def clear_status(self):
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()

    def colorize_result(self, result):
        """V1 Result Colorizer"""
        if result == "FAIL":
            return f"{Colors.RED}{result}{Colors.END}"
        elif "ms" in result:
            try:
                ms = float(result.replace("ms", ""))
                if ms < 50: return f"{Colors.GREEN}{result}{Colors.END}"
                elif ms < 200: return f"{Colors.YELLOW}{result}{Colors.END}"
                else: return f"{Colors.RED}{result}{Colors.END}"
            except: return f"{Colors.WHITE}{result}{Colors.END}"
        elif (result.startswith(("HTTP:2", "HTTP:3", "TLS1.2:2", "TLS1.2:3", "TLS1.3:2", "TLS1.3:3")) or
              result.startswith(("TLSV1.2:2", "TLSV1.2:3", "TLSV1.3:2", "TLSV1.3:3"))):
            return f"{Colors.GREEN}{result}{Colors.END}"
        elif result == "N/A":
            return f"{Colors.BLUE}{result}{Colors.END}"
        else:
            return f"{Colors.RED}{result}{Colors.END}"

    def print_results_table(self, strategy_name, results, total_tested, total_available, google_ping):
        """V1 Table Style"""
        self.clear_status()
        separator = f"{Colors.CYAN}{'='*90}{Colors.END}"
        title = f"{Colors.BOLD}{Colors.CYAN}РЕЗУЛЬТАТЫ СТРАТЕГИИ: {strategy_name}{Colors.END}"
        header = f"{Colors.BOLD}{Colors.WHITE}{'Домен/IP':<40} {'Ping':<10} {'HTTP':<10} {'TLS1.2':<10} {'TLS1.3':<10}{Colors.END}"
        
        self.log(f"\n{separator}")
        self.log(title)
        
        if google_ping < float('inf'):
            ping_color = Colors.GREEN if google_ping < 50 else Colors.YELLOW if google_ping < 200 else Colors.RED
            self.log(f"{Colors.CYAN}Базовая задержка (google.com): {ping_color}{google_ping:.1f}ms{Colors.END}")
        
        self.log(separator)
        self.log(header)
        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}")
        
        # Logic to skip middle rows if too many
        display_items = list(results.items())
        if len(results) > 30:
            top_20 = display_items[:20]
            last_10 = display_items[-10:]
            skipped = len(results) - 30
            
            self._print_rows(top_20)
            self.log(f"\n{Colors.YELLOW}... пропущено {skipped} результатов ...{Colors.END}", to_file=True)
            self._print_rows(last_10)
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
        """V1 Final Summary Style"""
        self.clear_status()
        self.log(f"\n{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
        self.log(f"{Colors.BOLD}{Colors.CYAN}ИТОГИ ТЕСТИРОВАНИЯ ВСЕХ СТРАТЕГИЙ{Colors.END}", to_file=True)
        self.log(f"{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
        
        header = f"{Colors.BOLD}{Colors.WHITE}{'№':<3} {'Стратегия':<30} {'Доступно':>10} {'%':>8} {'Google Ping':>12} {'Рейтинг':<10}{Colors.END}"
        separator = f"{Colors.CYAN}{'-'*90}{Colors.END}"
        
        self.log(header, to_file=True)
        self.log(separator, to_file=True)
        
        for idx, (strategy, available, ping) in enumerate(stats_list, 1):
            percentage = (available / total_domains * 100) if total_domains > 0 else 0
            
            if idx == 1: color, rating = Colors.GREEN, f"{Colors.GREEN}ЛУЧШАЯ{Colors.END}"
            elif percentage > 80: color, rating = Colors.GREEN, f"{Colors.GREEN}ОТЛИЧНО{Colors.END}"
            elif percentage > 60: color, rating = Colors.YELLOW, f"{Colors.YELLOW}ХОРОШО{Colors.END}"
            elif percentage > 40: color, rating = Colors.YELLOW, f"{Colors.YELLOW}СРЕДНЕ{Colors.END}"
            else: color, rating = Colors.RED, f"{Colors.RED}ПЛОХО{Colors.END}"
            
            if ping < float('inf'):
                p_col = Colors.GREEN if ping < 50 else Colors.YELLOW if ping < 100 else Colors.RED
                ping_display = f"{p_col}{ping:>10.1f}ms{Colors.END}"
            else:
                ping_display = f"{Colors.RED}{'N/A':>10}{Colors.END}"
            
            s_disp = strategy[:28] + "..." if len(strategy) > 28 else strategy
            row = f"{color}{idx:<3}{Colors.END} " \
                  f"{color}{s_disp:<30}{Colors.END} " \
                  f"{color}{available:>10}{Colors.END} " \
                  f"{color}{percentage:>7.1f}%{Colors.END} " \
                  f"{ping_display:>12} " \
                  f"{rating:<10}"
            self.log(row, to_file=True)

# --- Network Logic ---
class NetworkTester:
    @staticmethod
    def _run_cmd(cmd, timeout):
        """Вспомогательный метод для запуска команд без лишнего оверхеда"""
        try:
            # shell=False быстрее и безопаснее
            # capture_output=True создает пайпы, что может быть медленно на массе,
            # но нужно для парсинга.
            res = subprocess.run(
                cmd, 
                capture_output=True, 
                text=True, 
                timeout=timeout
            )
            return res
        except subprocess.TimeoutExpired:
            return None
        except Exception:
            return None

    @staticmethod
    def test_ping(domain, timeout=1.5):
        # Используем -c 1 для скорости. Если пакет потерян - считаем FAIL.
        # Для статистики нам не нужна супер-точность среднего из 4 пакетов.
        cmd = ["ping", "-c", "1", "-W", str(timeout), domain]
        res = NetworkTester._run_cmd(cmd, timeout + 0.5)
        
        if res and res.returncode == 0:
            match = re.search(r"time=([\d\.]+)", res.stdout)
            if match:
                ms = float(match.group(1))
                return f"{ms:.0f}ms", True, ms
        return "FAIL", False, float('inf')

    @staticmethod
    def curl_check(domain, mode, timeout=3):
        """Универсальная проверка CURL"""
        # --max-time (или -m) жестко обрывает curl
        # -I (HEAD) быстрее, чем скачивать тело страницы
        base_cmd = ["curl", "-I", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", str(timeout)]
        
        if mode == "http":
            url = f"http://{domain}"
            label = "HTTP"
        elif mode == "tls1.2":
            url = f"https://{domain}"
            base_cmd.append("--tlsv1.2")
            label = "TLS1.2"
        elif mode == "tls1.3":
            url = f"https://{domain}"
            base_cmd.append("--tlsv1.3")
            label = "TLS1.3"
            
        base_cmd.append(url)
        
        res = NetworkTester._run_cmd(base_cmd, timeout + 0.5)
        
        if res and res.returncode == 0 and res.stdout.isdigit():
            code = int(res.stdout)
            # Если код 000 - это ошибка curl (но returncode 0)
            if code > 0:
                return f"{label}:{code}"
        return "FAIL"

    @staticmethod
    def full_test_domain_parallel(domain):
        """
        Запускает проверки параллельно для одного домена.
        Это решает проблему зависания на 15 секунд.
        """
        domain = domain.strip()
        if not domain or domain.startswith('#'): 
            return domain, ["FAIL"]*4 + [0], float('inf')
        
        # 1. Ping (последовательно, так как это дешево и отсекает мертвые IP)
        ping_res, ping_ok, ping_time = NetworkTester.test_ping(domain)
        
        # Если это IP и он не пингуется - считаем мертвым (для скорости)
        is_ip = bool(re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', domain))
        if is_ip and not ping_ok:
             return domain, ["FAIL", "FAIL", "FAIL", "FAIL", 0], float('inf')
        
        if is_ip:
             # IP обычно не имеют сертификатов, curl бессмысленен без Host хедера
             return domain, [ping_res, "N/A", "N/A", "N/A", 1], ping_time

        # 2. Параллельный запуск CURL (HTTP, TLS1.2, TLS1.3)
        # Используем потоки внутри потока? Нет, это слишком накладно.
        # Лучше запустить subprocess.Popen не блокируясь, а потом собрать результаты.
        
        import subprocess
        
        def start_proc(cmd):
            return subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
            )

        # Формируем команды
        t_out = 3 # Жесткий таймаут для CURL
        
        # HTTP
        cmd_http = ["curl", "-I", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", str(t_out), f"http://{domain}"]
        # TLS 1.2
        cmd_t12 = ["curl", "-I", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", str(t_out), "--tlsv1.2", f"https://{domain}"]
        # TLS 1.3
        cmd_t13 = ["curl", "-I", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", str(t_out), "--tlsv1.3", f"https://{domain}"]

        # Запускаем все три процесса одновременно
        p_http = start_proc(cmd_http)
        p_t12 = start_proc(cmd_t12)
        p_t13 = start_proc(cmd_t13)

        def get_res(proc, label):
            try:
                # communicate ждет завершения
                out, _ = proc.communicate(timeout=t_out + 1)
                if proc.returncode == 0 and out.strip().isdigit():
                    return f"{label}:{out.strip()}"
            except subprocess.TimeoutExpired:
                proc.kill()
            except: pass
            return "FAIL"

        # Собираем результаты (они будут готовы почти одновременно)
        res_http = get_res(p_http, "HTTP")
        res_t12 = get_res(p_t12, "TLS1.2")
        res_t13 = get_res(p_t13, "TLS1.3")

        # Анализ доступности
        def is_ok(s): return "200" in s or "301" in s or "302" in s or "403" in s
        # Расширенная проверка: любой код ответа curl лучше чем FAIL
        available = 1 if (res_t12 != "FAIL" or res_t13 != "FAIL") else 0
        
        return domain, [ping_res, res_http, res_t12, res_t13, available], ping_time

    @staticmethod
    def test_google():
        try:
            res = subprocess.run(["ping", "-c", "4", "-W", "2", "google.com"], capture_output=True, text=True, timeout=5)
            if res.returncode == 0:
                match = re.search(r"min/avg/max/mdev = [\d\.]+/([\d\.]+)/", res.stdout)
                if match: return float(match.group(1))
        except: pass
        return float('inf')

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
    except: return None

    # Detect FW
    fwtype = "nftables" # Simple default
    try:
        r = subprocess.run(["iptables", "--version"], capture_output=True, text=True)
        if "legacy" in r.stdout: fwtype = "iptables"
    except: pass
    
    ui.log(f"Обнаружен фаервол: {Colors.BOLD}{fwtype}{Colors.END}", Colors.WHITE, to_file=True)
    
    executor = ThreadPoolExecutor(max_workers=threads) # Reuse threads
    stats = []
    
    best_score = 0
    total_domains = len(domains)
    margin = int(total_domains * 0.2)

    try:
        for i, (name, path) in enumerate(configs.items(), 1):
            ui.log(f"\n{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
            ui.log(f"Стратегия [{i}/{len(configs)}]: {Colors.BOLD}{name}{Colors.END}", Colors.YELLOW, to_file=True)
            
            if not ZapretManager.apply_config(path, hostlist_path, fwtype):
                ui.log(f"{Colors.RED}Ошибка применения стратегии, пропускаю...{Colors.END}", to_file=True)
                continue

            # Base Ping
            ui.update_status(name, "init", "google.com", "ping...")
            google_ping = NetworkTester.test_google()
            if google_ping == float('inf'):
                ui.log(f"{Colors.RED}Google недоступен! Пропуск стратегии.{Colors.END}", to_file=True)
                stats.append((name, 0, float('inf')))
                continue

            # Run Threads
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
                    if metrics[4]: available += 1 # Index 4 is available flag
                    
                    # V1 Status Bar
                    pct = int(completed / total_domains * 100)
                    ui.update_status(name, "testing", d, f"{pct}% ({completed}/{total_domains})")
                    
                    # Smart Exit
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

    # Final Summary (V1 Style)
    if stats:
        # Sort logic
        sorted_stats = sorted(stats, key=lambda x: (-x[1], x[2]))
        ui.print_final_summary(sorted_stats, total_domains)
        
        best = sorted_stats[0]
        if best[1] > 0:
            b_name, b_avail, b_ping = best
            pct = (b_avail / total_domains * 100)
            p_disp = f"{b_ping:.1f}ms" if b_ping < 999 else "N/A"
            ui.log(f"\n{Colors.BOLD}{Colors.GREEN}✓ ЛУЧШАЯ СТРАТЕГИЯ:{Colors.END} {Colors.BOLD}{b_name}{Colors.END}", to_file=True)
            ui.log(f"{Colors.GREEN}  Доступно: {b_avail}/{total_domains} ({pct:.1f}%) доменов, задержка: {p_disp}{Colors.END}", to_file=True)
            
            return sorted_stats, fwtype
    return None, fwtype

# --- Main ---
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("configs_json", help="JSON конфиг")
    parser.add_argument("hostlist", help="Файл хостлиста")
    parser.add_argument("--threads", "-t", type=int, default=10)
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
    
    ui.log(f"{Colors.BOLD}{Colors.CYAN}Тестирование стратегий Zapret (Hybrid V2){Colors.END}", to_file=True)
    ui.log(f"Лог: /tmp/zapret_test_{ts}.log", Colors.WHITE, to_file=True)
    ui.log(f"Количество потоков: {args.threads}", Colors.WHITE, to_file=True)

    results, fwtype = run_tests(configs, args.hostlist, args.threads, ui, state)

    # Interactive Menu
    if results:
        top_10 = results[:10]
        print(f"\n{Colors.BOLD}Выберите действие:{Colors.END}")
        for i, (name, av, _) in enumerate(top_10, 1):
             print(f"  {Colors.GREEN}{i}{Colors.END}: Применить {Colors.BOLD}{name}{Colors.END}")
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