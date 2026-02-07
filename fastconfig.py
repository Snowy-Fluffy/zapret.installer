#!/usr/bin/env python3
"""
Ускоренный тестер стратегий для Zapret с live-статусом и управлением потоками
"""

import subprocess
import time
import threading
import os
import sys
import re
import json
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
import shutil
from datetime import datetime
from collections import OrderedDict, defaultdict

# Глобальная переменная для статуса
current_status = {"strategy": "", "domain": "", "phase": "idle", "progress": ""}
status_lock = threading.Lock()
output_file = None

# ANSI коды цветов
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

def log_message(message, color="", to_file=True, end="\n"):
    """Логирует сообщение с цветом в консоль и файл (с цветами)"""
    if output_file and to_file:
        # Сохраняем сообщение с цветами в файл
        output_file.write(message + end)
        output_file.flush()
    
    # Выводим в консоль с цветом
    print(f"{color}{message}{Colors.END}", end=end)

def update_status(strategy=None, domain=None, phase=None, progress=None):
    """Обновляет статус выполнения"""
    with status_lock:
        if strategy is not None:
            current_status["strategy"] = strategy
        if domain is not None:
            current_status["domain"] = domain[:40]
        if phase is not None:
            current_status["phase"] = phase
        if progress is not None:
            current_status["progress"] = progress
    
    # Выводим одну строку статуса
    status_line = f"\r\033[K{Colors.CYAN}strategy:{Colors.END} {current_status['strategy'][:15]:15} | " \
                  f"{Colors.CYAN}status:{Colors.END} {current_status['phase']:12} " \
                  f"{current_status['domain'][:30]:30} | " \
                  f"{Colors.CYAN}progress:{Colors.END} {current_status['progress']:10}"
    sys.stderr.write(status_line)
    sys.stderr.flush()

def clear_status():
    """Очищает строку статуса"""
    sys.stderr.write("\r\033[K")
    sys.stderr.flush()

def test_ping(domain, timeout=2):
    """Тест ping с таймаутом"""
    try:
        result = subprocess.run(
            ["ping", "-c", "2", "-W", str(timeout), domain],
            capture_output=True,
            text=True,
            timeout=timeout + 1
        )
        if result.returncode == 0:
            match = re.search(r"min/avg/max/mdev = [\d\.]+/([\d\.]+)/", result.stdout)
            if match:
                ping_time = float(match.group(1))
                return f"{ping_time:.1f}ms", True, ping_time
        return "FAIL", False, float('inf')
    except:
        return "FAIL", False, float('inf')

def test_google_ping():
    """Тест ping до Google для измерения базовой задержки стратегии"""
    try:
        result = subprocess.run(
            ["ping", "-c", "4", "-W", "2", "google.com"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            match = re.search(r"min/avg/max/mdev = [\d\.]+/([\d\.]+)/", result.stdout)
            if match:
                return float(match.group(1))
        return float('inf')
    except:
        return float('inf')

def test_http(domain, timeout=5):
    """Тест HTTP соединения"""
    try:
        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", 
             "-m", str(timeout), f"http://{domain}"],
            capture_output=True,
            text=True,
            timeout=timeout + 1
        )
        if result.returncode == 0 and result.stdout.isdigit():
            return f"HTTP:{result.stdout}"
        return "FAIL"
    except:
        return "FAIL"

def test_https(domain, timeout=5, tls_version="tlsv1.2"):
    """Тест HTTPS с указанной версией TLS"""
    tls_flag = f"--{tls_version}"
    try:
        result = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "-m", str(timeout), tls_flag, f"https://{domain}"],
            capture_output=True,
            text=True,
            timeout=timeout + 1
        )
        if result.returncode == 0 and result.stdout.isdigit():
            return f"{tls_version.upper()}:{result.stdout}"
        return "FAIL"
    except:
        return "FAIL"

