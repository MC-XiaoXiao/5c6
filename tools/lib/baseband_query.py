"""Optional normal-mode identity export; default restores use native BasebandData."""
from pathlib import Path
import plistlib
import subprocess

from baseband import query_parameters
from hosttools import tool_env


def normal_query(model, ecid, tools):
    from device import normal_udids
    tools = Path(tools).resolve()
    for udid in normal_udids():
        result = subprocess.run([str(tools / 'ideviceinfo'), '-u', udid, '-x'],
                                capture_output=True, timeout=15, env=tool_env(tools), check=True)
        query = plistlib.loads(result.stdout)
        if query.get('ProductType') == model and query.get('UniqueChipID') == ecid:
            query_parameters(query, model, ecid)
            return query
    raise ValueError('No matching normal-mode device with complete baseband parameters')

