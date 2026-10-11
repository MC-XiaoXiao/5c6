#!/usr/bin/env python3
"""Select source firmware or a workspace using the host desktop's chooser."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def start_directory(initial):
    path = Path(initial).expanduser() if initial else Path.home() / 'Downloads'
    if path.is_file():
        path = path.parent
    return (path if path.is_dir() else Path.home()).resolve()


def dialog(initial='', directory=False, baseband=False):
    folder = str(start_directory(initial)) + os.sep
    title = 'Select workspace folder' if directory else 'Select original iPhone 5 IPSW'
    if baseband: title = 'Select your personalized Mav7 ZIP'
    if sys.platform == 'darwin':
        script = '''on run argv
    try
        set selected to CHOOSER default location (POSIX file (item 1 of argv))
        return POSIX path of selected
    on error number -128
        return ""
    end try
end run
'''
        chooser = 'choose folder with prompt "Select workspace folder"' if directory else 'choose file with prompt "Select original iPhone 5 IPSW" of type {"ipsw"}'
        if baseband: chooser = 'choose file with prompt "Select your personalized Mav7 ZIP" of type {"zip"}'
        return ['osascript', '-', folder], script.replace('CHOOSER', chooser)
    if not sys.platform.startswith('linux'):
        raise ValueError('Native selection supports macOS and Linux.')
    if not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')):
        raise ValueError('No desktop display available. Use --source-ipsw PATH from a terminal.')
    desktop = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
    candidates = ('kdialog', 'zenity') if 'kde' in desktop else ('zenity', 'kdialog')
    for name in candidates:
        binary = shutil.which(name)
        if not binary:
            continue
        if name == 'kdialog':
            if directory:
                return [binary, '--title', title, '--getexistingdirectory', folder], None
            return [binary, '--title', title, '--getopenfilename', folder,
                    '*.zip *.ZIP|Personalized Mav7 firmware (*.zip)' if baseband else '*.ipsw *.IPSW|iOS firmware (*.ipsw)'], None
        if directory:
            return [binary, '--file-selection', '--directory', '--title=' + title,
                    '--filename=' + folder], None
        return [binary, '--file-selection', '--title=' + title,
                '--filename=' + folder,
                '--file-filter=Personalized Mav7 firmware | *.zip *.ZIP' if baseband else '--file-filter=iOS firmware | *.ipsw *.IPSW'], None
    raise ValueError('Install zenity or kdialog for the file chooser, or use --source-ipsw PATH.')


def workspace_path(value):
    path = Path(value).expanduser().resolve()
    if path.exists() and not path.is_dir():
        raise ValueError('Workspace path must be a directory.')
    parent = path.parent
    while not parent.exists():
        parent = parent.parent
    if not parent.is_dir():
        raise ValueError('Workspace parent must be a directory.')
    return path


def choose(initial='', directory=False, baseband=False):
    command, script = dialog(initial, directory, True) if baseband else dialog(initial, directory)
    with subprocess.Popen(command, stdin=subprocess.PIPE if script else subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        try:
            output, errors = process.communicate(script)
        except KeyboardInterrupt:
            process.terminate()
            process.communicate()
            raise
    if process.returncode == 1 or (process.returncode == 0 and not output.rstrip('\r\n')):
        return None
    if process.returncode != 0:
        raise ValueError(errors.strip() or 'The file chooser failed to open.')
    path = Path(output.rstrip('\r\n')).expanduser()
    if directory:
        if not path.is_dir():
            raise ValueError('Select an existing workspace folder.')
        return workspace_path(path)
    if not path.is_file() or path.suffix.lower() != ('.zip' if baseband else '.ipsw'):
        raise ValueError('Select an existing personalized Mav7 ZIP file.' if baseband else 'Select an existing IPSW file.')
    return path.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('initial', nargs='?', default='')
    parser.add_argument('--directory', action='store_true')
    parser.add_argument('--baseband', action='store_true')
    parser.add_argument('--path', help='Validate a manually entered workspace path; new directories are allowed')
    args = parser.parse_args()
    if args.baseband and args.directory:parser.error('--baseband cannot be combined with --directory')
    # Let the shell menu prompt for a path only when no desktop is available.
    headless = (sys.platform.startswith('linux') and not (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY'))) or (sys.platform == 'darwin' and bool(os.environ.get('SSH_CONNECTION') or os.environ.get('SSH_TTY')))
    if args.path is None and headless:
        return 3
    try:
        if args.path is not None:
            if not args.directory:
                raise ValueError('--path requires --directory')
            path = workspace_path(args.path)
        else:
            path = choose(args.initial, args.directory, True) if args.baseband else choose(args.initial, args.directory)
        if path is None:
            return 130
        print(path)
        return 0
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError) as error:
        print('File selection: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
