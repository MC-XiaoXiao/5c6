"""Human-readable workflow progress; stdout stays available for CLI data."""
from contextlib import contextmanager
from datetime import datetime
import shlex
from pathlib import Path
import subprocess
import sys
import threading
import time


def log(message, level='INFO'):
    print(f'[{datetime.now().astimezone().isoformat(timespec="seconds")}] '
          f'[{level}] {message}', file=sys.stderr, flush=True)


@contextmanager
def stage(label, interval=15):
    """Identify failures and keep long, otherwise silent operations visible."""
    started = time.monotonic()
    stopped = threading.Event()
    log(label + ' — starting', 'STEP')

    def heartbeat():
        while not stopped.wait(interval):
            log(f'{label} — still running ({time.monotonic() - started:.0f}s)', 'WAIT')

    worker = threading.Thread(target=heartbeat, daemon=True)
    worker.start()
    try:
        yield
    except BaseException as error:
        stopped.set()
        worker.join()
        # Exception text can contain key-bearing child arguments. Let the caller
        # choose safe diagnostics; this layer records only the phase and type.
        log(f'{label} — failed after {time.monotonic() - started:.1f}s '
            f'({type(error).__name__})', 'FAIL')
        raise
    else:
        stopped.set()
        worker.join()
        log(f'{label} — completed in {time.monotonic() - started:.1f}s', 'DONE')


def commands(rows):
    """Show usable preview commands without dumping nested reports."""
    for row in rows:
        log('Preview: ' + shlex.join(map(str, row)))


def error_detail(error, include_output=True):
    """Avoid printing complete subprocess arguments (which may hold keys)."""
    if isinstance(error, subprocess.SubprocessError):
        cmd = getattr(error, 'cmd', [])
        name = Path(cmd[0]).name if isinstance(cmd, (list, tuple)) and cmd else 'external tool'
        if isinstance(error, subprocess.TimeoutExpired):
            log(f'{name} timed out after {error.timeout}s', 'ERROR')
        else:
            log(f'{name} failed (exit code {getattr(error, "returncode", "unknown")})', 'ERROR')
        if include_output:
            for label in ('stderr', 'stdout'):
                output = getattr(error, label, None)
                if output:
                    detail = output.decode(errors='replace') if isinstance(output, bytes) else output
                    log(label + ' (last 4096 characters): ' + detail[-4096:].strip(), 'ERROR')
    else:
        log(f'{type(error).__name__}: {error}', 'ERROR')
