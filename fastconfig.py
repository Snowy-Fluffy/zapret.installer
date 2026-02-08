#!/usr/bin/env python3
"""
Zapret Strategy Tester - Accelerated

"""

import sys
import os
import time
import subprocess
import json
import argparse
import re
import shutil
import logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Optional, Tuple, Any, Callable
from enum import Enum

# --- Constants ---
ZAPRET_CONFIG_PATH = Path("/opt/zapret/config")
DEFAULT_TIMEOUT = 3
DEFAULT_THREADS = 1000

# --- Models / Data Structures ---

@dataclass
class NetworkMetric:
    """Holds the result of a single network test."""
    raw_value: Any  # float for ping, int for http code, etc.
    formatted: str
    is_success: bool
    details: str = ""

@dataclass
class DomainResult:
    """Holds the testing results for a specific domain."""
    domain: str
    ping: NetworkMetric
    http: NetworkMetric
    tls12: NetworkMetric
    tls13: NetworkMetric
    is_available: bool

@dataclass
class StrategyStats:
    """Aggregated statistics for a specific strategy."""
    name: str
    config_path: str
    total_checked: int = 0
    available_count: int = 0
    google_latency: float = float('inf')
    domain_results: List[DomainResult] = field(default_factory=list)

    @property
    def success_rate(self) -> float:
        if self.total_checked == 0:
            return 0.0
        return (self.available_count / self.total_checked) * 100

# --- UI & Presentation Layer ---

class Colors:
    """ANSI Color codes."""
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    END = '\033[0m'
    RESET_LINE = '\r\033[K'