def test_domain(domain, timeout=5):
    """Тестирует домен с оптимизацией"""
    domain = domain.strip()
    if not domain or domain.startswith('#'):
        return domain, ["FAIL", "FAIL", "FAIL", "FAIL", 0]
    
    is_ip = re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', domain)
    
    ping_result, ping_success, ping_time = test_ping(domain, timeout if is_ip else 2)
    
    if not ping_success:
        return domain, ["FAIL", "FAIL", "FAIL", "FAIL", 0], ping_time
    
    if is_ip:
        return domain, [ping_result, "N/A", "N/A", "N/A", 1], ping_time
    
    http_result = test_http(domain, timeout)
    tls12_result = test_https(domain, timeout, "tlsv1.2")
    tls13_result = test_https(domain, timeout, "tlsv1.3")
    
    # Исправлено: теперь проверяем как "TLS1.2", так и "TLSV1.2"
    tls12_ok = (tls12_result.startswith("TLS1.2:2") or tls12_result.startswith("TLS1.2:3") or
                tls12_result.startswith("TLSV1.2:2") or tls12_result.startswith("TLSV1.2:3"))
    tls13_ok = (tls13_result.startswith("TLS1.3:2") or tls13_result.startswith("TLS1.3:3") or
                tls13_result.startswith("TLSV1.3:2") or tls13_result.startswith("TLSV1.3:3"))
    available = 1 if tls12_ok or tls13_ok else 0
    
    return domain, [ping_result, http_result, tls12_result, tls13_result, available], ping_time

def apply_config(config_path, fwtype="nftables"):
    """Применяет конфигурацию с использованием systemctl"""
    try:
        shutil.copy(config_path, "/opt/zapret/config")
        
        with open("/opt/zapret/config", 'r') as f:
            lines = f.readlines()
        
        with open("/opt/zapret/config", 'w') as f:
            for line in lines:
                if line.startswith("FWTYPE="):
                    f.write(f"FWTYPE={fwtype}\n")
                else:
                    f.write(line)
        
        subprocess.run(
            ["systemctl", "restart", "zapret"], 
            check=True, 
            capture_output=True,
            text=True
        )
        
        time.sleep(2)
        return True
    except:
        return False

def colorize_result(result):
    """Добавляет цвет к результату теста"""
    if result == "FAIL":
        return f"{Colors.RED}{result}{Colors.END}"
    elif "ms" in result:
        try:
            ms = float(result.replace("ms", ""))
            if ms < 50:
                return f"{Colors.GREEN}{result}{Colors.END}"
            elif ms < 200:
                return f"{Colors.YELLOW}{result}{Colors.END}"
            else:
                return f"{Colors.RED}{result}{Colors.END}"
        except:
            return f"{Colors.WHITE}{result}{Colors.END}"
    # Исправлено: теперь обрабатываем как "TLS1.2", так и "TLSV1.2"
    elif (result.startswith(("HTTP:2", "HTTP:3", "TLS1.2:2", "TLS1.2:3", "TLS1.3:2", "TLS1.3:3")) or
          result.startswith(("TLSV1.2:2", "TLSV1.2:3", "TLSV1.3:2", "TLSV1.3:3"))):
        return f"{Colors.GREEN}{result}{Colors.END}"
    elif result == "N/A":
        return f"{Colors.BLUE}{result}{Colors.END}"
    else:
        return f"{Colors.RED}{result}{Colors.END}"

