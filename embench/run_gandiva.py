#!/usr/bin/env python3
import argparse
import subprocess
import re
import os
import sys
import atexit
import math

# pyrefly: ignore [missing-import]
from embench_core import log

cycle_counts = []

def print_geomean():
    if cycle_counts:
        prod = math.prod(cycle_counts)
        geomean = int(round(prod ** (1 / len(cycle_counts))))
        print(f"{'Geometric mean':<20} | Cycles: {geomean:>12}")

atexit.register(print_geomean)

def get_target_args(remnant):
    parser = argparse.ArgumentParser(description='Get target specific args')
    parser.add_argument('--objcopy', type=str, default='riscv-none-elf-objcopy', help='Objcopy tool')
    parser.add_argument('--bin2hex', type=str, default='../../sw/bin2hex.py', help='bin2hex script path')
    parser.add_argument('--sim', type=str, default='../../sim/tb_gandiva', help='Path to tb_gandiva')
    return parser.parse_args(remnant)

def decode_results(stdout_str, stderr_str, bench="Unknown"):
    rcstr = re.search(r'RET=(\d+)', stdout_str, re.S | re.M)
    if not rcstr:
        log.debug('Warning: Failed to find return code')
        return None

    cycles_str = re.search(r'CYCLES=(\d+)', stdout_str, re.S | re.M)
    if cycles_str:
        cycles = int(cycles_str.group(1))
        print(f"{bench:<20} | Cycles: {cycles:>12}")
        cycle_counts.append(cycles)
        # 50 MHz simulation clock -> 50,000 cycles per ms
        ms_elapsed = float(cycles) / 50000.0
        return max(ms_elapsed, 0.001)

    log.debug('Warning: Failed to find timing')
    return None

def run_benchmark(bench, path, args):
    try:
        bin_path = path + '.bin'
        hex_path = path + '.hex'
        
        # 1. objcopy ELF to binary
        subprocess.run([args.objcopy, '-O', 'binary', path, bin_path], check=True)
        
        # 2. Convert binary to hex
        subprocess.run([sys.executable, args.bin2hex, bin_path, hex_path], check=True, stdout=subprocess.DEVNULL)
        
        # 3. Run simulation
        res = subprocess.run(
            [args.sim, f'+IMEM={hex_path}'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=50,
        )
        
    except subprocess.TimeoutExpired:
        log.warning(f'Warning: Run of {bench} timed out.')
        return None
    except subprocess.CalledProcessError as e:
        log.warning(f'Warning: Build/Run failed for {bench}: {e}')
        return None
        
    return decode_results(res.stdout.decode('utf-8'), res.stderr.decode('utf-8'), bench)