class ConsoleRenderer:
    """Handles all user output, logging, and formatting."""

    def __init__(self, log_path: Path):
        self.log_path = log_path
        self._setup_logging()

    def _setup_logging(self):
        """Sets up file logging."""
        try:
            # We use a custom raw logger to handle the specific formatting requirements
            # of the original script (writing ANSI codes to file as per request)
            self.log_file = open(self.log_path, 'w', encoding='utf-8')
            self.log_file.write('\ufeff')  # BOM
        except IOError as e:
            print(f"{Colors.RED}Failed to create log file: {e}{Colors.END}")
            self.log_file = None

    def log(self, message: str, color: str = "", end: str = "\n", to_file: bool = True):
        """Print to console and write to file."""
        # Console output
        sys.stdout.write(f"{color}{message}{Colors.END}{end}")
        sys.stdout.flush()

        # File output (strip colors if needed, but original req kept them)
        if self.log_file and to_file:
            self.log_file.write(f"{message}{end}")
            self.log_file.flush()

    def close(self):
        if self.log_file:
            self.log_file.close()

    def print_banner(self, config_count: int, threads: int, hostlist: str):
        self.log(f"{Colors.BOLD}{Colors.CYAN}Zapret Strategy Tester{Colors.END}")
        self.log(f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", Colors.WHITE)
        self.log(f"Log: {self.log_path}", Colors.WHITE)
        self.log(f"Threads: {threads}", Colors.WHITE)
        self.log(f"Hostlist: {hostlist}", Colors.WHITE)
        self.log(f"Strategies: {config_count}", Colors.WHITE)
        self.log(f"{Colors.CYAN}{'=' * 50}{Colors.END}")

    def update_status(self, strategy: str, phase: str, domain: str, progress: str):
        """Updates the dynamic status line."""
        # Truncate for display
        strat_disp = (strategy[:15] + '..') if len(strategy) > 15 else strategy
        dom_disp = (domain[:30] + '..') if len(domain) > 30 else domain
        
        status_line = (
            f"{Colors.RESET_LINE}"
            f"{Colors.CYAN}strategy:{Colors.END} {strat_disp:<17} | "
            f"{Colors.CYAN}status:{Colors.END} {phase:<12} "
            f"{dom_disp:<32} | "
            f"{Colors.CYAN}progress:{Colors.END} {progress:<10}"
        )
        sys.stderr.write(status_line)
        sys.stderr.flush()

    def clear_status(self):
        sys.stderr.write(Colors.RESET_LINE)
        sys.stderr.flush()

    def _colorize_metric(self, metric: NetworkMetric) -> str:
        if not metric.is_success:
            return f"{Colors.RED}{metric.formatted}{Colors.END}"
        
        # Ping Logic
        if "ms" in metric.formatted:
            val = metric.raw_value
            if val < 50: return f"{Colors.GREEN}{metric.formatted}{Colors.END}"
            if val < 200: return f"{Colors.YELLOW}{metric.formatted}{Colors.END}"
            return f"{Colors.RED}{metric.formatted}{Colors.END}"
        
        # HTTP/TLS Logic
        if metric.is_success:
            return f"{Colors.GREEN}{metric.formatted}{Colors.END}"
        
        return f"{Colors.WHITE}{metric.formatted}{Colors.END}"

    def show_strategy_results(self, stats: StrategyStats):
        self.clear_status()
        
        sep = f"{Colors.CYAN}{'='*90}{Colors.END}"
        self.log(f"\n{sep}")
        self.log(f"{Colors.BOLD}{Colors.CYAN}STRATEGY RESULTS: {stats.name}{Colors.END}")
        
        # Show Baseline
        if stats.google_latency < float('inf'):
            p_color = Colors.GREEN if stats.google_latency < 50 else Colors.YELLOW
            self.log(f"Baseline (google.com): {p_color}{stats.google_latency:.1f}ms{Colors.END}")
        
        header = f"{Colors.BOLD}{Colors.WHITE}{'Domain/IP':<40} {'Ping':<10} {'HTTP':<10} {'TLS1.2':<10} {'TLS1.3':<10}{Colors.END}"
        self.log(sep)
        self.log(header)
        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}")

        # Limit output to prevent spamming
        display_items = stats.domain_results
        if len(display_items) > 30:
            display_items = display_items[:20] + display_items[-10:]
            skipped = True
        else:
            skipped = False

        for i, res in enumerate(display_items):
            if skipped and i == 20:
                self.log(f"{Colors.YELLOW}... {len(stats.domain_results) - 30} hidden ...{Colors.END}")
            
            d_str = (res.domain[:38] + "..") if len(res.domain) > 38 else res.domain
            row = (
                f"{Colors.WHITE}{d_str:<40}{Colors.END} "
                f"{self._colorize_metric(res.ping):<10} "
                f"{self._colorize_metric(res.http):<10} "
                f"{self._colorize_metric(res.tls12):<10} "
                f"{self._colorize_metric(res.tls13):<10}"
            )
            self.log(row)

        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}")
        
        # Summary
        pct = stats.success_rate
        icon = "✓" if pct > 70 else ("⚠" if pct > 30 else "✗")
        color = Colors.GREEN if pct > 70 else (Colors.YELLOW if pct > 30 else Colors.RED)
        
        self.log(
            f"{color}{icon} {Colors.BOLD}Available:{Colors.END} "
            f"{color}{stats.available_count}/{stats.total_checked}{Colors.END} "
            f"{Colors.BOLD}({pct:.1f}%){Colors.END}"
        )
        self.log(f"{Colors.CYAN}{'='*90}{Colors.END}\n")

    def show_final_summary(self, all_stats: List[StrategyStats]):
        self.clear_status()
        self.log(f"\n{Colors.CYAN}{'='*90}{Colors.END}")
        self.log(f"{Colors.BOLD}{Colors.CYAN}FINAL SUMMARY{Colors.END}")
        self.log(f"{Colors.CYAN}{'='*90}{Colors.END}")
        
        header = f"{Colors.BOLD}{Colors.WHITE}{'#':<3} {'Strategy':<30} {'Avail':>10} {'%':>8} {'Ping':>12} {'Rating':<10}{Colors.END}"
        self.log(header)
        self.log(f"{Colors.CYAN}{'-'*90}{Colors.END}")

        for idx, stat in enumerate(all_stats, 1):
            pct = stat.success_rate
            
            # Determine Color/Rating
            if idx == 1:
                color = Colors.GREEN
                rating = "BEST"
            elif pct > 80:
                color = Colors.GREEN
                rating = "EXCELLENT"
            elif pct > 60:
                color = Colors.YELLOW
                rating = "GOOD"
            elif pct > 40:
                color = Colors.YELLOW
                rating = "AVERAGE"
            else:
                color = Colors.RED
                rating = "POOR"

            ping_str = f"{stat.google_latency:.1f}ms" if stat.google_latency < float('inf') else "N/A"
            strat_name = (stat.name[:28] + "..") if len(stat.name) > 28 else stat.name
            
            row = (
                f"{color}{idx:<3}{Colors.END} "
                f"{color}{strat_name:<30}{Colors.END} "
                f"{color}{stat.available_count:>10}{Colors.END} "
                f"{color}{pct:>7.1f}%{Colors.END} "
                f"{color}{ping_str:>12}{Colors.END} "
                f"{color}{rating:<10}{Colors.END}"
            )
            self.log(row)

# --- Logic Layer: System Operations ---

