#!/usr/bin/env python3
"""Read connected USB identity without changing device state."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import socket
import struct
import plistlib
from hosttools import tool_env


def recovery_usb_count():
    """Count physical Apple recovery/DFU devices before querying one identity."""
    products = {0x1227, 0x1280, 0x1281, 0x1282, 0x1283}
    if sys.platform == 'linux':
        directory = Path('/sys/bus/usb/devices')
        if not directory.is_dir():
            raise ValueError('USB device inventory is unavailable')
        count = 0
        for node in directory.iterdir():
            if not (node / 'idVendor').is_file():
                continue
            try:
                vendor = int((node / 'idVendor').read_text().strip(), 16)
                product = int((node / 'idProduct').read_text().strip(), 16)
            except FileNotFoundError:
                continue  # A device disconnected during this read-only inventory.
            if vendor == 0x05ac and product in products:
                count += 1
        return count
    if sys.platform == 'darwin':
        result = subprocess.run(['/usr/sbin/ioreg', '-p', 'IOUSB', '-a'], capture_output=True, timeout=15, check=True)
        def count_nodes(value):
            if isinstance(value, list):
                return sum(count_nodes(row) for row in value)
            if isinstance(value, dict):
                found = int(value.get('idVendor') == 0x05ac and value.get('idProduct') in products)
                return found + sum(count_nodes(row) for row in value.values() if isinstance(row, (list, dict)))
            return 0
        return count_nodes(plistlib.loads(result.stdout))
    raise ValueError('Device detection requires macOS or Linux')


def normal_udids():
    """List USB devices via the usbmuxd protocol without a project-specific helper."""
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(5)
            connection.connect('/var/run/usbmuxd')
            request = plistlib.dumps({'MessageType': 'ListDevices', 'ClientVersionString': 'Project5C', 'ProgName': 'Project5C', 'kLibUSBMuxVersion': 3})
            connection.sendall(struct.pack('<IIII', len(request) + 16, 1, 8, 1) + request)
            def exact(size):
                result = bytearray()
                while len(result) < size:
                    block = connection.recv(size - len(result))
                    if not block:
                        raise ValueError('Truncated usbmuxd response')
                    result.extend(block)
                return bytes(result)
            size, version, message, tag = struct.unpack('<IIII', exact(16))
            if not 16 <= size <= 1024 * 1024 or (version, message, tag) != (1, 8, 1):
                raise ValueError('Invalid usbmuxd response')
            reply = plistlib.loads(exact(size - 16))
            return [row['Properties']['SerialNumber'] for row in reply.get('DeviceList', []) if row['Properties'].get('ConnectionType', 'USB') == 'USB']
    except (FileNotFoundError, ConnectionRefusedError):
        return []


def detect(directory):
    directory = Path(directory).resolve()
    env = tool_env(directory)
    def binary(name):
        local = directory / name
        return str(local) if local.is_file() and os.access(local, os.X_OK) else shutil.which(name)
    def query(command):
        result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
        return result.stdout.strip() if result.returncode == 0 else ''
    physical_recovery = recovery_usb_count()
    if physical_recovery > 1:
        raise ValueError('Multiple recovery/DFU devices detected. Connect only the target iPhone 5c.')
    devices = {}
    identified_recovery = False
    recovery = binary('irecovery')
    if recovery:
        fields = dict(re.findall(r'^([A-Z]+):\s*(.+)$', query([recovery, '-q']), re.M))
        if fields.get('ECID'):
            identified_recovery = True
            chip = int(fields.get('CPID', '0'), 0)
            board = int(fields.get('BDID', '0'), 0)
            model = {10: 'iPhone5,3', 14: 'iPhone5,4'}.get(board) if chip == 0x8950 else None
            devices[int(fields['ECID'], 0)] = (model, fields.get('MODE', 'Recovery'))
    device_id, info = binary('idevice_id'), binary('ideviceinfo')
    if info:
        udids = query([device_id, '-l']).splitlines() if device_id else normal_udids()
        for udid in udids:
            model = query([info, '-u', udid, '-k', 'ProductType'])
            ecid = query([info, '-u', udid, '-k', 'UniqueChipID'])
            if not model or not ecid:
                raise ValueError('Connected device identity is unavailable. Unlock the device and trust this computer, or enter DFU.')
            devices[int(ecid, 0)] = (model, 'Normal')
    if physical_recovery and not identified_recovery:
        raise ValueError('A recovery/DFU device is connected but its identity is unavailable')
    if not recovery and not info:
        raise ValueError('Device detection tools are missing. Supply irecovery for DFU/Recovery or idevice_id and ideviceinfo for normal mode.')
    if not devices:
        raise ValueError('No accessible device detected. Connect an iPhone 5c and enter DFU, or unlock and trust this computer.')
    if len(devices) != 1:
        raise ValueError('Multiple devices detected. Connect only the target iPhone 5c.')
    ecid, (model, mode) = next(iter(devices.items()))
    if model not in ['iPhone5,3', 'iPhone5,4'] or ecid <= 0:
        raise ValueError('The connected device is not a supported iPhone 5c.')
    return model, hex(ecid), mode


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tools-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        print('\t'.join(detect(args.tools_dir)))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Device detection failed: ' + str(error), file=sys.stderr)
        sys.exit(2)