def print_results_table(strategy_name, results, total_tested, total_available, google_ping):
    """Выводит таблицу результатов один раз в конце тестирования стратегии"""
    clear_status()
    
    # Выводим заголовок таблицы
    separator = f"{Colors.CYAN}{'='*90}{Colors.END}"
    title = f"{Colors.BOLD}{Colors.CYAN}РЕЗУЛЬТАТЫ СТРАТЕГИИ: {strategy_name}{Colors.END}"
    header = f"{Colors.BOLD}{Colors.WHITE}{'Домен/IP':<40} {'Ping':<10} {'HTTP':<10} {'TLS1.2':<10} {'TLS1.3':<10}{Colors.END}"
    
    log_message(f"\n{separator}")
    log_message(title)
    
    if google_ping < float('inf'):
        ping_color = Colors.GREEN if google_ping < 50 else Colors.YELLOW if google_ping < 200 else Colors.RED
        log_message(f"{Colors.CYAN}Базовая задержка (google.com): {ping_color}{google_ping:.1f}ms{Colors.END}")
    
    log_message(separator)
    log_message(header)
    log_message(f"{Colors.CYAN}{'-'*90}{Colors.END}")
    
    # Выводим результаты
    max_display = 30
    if len(results) > max_display:
        display_results = list(results.items())[:20]
        skipped = len(results) - 30
        
        for domain, metrics in display_results:
            display_domain = domain[:38] + "..." if len(domain) > 38 else domain
            row = f"{Colors.WHITE}{display_domain:<40}{Colors.END} " \
                  f"{colorize_result(metrics[0]):<10} " \
                  f"{colorize_result(metrics[1]):<10} " \
                  f"{colorize_result(metrics[2]):<10} " \
                  f"{colorize_result(metrics[3]):<10}"
            log_message(row, to_file=True)
        
        if skipped > 0:
            log_message(f"\n{Colors.YELLOW}... пропущено {skipped} результатов ...{Colors.END}", to_file=True)
        
        display_results = list(results.items())[-10:]
        for domain, metrics in display_results:
            display_domain = domain[:38] + "..." if len(domain) > 38 else domain
            row = f"{Colors.WHITE}{display_domain:<40}{Colors.END} " \
                  f"{colorize_result(metrics[0]):<10} " \
                  f"{colorize_result(metrics[1]):<10} " \
                  f"{colorize_result(metrics[2]):<10} " \
                  f"{colorize_result(metrics[3]):<10}"
            log_message(row, to_file=True)
    else:
        for domain, metrics in results.items():
            display_domain = domain[:38] + "..." if len(domain) > 38 else domain
            row = f"{Colors.WHITE}{display_domain:<40}{Colors.END} " \
                  f"{colorize_result(metrics[0]):<10} " \
                  f"{colorize_result(metrics[1]):<10} " \
                  f"{colorize_result(metrics[2]):<10} " \
                  f"{colorize_result(metrics[3]):<10}"
            log_message(row, to_file=True)
    
    log_message(f"{Colors.CYAN}{'-'*90}{Colors.END}")
    
    # Статистика
    percentage = (total_available / total_tested * 100) if total_tested > 0 else 0
    if percentage > 70:
        status_color = Colors.GREEN
        status_icon = "✓"
    elif percentage > 30:
        status_color = Colors.YELLOW
        status_icon = "⚠"
    else:
        status_color = Colors.RED
        status_icon = "✗"
    
    stats_msg = f"{status_color}{status_icon} {Colors.BOLD}Доступно:{Colors.END} " \
                f"{status_color}{total_available}/{total_tested}{Colors.END} " \
                f"{Colors.BOLD}доменов/IP ({percentage:.1f}%){Colors.END}"
    
    log_message(stats_msg, to_file=True)
    log_message(f"{Colors.CYAN}{'='*90}{Colors.END}\n")

def test_strategy(strategy_name, strategy_path, hostlist_path, threads=10):
    """Тестирует одну стратегию на всем хостлисте"""
    update_status(strategy=strategy_name, phase="начало", progress="0%")
    
    # Измеряем базовую задержку до google.com
    google_ping = test_google_ping()
    
    # Читаем хостлист
    try:
        with open(hostlist_path, 'r') as f:
            domains = [line.strip() for line in f if line.strip() and not line.startswith('#')]
    except Exception as e:
        log_message(f"Ошибка чтения хостлиста: {e}", Colors.RED, to_file=True)
        return 0, float('inf')
    
    total = len(domains)
    if total == 0:
        log_message("Хостлист пуст!", Colors.RED, to_file=True)
        return 0, google_ping
    
    available = 0
    results = OrderedDict()
    ping_times = []
    
    # Тестируем домены
    try:
        with ThreadPoolExecutor(max_workers=threads) as executor:
            future_to_domain = {
                executor.submit(test_domain, domain): domain 
                for domain in domains
            }
            
            completed = 0
            for future in as_completed(future_to_domain):
                domain = future_to_domain[future]
                completed += 1
                
                try:
                    domain_result, metrics, ping_time = future.result(timeout=30)
                    results[domain_result] = metrics
                    
                    if ping_time < float('inf'):
                        ping_times.append(ping_time)
                    
                    progress_percent = int((completed / len(future_to_domain)) * 100)
                    update_status(
                        domain=domain,
                        phase="тестирование",
                        progress=f"{progress_percent}% ({completed}/{len(future_to_domain)})"
                    )
                    
                    if metrics[4]:
                        available += 1
                        
                except Exception as e:
                    log_message(f"Ошибка тестирования {domain}: {e}", Colors.RED, to_file=True)
    
    except KeyboardInterrupt:
        log_message("\nТестирование прервано пользователем", Colors.YELLOW, to_file=True)
        clear_status()
        return available, google_ping
    
    update_status(phase="завершено", progress="100%", domain="")
    clear_status()
    
    # Выводим таблицу результатов
    print_results_table(strategy_name, results, total, available, google_ping)
    
    return available, google_ping

