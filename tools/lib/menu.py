#!/usr/bin/env python3
"""Small arrow-key selector with a numbered fallback for plain terminals."""
import argparse
import os
import sys
import termios
import tty


def choose(title, options, default=0):
    if not 0 <= default < len(options):
        raise ValueError('Invalid menu default')
    out = sys.stderr
    print('\n' + title, file=out)
    if os.environ.get('TERM', 'dumb') == 'dumb' or os.environ.get('TOOL_MENU') == 'numbered':
        for index, option in enumerate(options, 1):
            print(f'  {index}. {option}', file=out)
        while True:
            print(f'Choose [{default + 1}]: ', end='', file=out, flush=True)
            line = sys.stdin.readline()
            if not line:
                raise EOFError
            value = line.strip() or str(default + 1)
            if value.isdigit() and 1 <= int(value) <= len(options):
                return int(value) - 1
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    selected = default
    print('Use ↑/↓ and Enter (or 1–9); Esc cancels.', file=out)
    try:
        tty.setcbreak(fd)
        out.write('\033[?25l')
        while True:
            for index, option in enumerate(options):
                label = f' {index + 1}. {option} '
                out.write('\033[2K' + (' → \033[7m' + label + '\033[0m' if index == selected else '   ' + label) + '\n')
            out.flush()
            key = os.read(fd, 1)
            if key in (b'\r', b'\n'):
                return selected
            if key == b'\x1b':
                import select
                sequence = b''
                for _ in range(2):
                    if select.select([fd], [], [], 0.15)[0]:
                        sequence += os.read(fd, 1)
                if sequence in (b'[A', b'OA'):
                    selected = (selected - 1) % len(options)
                elif sequence in (b'[B', b'OB'):
                    selected = (selected + 1) % len(options)
                elif not sequence:
                    raise EOFError
            elif key in (b'\x03', b'\x04', b''):
                raise EOFError
            elif key in b'123456789' and int(key) <= len(options):
                return int(key) - 1
            out.write(f'\033[{len(options)}A')
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        out.write('\033[0m\033[?25h')
        out.flush()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--default', type=int, default=0)
    parser.add_argument('title')
    parser.add_argument('options', nargs='+')
    args = parser.parse_args()
    try:
        print(choose(args.title, args.options, args.default))
    except (EOFError, KeyboardInterrupt):
        sys.exit(130)
