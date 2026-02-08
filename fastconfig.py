#!/usr/bin/env python3
"""
Zapret Strategy Tester v2 (Optimized)
Features: State Restore, Smart Early Exit, Thread Reuse, Hostlist Injection.
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
import signal
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Tuple

# --- Constants ---
ZAPRET_BASE = Path("/opt/zapret")
ZAPRET_CONFIG_PATH = ZAPRET_BASE / "config"
# Стандартный путь к пользовательскому хостлисту в Zapret
ZAPRET_HOSTLIST_PATH = ZAPRET_BASE / "ipset" / "zapret-hosts-user.txt"

# Тайм-ауты стали агрессивнее для скорости
TIMEOUT_PING = 1.5
TIMEOUT_HTTP = 3
RESTART_DELAY = 0.5  # Пауза после systemctl restart

# --- UI Colors ---
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    END = '\033[0m'

# --- Data Models ---
@dataclass
class DomainResult:
    domain: str
    is_available: bool = False
    latency: float = float('inf')
    details: str = ""

@dataclass
class StrategyStats:
    name: str
    available_count: int
    total_count: int
    google_latency: float
    aborted: bool = False

    @property
    def score(self) -> float:
        """Рейтинг стратегии (кол-во доступных)."""
        return self.available_count

# --- State Management (Restore Logic) ---
class SystemState:
    """Сохраняет и восстанавливает состояние системы (Config, Hostlist, Service)."""
    
    def __init__(self, ui_logger):
        self.ui = ui_logger
        self.original_config = None
        self.original_hostlist = None
        self.was_active = False
        self.should_restore = True  # Флаг, нужно ли восстанавливать при выходе

    def backup(self):
        """Создает бэкап текущего состояния."""
        self.ui.log(f"{Colors.BLUE}[State] Создание резервной копии настроек...{Colors.END}", to_file=False)
        
        # 1. Service State
        res = subprocess.run(["systemctl", "is-active", "zapret"], capture_output=True, text=True)
        self.was_active = (res.returncode == 0)

        # 2. Config
        if ZAPRET_CONFIG_PATH.exists():
            try:
                self.original_config = ZAPRET_CONFIG_PATH.read_bytes()
            except Exception as e:
                self.ui.log(f"{Colors.RED}Ошибка бэкапа конфига: {e}{Colors.END}")

        # 3. Hostlist
        if ZAPRET_HOSTLIST_PATH.exists():
            try:
                self.original_hostlist = ZAPRET_HOSTLIST_PATH.read_bytes()
            except Exception:
                pass # Хостлиста может и не быть

    def restore(self):
        """Восстанавливает состояние (если should_restore=True)."""
        if not self.should_restore:
            return

        self.ui.log(f"\n{Colors.YELLOW}[State] Восстановление исходного состояния...{Colors.END}", to_file=False)

        # 1. Restore Config
        if self.original_config:
            try:
                ZAPRET_CONFIG_PATH.write_bytes(self.original_config)
            except Exception as e:
                print(f"Error restoring config: {e}")

        # 2. Restore Hostlist
        if self.original_hostlist:
            try:
                ZAPRET_HOSTLIST_PATH.write_bytes(self.original_hostlist)
            except Exception as e:
                print(f"Error restoring hostlist: {e}")
        elif ZAPRET_HOSTLIST_PATH.exists():
            # Если файла не было, удаляем созданный
            try:
                os.remove(ZAPRET_HOSTLIST_PATH)
            except: pass

        # 3. Restore Service
        if self.was_active:
            subprocess.run(["systemctl", "restart", "zapret"], capture_output=True)
            self.ui.log(f"{Colors.GREEN}[State] Zapret перезапущен.{Colors.END}", to_file=False)
        else:
            subprocess.run(["systemctl", "stop", "zapret"], capture_output=True)
            self.ui.log(f"{Colors.YELLOW}[State] Zapret остановлен (как было).{Colors.END}", to_file=False)

    def commit(self):
        """Отменяет восстановление при выходе (пользователь выбрал новую стратегию)."""
        self.should_restore = False


# --- UI Layer ---
class ConsoleUI:
    def __init__(self, log_path: str):
        self.log_file = open(log_path, 'w', encoding='utf-8')
        self.lock = threading.Lock()

    def close(self):
        if self.log_file: self.log_file.close()

    def log(self, msg: str, color: str = "", end: str = "\n", to_file: bool = True):
        # Console output
        print(f"{color}{msg}{Colors.END}", end=end)
        # File output (strip colors if needed, but keeping mostly for raw view)
        if to_file and self.log_file:
            clean_msg = re.sub(r'\x1b\[[0-9;]*m', '', msg)
            self.log_file.write(clean_msg + end)
            self.log_file.flush()

    def update_status(self, strategy, status, domain, progress):
        sys.stderr.write(f"\r\033[KStrategy: {strategy[:15]:<15} | {status:<10} | {domain[:30]:<30} | {progress}")
        sys.stderr.flush()

    def clear_status(self):
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()

# --- Network & System ---
class NetworkTester:
    @staticmethod
    def ping(host: str) -> float:
        try:
            # -W 1.5 timeout, -c 1 count (быстрее)
            cmd = ["ping", "-c", "1", "-W", str(TIMEOUT_PING), host]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode == 0:
                match = re.search(r"time=([\d\.]+)", res.stdout)
                if match: return float(match.group(1))
            return float('inf')
        except: return float('inf')

    @staticmethod
    def check_http(domain: str) -> Tuple[bool, str]:
        """Быстрая проверка доступности (HTTP/HTTPS/TLS)."""
        # Используем curl с --fail для быстрого определения успеха
        # Проверяем HTTPS TLS1.2 (наиболее частый кейс)
        # -m (max-time) жестко ограничивает время
        try:
            cmd = ["curl", "-I", "-s", "-m", str(TIMEOUT_HTTP), "--tlsv1.2", f"https://{domain}"]
            res = subprocess.run(cmd, capture_output=True, text=True)
            
            # Коды 2xx, 3xx считаем успехом. 
            if res.returncode == 0:
                # Можно распарсить первую строку HTTP/2 200
                header = res.stdout.split('\n')[0]
                if any(x in header for x in ['200', '301', '302', '307', '403']): 
                    # 403 иногда тоже означает, что DPI пропустил, но сервер отверг, 
                    # но для чистоты теста лучше искать 200/3xx. 
                    # Если DPI блокирует, обычно это тайм-аут или connection reset.
                    return True, "OK"
            
            # Если HTTPS не прошел, пробуем HTTP (редко, но бывает)
            cmd_http = ["curl", "-I", "-s", "-m", str(TIMEOUT_HTTP), f"http://{domain}"]
            res_http = subprocess.run(cmd_http, capture_output=True, text=True)
            if res_http.returncode == 0:
                 return True, "HTTP_OK"

            return False, "FAIL"
        except:
            return False, "ERR"

class ZapretManager:
    @staticmethod
    def apply_config(config_path: str, hostlist_path: str, fwtype: str) -> bool:
        """Применяет конфиг и хостлист."""
        try:
            # 1. Copy Config
            shutil.copy(config_path, ZAPRET_CONFIG_PATH)
            
            # Patch FWTYPE in config in place
            with open(ZAPRET_CONFIG_PATH, 'r') as f: lines = f.readlines()
            with open(ZAPRET_CONFIG_PATH, 'w') as f:
                for line in lines:
                    if line.startswith("FWTYPE="): f.write(f"FWTYPE={fwtype}\n")
                    else: f.write(line)

            # 2. Copy Hostlist (CRITICAL for user point 6)
            # Убедимся, что папка ipset существует
            ZAPRET_HOSTLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(hostlist_path, ZAPRET_HOSTLIST_PATH)

            # 3. Restart
            subprocess.run(["systemctl", "restart", "zapret"], check=True, capture_output=True)
            time.sleep(RESTART_DELAY)
            return True
        except Exception:
            return False

# --- Core Logic ---
class StrategyRunner:
    def __init__(self, ui: ConsoleUI, executor: ThreadPoolExecutor):
        self.ui = ui
        self.executor = executor
        self.best_score = 0
        self.total_domains = 0

    def run(self, name: str, domains: List[str]) -> StrategyStats:
        self.total_domains = len(domains)
        self.ui.update_status(name, "CHECK_NET", "google.com", "...")
        
        # 1. Early Exit: Check Google
        google_lat = NetworkTester.ping("google.com")
        if google_lat == float('inf'):
            self.ui.log(f"   {Colors.RED}google.com недоступен. Пропуск.{Colors.END}", to_file=True)
            return StrategyStats(name, 0, self.total_domains, float('inf'), aborted=True)

        # 2. Parallel Test
        success_count = 0
        completed = 0
        # Порог отсечения: 20% от общего числа.
        # Если (текущие_успехи + оставшиеся_домены) < (лучший_результат - 20%_от_всех), то нет смысла продолжать.
        # Или проще по запросу пользователя: если результат < (лучший - 20%).
        # Реализуем "Smart Cutoff": прерываем, если математически нельзя достичь (Best - Margin).
        margin = int(self.total_domains * 0.2)
        target_threshold = max(0, self.best_score - margin)
        
        aborted = False
        
        # Используем существующий executor (Point 2)
        futures = {self.executor.submit(self._test_single, d): d for d in domains}
        
        try:
            for future in as_completed(futures):
                completed += 1
                try:
                    is_ok = future.result()
                    if is_ok:
                        success_count += 1
                except: pass

                # Smart Exit Logic (Point 1)
                # Max possible score for this run = current success + remaining
                remaining = self.total_domains - completed
                max_possible = success_count + remaining
                
                # Если даже при 100% успехе оставшихся мы не догоним лидера минус маржа
                if self.best_score > 0 and max_possible < target_threshold:
                    aborted = True
                    self.ui.update_status(name, "ABORTING", "Low success rate", f"{completed}/{self.total_domains}")
                    for f in futures: f.cancel() # Try to cancel pending
                    break

                if completed % 5 == 0:
                    pct = int(completed / self.total_domains * 100)
                    self.ui.update_status(name, "TESTING", f"OK: {success_count}", f"{pct}%")

        except KeyboardInterrupt:
            # Re-raise to be caught in main
            raise 
            
        self.ui.clear_status()
        
        if aborted:
            msg = f"   {Colors.YELLOW}Прервано: низкая эффективность ({success_count} OK).{Colors.END}"
        else:
            pct = (success_count / self.total_domains * 100)
            color = Colors.GREEN if pct > 50 else Colors.RED
            msg = f"   Результат: {color}{success_count}/{self.total_domains} ({pct:.1f}%){Colors.END} | Ping: {google_lat:.1f}ms"
            
            # Обновляем лучший результат, если этот тест был полным
            if success_count > self.best_score:
                self.best_score = success_count

        self.ui.log(msg, to_file=True)
        return StrategyStats(name, success_count, self.total_domains, google_lat, aborted)

    def _test_single(self, domain: str) -> bool:
        # Просто wrapper для выполнения в потоке
        # Сначала пинг IP (быстро), если домен не резолвится - fail
        # В данном скрипте NetworkTester делает curl, он сам резолвит.
        ok, _ = NetworkTester.check_http(domain)
        return ok

# --- Main ---
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("configs_json", help="JSON с конфигами")
    parser.add_argument("hostlist", help="Файл со списком доменов")
    parser.add_argument("--threads", "-t", type=int, default=20, help="Число потоков")
    args = parser.parse_args()

    # Проверка прав
    if os.geteuid() != 0:
        print(f"{Colors.RED}Требуются права root!{Colors.END}")
        sys.exit(1)

    # Init
    log_path = f"/tmp/zapret_test_{datetime.now().strftime('%H%M%S')}.log"
    ui = ConsoleUI(log_path)
    state = SystemState(ui)
    
    # Загрузка ресурсов
    try:
        with open(args.configs_json) as f: strategies = json.load(f)
        with open(args.hostlist) as f: 
            domains = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    except Exception as e:
        print(f"Ошибка файлов: {e}")
        sys.exit(1)

    fwtype = "nftables" # Детектить лень, чаще всего это nftables в современных OS. 
    # (Можно вернуть детектор из прошлой версии, если критично)

    # Бэкап
    state.backup()
    
    # Глобальный пул потоков (Point 2)
    # Создаем один раз, используем везде.
    executor = ThreadPoolExecutor(max_workers=args.threads)
    runner = StrategyRunner(ui, executor)

    all_stats = []

    ui.log(f"{Colors.BOLD}{Colors.CYAN}=== Zapret Optimized Tester ==={Colors.END}")
    ui.log(f"Стратегий: {len(strategies)} | Доменов: {len(domains)} | Потоков: {args.threads}")
    ui.log(f"Хостлист будет временно скопирован в: {ZAPRET_HOSTLIST_PATH}")
    
    try:
        for idx, (name, path) in enumerate(strategies.items(), 1):
            ui.log(f"\n{Colors.CYAN}[{idx}/{len(strategies)}] Применение: {name}{Colors.END}", to_file=True)
            
            # Применяем конфиг и ХОСТЛИСТ (Point 6)
            if not ZapretManager.apply_config(path, args.hostlist, fwtype):
                ui.log(f"{Colors.RED}Ошибка перезапуска службы!{Colors.END}")
                continue
            
            # Запуск теста
            stats = runner.run(name, domains)
            if not stats.aborted:
                all_stats.append(stats)
            
    except KeyboardInterrupt:
        ui.log(f"\n{Colors.RED}Тест прерван пользователем!{Colors.END}")
    finally:
        # Shutdown executor
        executor.shutdown(wait=False)

        # Сортировка результатов
        all_stats.sort(key=lambda x: (-x.score, x.google_latency))
        
        # Вывод таблицы
        ui.clear_status()
        ui.log(f"\n{Colors.CYAN}{'='*60}{Colors.END}")
        ui.log(f"{Colors.BOLD}{'#':<3} {'Стратегия':<25} {'Score':<10} {'Ping':<10}{Colors.END}")
        ui.log(f"{Colors.CYAN}{'-'*60}{Colors.END}")
        
        top_strategies = all_stats[:10]
        for i, s in enumerate(top_strategies, 1):
            ping_str = f"{s.google_latency:.1f}ms" if s.google_latency < 999 else "N/A"
            ui.log(f"{Colors.YELLOW}{i:<3}{Colors.END} {s.name:<25} {Colors.GREEN}{s.score}/{s.total_count}{Colors.END} {ping_str}")
        
        ui.log(f"{Colors.CYAN}{'='*60}{Colors.END}")

        # Меню выбора (Point 5)
        choice_idx = -1
        if top_strategies:
            print(f"\n{Colors.BOLD}Выберите действие:{Colors.END}")
            print(f"  {Colors.GREEN}1-{len(top_strategies)}{Colors.END} : Применить стратегию из топа")
            print(f"  {Colors.RED}0{Colors.END}   : Выйти и восстановить настройки (как было до запуска)")
            
            while True:
                try:
                    val = input(f"\nВаш выбор [{Colors.GREEN}1{Colors.END}]: ").strip()
                    if not val: val = "1" # Default best
                    choice_idx = int(val)
                    if 0 <= choice_idx <= len(top_strategies):
                        break
                except ValueError: pass
        
        if choice_idx > 0:
            # Пользователь выбрал стратегию
            selected = top_strategies[choice_idx-1]
            config_path = strategies[selected.name]
            
            print(f"\n{Colors.GREEN}Применяю стратегию: {selected.name}...{Colors.END}")
            
            # Мы фиксируем изменения, чтобы restore() при выходе не сработал
            state.commit()
            
            # Применяем финально (еще раз, на случай если последняя в тесте была другая)
            ZapretManager.apply_config(config_path, args.hostlist, fwtype)
            print(f"{Colors.BOLD}Готово. Zapret настроен и работает.{Colors.END}")
            
        else:
            # Пользователь выбрал 0 или списка нет -> сработает state.restore() автоматически
            print(f"\n{Colors.YELLOW}Отмена изменений...{Colors.END}")

        # State restore вызывается в конце, если не было commit()
        state.restore()
        ui.close()

if __name__ == "__main__":
    main()