class SystemController:
    """Handles OS-level interactions (firewall, services, files)."""

    @staticmethod
    def detect_fw_type() -> str:
        try:
            res = subprocess.run(["iptables", "--version"], capture_output=True, text=True)
            if "legacy" in res.stdout:
                return "iptables"
        except FileNotFoundError:
            pass
        return "nftables" # Default to nftables for modern systems

    @staticmethod
    def apply_config(config_source: str, fw_type: str) -> bool:
        """Copies config and restarts Zapret."""
        try:
            shutil.copy(config_source, ZAPRET_CONFIG_PATH)
            
            # Inject FWTYPE if needed
            with open(ZAPRET_CONFIG_PATH, 'r') as f:
                lines = f.readlines()
            
            with open(ZAPRET_CONFIG_PATH, 'w') as f:
                for line in lines:
                    if line.startswith("FWTYPE="):
                        f.write(f"FWTYPE={fw_type}\n")
                    else:
                        f.write(line)
            
            subprocess.run(
                ["systemctl", "restart", "zapret"],
                check=True, capture_output=True, text=True
            )
            time.sleep(2) # Wait for service to settle
            return True
        except Exception:
            return False

# --- Logic Layer: Network Testing ---

class NetworkTester:
    """Performs raw network operations."""

    @staticmethod
    def ping(host: str, timeout: int = 2) -> Tuple[float, bool]:
        """Returns (ms, success)."""
        try:
            cmd = ["ping", "-c", "2", "-W", str(timeout), host]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout+1)
            
            if res.returncode == 0:
                match = re.search(r"min/avg/max/mdev = [\d\.]+/([\d\.]+)/", res.stdout)
                if match:
                    return float(match.group(1)), True
            return float('inf'), False
        except subprocess.TimeoutExpired:
            return float('inf'), False
        except Exception:
            return float('inf'), False

    @staticmethod
    def check_http(url: str, timeout: int = 5) -> Tuple[str, bool]:
        """Returns (http_code_str, success)."""
        try:
            cmd = [
                "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "-m", str(timeout), url
            ]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout+1)
            if res.returncode == 0 and res.stdout.isdigit():
                return res.stdout, True
            return "FAIL", False
        except Exception:
            return "FAIL", False

    @staticmethod
    def check_tls(domain: str, version: str, timeout: int = 5) -> Tuple[str, bool]:
        """Returns (result_string, success)."""
        tls_flag = f"--{version}"
        url = f"https://{domain}"
        try:
            cmd = [
                "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                "-m", str(timeout), tls_flag, url
            ]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout+1)
            
            # Check logic adapted from original script
            if res.returncode == 0 and res.stdout.isdigit():
                return f"{version.upper()}:{res.stdout}", True
            return "FAIL", False
        except Exception:
            return "FAIL", False

    @classmethod
    def analyze_domain(cls, domain: str, timeout: int) -> DomainResult:
        """Runs a full battery of tests on a domain."""
        domain = domain.strip()
        
        # 1. Ping
        ping_ms, ping_ok = cls.ping(domain, timeout=2)
        ping_metric = NetworkMetric(
            ping_ms, f"{ping_ms:.1f}ms" if ping_ok else "FAIL", ping_ok
        )

        # Optimization: If ping fails (and it's an IP), mostly likely dead
        is_ip = bool(re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', domain))
        
        if not ping_ok and is_ip:
            # Short circuit for dead IPs
            fail = NetworkMetric(0, "FAIL", False)
            return DomainResult(domain, ping_metric, fail, fail, fail, False)

        if is_ip:
            # IPs don't need HTTP/TLS checks usually in this context
            na = NetworkMetric(0, "N/A", True) # Treated as neutral/pass
            return DomainResult(domain, ping_metric, na, na, na, True)

        # 2. HTTP
        http_code, http_ok = cls.check_http(f"http://{domain}", timeout)
        http_metric = NetworkMetric(
            int(http_code) if http_code.isdigit() else 0,
            f"HTTP:{http_code}",
            http_ok
        )

        # 3. TLS 1.2
        t12_res, t12_ok = cls.check_tls(domain, "tlsv1.2", timeout)
        t12_metric = NetworkMetric(0, t12_res, t12_ok and ("2" in t12_res or "3" in t12_res)) # loose check on 2xx/3xx

        # 4. TLS 1.3
        t13_res, t13_ok = cls.check_tls(domain, "tlsv1.3", timeout)
        t13_metric = NetworkMetric(0, t13_res, t13_ok and ("2" in t13_res or "3" in t13_res))

        # Determine overall availability (Logic: if any TLS works)
        is_available = t12_metric.is_success or t13_metric.is_success

        return DomainResult(domain, ping_metric, http_metric, t12_metric, t13_metric, is_available)

# --- Orchestration ---

class TestManager:
    """Orchestrates the testing process."""
    
    def __init__(self, ui: ConsoleRenderer, threads: int = 10):
        self.ui = ui
        self.threads = threads
        self.fw_type = SystemController.detect_fw_type()

    def load_hostlist(self, path: str) -> List[str]:
        try:
            with open(path, 'r') as f:
                return [line.strip() for line in f if line.strip() and not line.startswith('#')]
        except Exception as e:
            self.ui.log(f"{Colors.RED}Error reading hostlist: {e}{Colors.END}")
            return []

    def run_strategy(self, name: str, config_path: str, hosts: List[str]) -> StrategyStats:
        stats = StrategyStats(name=name, config_path=config_path, total_checked=len(hosts))
        
        # 1. Apply Config
        self.ui.log(f"Applying strategy: {Colors.BOLD}{name}{Colors.END}...", to_file=False)
        if not SystemController.apply_config(config_path, self.fw_type):
            self.ui.log(f"{Colors.RED}Failed to apply configuration.{Colors.END}")
            return stats

        # 2. Baseline Latency
        base_ms, base_ok = NetworkTester.ping("google.com", timeout=2)
        stats.google_latency = base_ms if base_ok else float('inf')

        # 3. Parallel Test
        completed = 0
        with ThreadPoolExecutor(max_workers=self.threads) as executor:
            future_to_domain = {
                executor.submit(NetworkTester.analyze_domain, domain, DEFAULT_TIMEOUT): domain 
                for domain in hosts
            }

            for future in as_completed(future_to_domain):
                domain = future_to_domain[future]
                completed += 1
                try:
                    result = future.result()
                    stats.domain_results.append(result)
                    if result.is_available:
                        stats.available_count += 1
                except Exception as e:
                    # Log internal error but don't crash
                    pass
                
                # Update UI
                pct = int((completed / len(hosts)) * 100)
                self.ui.update_status(name, "testing", domain, f"{pct}%")

        self.ui.show_strategy_results(stats)
        return stats

    def run_all(self, configs: Dict[str, str], hostlist_path: str, apply_best: bool = True):
        hosts = self.load_hostlist(hostlist_path)
        if not hosts:
            self.ui.log("No hosts to test.")
            return

        self.ui.print_banner(len(configs), self.threads, hostlist_path)
        self.ui.log(f"Firewall detected: {Colors.BOLD}{self.fw_type}{Colors.END}")

        all_stats: List[StrategyStats] = []

        try:
            for name, path in configs.items():
                stats = self.run_strategy(name, path, hosts)
                all_stats.append(stats)
        except KeyboardInterrupt:
            self.ui.log(f"\n{Colors.RED}Interrupted by user.{Colors.END}")
        
        # Sort by availability (desc), then latency (asc)
        sorted_stats = sorted(
            all_stats, 
            key=lambda x: (-x.available_count, x.google_latency)
        )

        self.ui.show_final_summary(sorted_stats)

        if apply_best and sorted_stats:
            best = sorted_stats[0]
            self.ui.log(f"\n{Colors.YELLOW}Applying best strategy: {best.name}{Colors.END}")
            if SystemController.apply_config(best.config_path, self.fw_type):
                self.ui.log(f"{Colors.GREEN}✓ Successfully applied {best.name}{Colors.END}")
            else:
                self.ui.log(f"{Colors.RED}✗ Failed to apply best strategy{Colors.END}")

# --- Entry Point ---

def main():
    parser = argparse.ArgumentParser(description="Автоподбор стратегий Zapret")
    parser.add_argument("configs_json", help="Path to JSON file with strategies")
    parser.add_argument("hostlist", help="Path to hostlist file")
    parser.add_argument("--threads", "-t", type=int, default=DEFAULT_THREADS)
    parser.add_argument("--no-apply", action="store_true", help="Do not apply best strategy at end")
    
    args = parser.parse_args()

    # Generate log filename
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_path = Path(f"/tmp/zapret_test_{timestamp}.log")

    # Initialize UI
    ui = ConsoleRenderer(log_path)
    
    # Load Configs
    try:
        with open(args.configs_json, 'r') as f:
            configs = json.load(f)
    except Exception as e:
        ui.log(f"{Colors.RED}Failed to load config JSON: {e}{Colors.END}")
        sys.exit(1)

    # Check Root
    if os.geteuid() != 0:
        ui.log(f"{Colors.RED}Error: This script must be run as root.{Colors.END}")
        sys.exit(1)

    # Run
    manager = TestManager(ui, args.threads)
    manager.run_all(configs, args.hostlist, apply_best=not args.no_apply)
    
    ui.close()
    print(f"\nFull log saved to: {log_path}")

if __name__ == "__main__":
    main()