def resolve_strategy_tie(strategies_stats):
    """Разрешает конфликты при выборе лучшей стратегии"""
    return sorted(strategies_stats, key=lambda x: (-x[1], x[2]))

def main_test(configs_to_test, hostlist_path, threads=10, apply_best=True):
    """Основная функция тестирования"""
    global output_file
    
    # Создаем файл для вывода
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_filename = f"/tmp/zapret_test_{timestamp}.log"
    
    try:
        output_file = open(log_filename, 'w', encoding='utf-8')
        # Добавляем BOM для UTF-8 (необязательно, но может помочь)
        output_file.write('\ufeff')
        
        log_message(f"{Colors.BOLD}{Colors.CYAN}Тестирование стратегий Zapret{Colors.END}", to_file=True)
        log_message(f"Время начала: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", Colors.WHITE, to_file=True)
        log_message(f"Файл лога: {log_filename}", Colors.WHITE, to_file=True)
        log_message(f"Количество потоков: {threads}", Colors.WHITE, to_file=True)
        log_message(f"Хостлист: {hostlist_path}", Colors.WHITE, to_file=True)
        log_message(f"Стратегий для тестирования: {len(configs_to_test)}", Colors.WHITE, to_file=True)
        log_message(f"{Colors.CYAN}{'='*50}{Colors.END}", to_file=True)
    except Exception as e:
        log_message(f"Не удалось создать файл лога: {e}", Colors.RED)
        output_file = None
    
    # Определяем тип фаервола
    try:
        result = subprocess.run(
            ["iptables", "--version"], 
            capture_output=True, 
            text=True
        )
        if "legacy" in result.stdout:
            fwtype = "iptables"
        elif "nf_tables" in result.stdout:
            fwtype = "nftables"
        else:
            fwtype = "nftables"
    except:
        fwtype = "nftables"
    
    log_message(f"Обнаружен фаервол: {Colors.BOLD}{fwtype}{Colors.END}", Colors.WHITE, to_file=True)
    
    # Получаем общее количество доменов
    try:
        with open(hostlist_path, 'r') as f:
            total_domains = len([line for line in f if line.strip() and not line.startswith('#')])
    except:
        total_domains = 0
    
    stats = []
    
    try:
        config_items = list(configs_to_test.items())
        total_configs = len(config_items)
        
        for i, (config_name, config_path) in enumerate(config_items):
            log_message(f"\n{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
            log_message(f"Стратегия [{i+1}/{total_configs}]: {Colors.BOLD}{config_name}{Colors.END}", Colors.YELLOW, to_file=True)
            
            # Применяем стратегию
            if not apply_config(config_path, fwtype):
                log_message(f"{Colors.RED}Ошибка применения стратегии {config_name}, пропускаю...{Colors.END}", to_file=True)
                stats.append((config_name, 0, float('inf')))
                continue
            
            # Тестируем
            available, google_ping = test_strategy(config_name, config_path, hostlist_path, threads)
            stats.append((config_name, available, google_ping))
            
            # if i < total_configs - 1:
            #     time.sleep(2)
    
    except KeyboardInterrupt:
        log_message(f"\n{Colors.RED}Тестирование прервано пользователем{Colors.END}", to_file=True)
        clear_status()
    except Exception as e:
        log_message(f"\n{Colors.RED}Ошибка тестирования: {e}{Colors.END}", to_file=True)
    
    # Выводим итоговую таблицу
    if stats:
        sorted_stats = resolve_strategy_tie(stats)
        
        clear_status()
        log_message(f"\n{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
        log_message(f"{Colors.BOLD}{Colors.CYAN}ИТОГИ ТЕСТИРОВАНИЯ ВСЕХ СТРАТЕГИЙ{Colors.END}", to_file=True)
        log_message(f"{Colors.CYAN}{'='*90}{Colors.END}", to_file=True)
        
        # Заголовок таблицы
        header = f"{Colors.BOLD}{Colors.WHITE}{'№':<3} {'Стратегия':<30} {'Доступно':>10} {'%':>8} {'Google Ping':>12} {'Рейтинг':<10}{Colors.END}"
        separator = f"{Colors.CYAN}{'-'*90}{Colors.END}"
        
        log_message(header, to_file=True)
        log_message(separator, to_file=True)
        
        # Топ-10 стратегий
        top_10 = sorted_stats[:10]
        best_strategy, best_available, best_ping = sorted_stats[0] if sorted_stats else (None, 0, float('inf'))
        
        for idx, (strategy, available, ping) in enumerate(top_10, 1):
            if total_domains > 0:
                percentage = (available / total_domains * 100)
            else:
                percentage = 0
            
            if idx == 1:
                color = Colors.GREEN
                rating = f"{Colors.GREEN}ЛУЧШАЯ{Colors.END}"
            elif percentage > 80:
                color = Colors.GREEN
                rating = f"{Colors.GREEN}ОТЛИЧНО{Colors.END}"
            elif percentage > 60:
                color = Colors.YELLOW
                rating = f"{Colors.YELLOW}ХОРОШО{Colors.END}"
            elif percentage > 40:
                color = Colors.YELLOW
                rating = f"{Colors.YELLOW}СРЕДНЕ{Colors.END}"
            else:
                color = Colors.RED
                rating = f"{Colors.RED}ПЛОХО{Colors.END}"
            
            if ping < float('inf'):
                if ping < 50:
                    ping_color = Colors.GREEN
                elif ping < 100:
                    ping_color = Colors.YELLOW
                else:
                    ping_color = Colors.RED
                ping_display = f"{ping_color}{ping:>10.1f}ms{Colors.END}"
            else:
                ping_display = f"{Colors.RED}{'N/A':>10}{Colors.END}"
            
            strategy_display = strategy[:28] + "..." if len(strategy) > 28 else strategy
            row = f"{color}{idx:<3}{Colors.END} " \
                  f"{color}{strategy_display:<30}{Colors.END} " \
                  f"{color}{available:>10}{Colors.END} " \
                  f"{color}{percentage:>7.1f}%{Colors.END} " \
                  f"{ping_display:>12} " \
                  f"{rating:<10}"
            
            log_message(row, to_file=True)
        
        log_message(separator, to_file=True)
        
        # Лучшая стратегия
        if best_strategy:
            if total_domains > 0:
                best_percentage = (best_available / total_domains * 100)
            else:
                best_percentage = 0
            
            ping_display = f"{best_ping:.1f}ms" if best_ping < float('inf') else "N/A"
            
            log_message(f"\n{Colors.BOLD}{Colors.GREEN}✓ ЛУЧШАЯ СТРАТЕГИЯ:{Colors.END} {Colors.BOLD}{best_strategy}{Colors.END}", to_file=True)
            log_message(f"{Colors.GREEN}  Доступно: {best_available}/{total_domains} ({best_percentage:.1f}%) доменов, задержка: {ping_display}{Colors.END}", to_file=True)
            
            # Применяем лучшую стратегию
            if apply_best and best_strategy in configs_to_test:
                log_message(f"\n{Colors.YELLOW}Применяю лучшую стратегию...{Colors.END}", to_file=True)
                best_config_path = configs_to_test[best_strategy]
                if apply_config(best_config_path, fwtype):
                    log_message(f"{Colors.GREEN}✓ Лучшая стратегия успешно применена{Colors.END}", to_file=True)
                else:
                    log_message(f"{Colors.RED}✗ Не удалось применить лучшую стратегию{Colors.END}", to_file=True)
    
    if output_file:
        output_file.close()
        print(f"\n{Colors.BOLD}Полный лог сохранен в: {log_filename}{Colors.END}")
        print(f"{Colors.YELLOW}Внимание: Файл содержит ANSI цвета. Для правильного отображения используйте:{Colors.END}")
        print(f"{Colors.CYAN}  cat {log_filename}{Colors.END}")
        print(f"{Colors.CYAN}  или{Colors.END}")
        print(f"{Colors.CYAN}  less -R {log_filename}{Colors.END}")
    
    clear_status()
    return best_strategy if stats else None

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Тестирование стратегий Zapret")
    parser.add_argument("configs_json", help="JSON файл с конфигурациями")
    parser.add_argument("hostlist", help="Файл хостлиста")
    parser.add_argument("--threads", "-t", type=int, default=10, 
                       help="Количество потоков для тестирования (по умолчанию: 10)")
    parser.add_argument("--no-apply", action="store_true", 
                       help="Не применять лучшую стратегию по завершении")
    
    args = parser.parse_args()
    
    # Загружаем конфигурации
    try:
        with open(args.configs_json, 'r') as f:
            configs = json.load(f)
    except Exception as e:
        print(f"{Colors.RED}Ошибка загрузки JSON файла: {e}{Colors.END}")
        sys.exit(1)
    
    main_test(
        configs, 
        args.hostlist, 
        threads=args.threads,
        apply_best=not args.no_apply
    )
