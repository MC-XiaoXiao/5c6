#!/usr/bin/env python3
"""Unified N48/N49 feature builds, restore planning and tethered boot."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from progress import log, stage, commands as preview_commands, error_detail

PACKAGE=Path(__file__).resolve().parents[2]
ROOT=PACKAGE/'patches'
PORTABLE=ROOT
from integrity import declaration, checked
class PatchError(RuntimeError):pass

def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
def json_read(path):return json.loads(Path(path).read_text())
def json_write(path,value):Path(path).write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')
def relative(root,name):
    p=Path(name)
    if p.is_absolute() or '..' in p.parts:raise PatchError('unsafe relative path: '+name)
    target=Path(root)/p
    if not target.resolve().is_relative_to(Path(root).resolve()):raise PatchError('path escapes root: '+name)
    if target.is_symlink():raise PatchError('symlink target refused: '+name)
    return target

def registry():
    from features import feature_catalog, load_spec
    config = declaration(PORTABLE/'catalog.py', 'PROFILES')
    inputs = declaration(PORTABLE/'catalog.py', 'INPUTS')
    recipes = []
    for ident, row in feature_catalog(PORTABLE)['recipes'].items():
        spec = load_spec(PORTABLE, ident)
        recipes.append({'id': ident, 'inputs': [spec['input']] if spec.get('input') else [],
                        'destination': spec['destination'], 'mode': spec['mode']})
    return {'schema': 1, 'inputs': {k: {'filename': k, **v} for k, v in inputs.items()},
            'recipes': recipes, 'target': {'ProductType': 'iPhone5,4', 'HardwareModel': 'N49AP',
                                         'ProductVersion': '6.1.3', 'ProductBuildVersion': '10B329'},
            'profiles': {name: {'recipes': ids, 'status': 'See VALIDATION.md'} for name, ids in config.items()},
            'optional_groups': declaration(PORTABLE/'catalog.py', 'EXTRAS')}

def choose(m,profile,extras='',only=''):
    items={v['id']:v for v in m['recipes']}
    if only:active=only.split(',')
    else:
        if profile not in m['profiles']:raise PatchError('unknown profile')
        active=list(m['profiles'][profile]['recipes'])
        for group in filter(None,extras.split(',')):
            if group not in m['optional_groups']:raise PatchError('unknown extra: '+group)
            active+=m['optional_groups'][group]
    active=list(dict.fromkeys(active));order=[];busy=set()
    def visit(ident):
        if ident not in items:raise PatchError('unknown patch: '+ident)
        if ident in order:return
        if ident in busy:raise PatchError('dependency cycle')
        busy.add(ident)
        for inp in items[ident]['inputs']:
            producer=m['inputs'][inp].get('produced_by')
            if producer:visit(producer)
        busy.remove(ident);order.append(ident)
    for ident in active:visit(ident)
    dest=[items[x]['destination'] for x in active]
    if len(set(dest))!=len(dest):raise PatchError('selected patches have conflicting output destinations')
    required=sorted({i for ident in order for i in items[ident]['inputs'] if not m['inputs'][i].get('produced_by')})
    return active,order,required

def verify_registry():
    from features import verify_catalog
    return {'passed': True, 'models': verify_catalog(sys.modules[__name__])}


def build(inputs,dest,profile,extras='',only='',match='features',
          model='iPhone5,4',donor_inputs=None,tools=None,keys_file=None):
    if match != 'features':
        raise PatchError('Only the unified feature builder is supported')
    from features import feature_build
    return feature_build(sys.modules[__name__],inputs,dest,profile,extras,only,
                         model=model,donor_inputs=donor_inputs,tools=tools,keys_file=keys_file)

def verify_bundle(bundle,boot_only=False):
    bundle=Path(bundle).resolve();report=json_read(bundle/'build.json')
    m=None if boot_only else registry()
    feature=report.get('matching')=='binary-features'
    if not feature and not boot_only and report['target']!=m['target']:raise PatchError('bundle target differs from the patch registry')
    if feature:
        from targets import bundle_target
        target=bundle_target(report)
        if not boot_only and target['HardwareModel']=='N48AP':
            from features import feature_catalog
            selected,_,_=choose(m,report['profile'],','.join(report.get('extras',[])))
            if set(selected)!={row['id'] for row in report['files']} or not set(selected).issubset(feature_catalog(PORTABLE,'iPhone5,3')['recipes']):
                raise PatchError('N48 artifact set differs from the selected profile/extras')
    boot_paths={'ibss':'boot/iBSS.dfu','ibec':'boot/iBEC.dfu','devicetree-img3':'boot/DeviceTree.img3',
                'kernel-img3-validated':'boot/kernelcache.img3','kernel-img3-wifi-candidate':'boot/kernelcache.img3'}
    if boot_only:
        entries=[x for x in report['files'] if x['id'] in boot_paths]
        ids={x['id'] for x in entries}
        if not {'ibss','ibec','devicetree-img3'}.issubset(ids) or len(ids & {'kernel-img3-validated','kernel-img3-wifi-candidate'})!=1:
            raise PatchError('bundle lacks the four tethered boot components')
        items={ident:{'destination':path} for ident,path in boot_paths.items()}
    else:
        entries=report['files'];items={v['id']:v for v in m['recipes']}
        selected=report.get('selected')
        if 'selected' not in report:
            selected,_,_=choose(m,report['profile'],','.join(report.get('extras',[])))
        if not isinstance(selected,list) or not selected or any(not isinstance(x,str) for x in selected):
            raise PatchError('bundle patch selection is empty or invalid')
        if set(selected) != {x['id'] for x in entries} or len(selected) != len(entries):
            raise PatchError('bundle artifact set differs from its recorded patch selection')
    seen=set()
    for entry in entries:
        ident=entry['id']
        if ident in seen or ident not in items:raise PatchError('duplicate or unknown bundle artifact')
        seen.add(ident);item=items[ident]
        if feature and not boot_only:
            from features import load_spec
            expected_path=load_spec(PORTABLE,ident,target['ProductType'])['destination']
        else:expected_path=item['destination']
        if entry['path']!=expected_path:raise PatchError('artifact metadata does not match registry')
        if not re.fullmatch('[0-9a-f]{64}',entry['sha256']) or not isinstance(entry['size'],int) or entry['size']<0:raise PatchError('invalid artifact receipt')
        if entry['mode'] not in [0o644,0o755]:raise PatchError('unsupported artifact file mode')
        path=relative(bundle,entry['path'])
        if not path.is_file() or path.stat().st_size!=entry['size'] or sha(path)!=entry['sha256']:raise PatchError('bundle artifact mismatch: '+entry['id'])
    if seen & {'kernel-wifi-candidate', 'kernel-img3-wifi-candidate'}:
        from wifi import check as check_wifi
        check_wifi((bundle/'boot/kernelcache.img3').read_bytes() if boot_only else
                   (bundle/'boot/kernelcache.macho').read_bytes(),
                   (bundle/'boot/DeviceTree.img3').read_bytes() if boot_only else
                   (bundle/'boot/DeviceTree.dtb').read_bytes(), report['target']['ProductType'])
    return report

def save_input(ident,source,directory,match='features'):
    m=registry()
    if ident not in m['inputs'] or m['inputs'][ident].get('produced_by'):raise PatchError('not an external input ID')
    spec=m['inputs'][ident];source=Path(source)
    if not source.is_file() or not source.stat().st_size:raise PatchError('empty or missing input')
    directory=Path(directory).resolve();directory.mkdir(parents=True,exist_ok=True);target=relative(directory,spec['filename'])
    if target.exists():
        if target.read_bytes()==source.read_bytes():return
        raise PatchError('existing input differs')
    with tempfile.NamedTemporaryFile(dir=directory,delete=False) as f:tmp=Path(f.name)
    try:
        shutil.copyfile(source,tmp)
        os.link(tmp,target)  # Atomic no-clobber publication.
    finally:tmp.unlink(missing_ok=True)

def extract_rootfs(model,hfs,hfsplus,directory):
    m=registry();ids=[i for i,s in m['inputs'].items() if i.startswith(model+'-') and s['rootfs_path']]
    with tempfile.TemporaryDirectory(prefix='native6-hfs-') as temp:
        for ident in ids:
            f=Path(temp)/ident
            with stage(f'Extract input {ident}: ' + m['inputs'][ident]['rootfs_path']):
                subprocess.run([str(Path(hfsplus).resolve()),str(Path(hfs).resolve()),'extract',m['inputs'][ident]['rootfs_path'],str(f)],check=True,capture_output=True)
                save_input(ident,f,directory)
        if model in ['n41','n42']:
            version=Path(temp)/'SystemVersion.plist'
            subprocess.run([str(Path(hfsplus).resolve()),str(Path(hfs).resolve()),'extract','/System/Library/CoreServices/SystemVersion.plist',str(version)],check=True,capture_output=True)
            destination=relative(Path(directory).resolve(),'SystemVersion.plist')
            if destination.exists() and destination.read_bytes()!=version.read_bytes():raise PatchError('existing system version metadata differs')
            if not destination.exists():shutil.copyfile(version,destination)
        if model=='n49':
            cache=Path(temp)/'n49-cache'
            subprocess.run([str(Path(hfsplus).resolve()),str(Path(hfs).resolve()),'extract','/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7s',str(cache)],check=True,capture_output=True)
            found=scan_donor(cache,directory)
            if set(found)!={'n49-isp.bin','n49-setfile.dat'}:raise PatchError('both camera donor blobs are required')
            ids+=found
    return ids

def scan_donor(source,directory):
    # Locate embedded camera data and validate its binary patch features.
    data=Path(source).read_bytes();found=[];m=registry()
    for ident in ['n49-isp.bin','n49-setfile.dat']:
        spec=m['inputs'][ident];magic=bytes.fromhex(spec['scan_prefix_hex']);size=spec['size'];start=0
        while True:
            pos=data.find(magic,start)
            if pos<0:break
            start=pos+1;block=data[pos:pos+size]
            compatible=False
            if len(block)==size:
                from features import load_spec,apply_edits,locate,FeatureError
                feature=load_spec(PORTABLE,'camera-isp' if ident=='n49-isp.bin' else 'camera-setfile')
                try:
                    if feature['kind']=='edits':apply_edits(block,feature)
                    else:
                        for pattern in feature['features']:locate(block,bytes.fromhex(pattern))
                    compatible=True
                except FeatureError:pass
            if compatible:
                with tempfile.TemporaryDirectory() as temp:
                    p=Path(temp)/ident;p.write_bytes(block);save_input(ident,p,directory)
                found.append(ident);break
    if not found:raise PatchError('no matching camera binary features found; use extracted ISP/setfile with import')
    return found

def inject_plist(data,libraries,baseband=False,model='iPhone5,4',runtime=None):
    cfg=plistlib.loads(data)
    if not isinstance(cfg,dict):raise PatchError('launchd configuration is not a dictionary')
    env=cfg.setdefault('EnvironmentVariables',{})
    current=list(filter(None,env.get('DYLD_INSERT_LIBRARIES','').split(':')))
    env['DYLD_INSERT_LIBRARIES']=':'.join(dict.fromkeys(current+libraries))
    if baseband:
        cfg['ProgramArguments']=[runtime or '/usr/local/libexec/project5c/CommCenter.n49-runtime']
        machine=cfg.setdefault('LimitLoadToHardware',{}).setdefault('machine',[])
        if not isinstance(machine,list):raise PatchError('unexpected CommCenter hardware whitelist')
        if model not in machine:machine.append(model)
        cfg['RunAtLoad']=True
        cfg['StandardOutPath']='/var/wireless/Library/Logs/CommCenter.project5c.stdout'
        cfg['StandardErrorPath']='/var/wireless/Library/Logs/CommCenter.project5c.stderr'
    return plistlib.dumps(cfg,fmt=plistlib.FMT_BINARY,sort_keys=False)

def commcenter_hardware_plist(data,model):
    if model not in ['iPhone5,3','iPhone5,4']:raise PatchError('unsupported CommCenter target model')
    cfg=plistlib.loads(data)
    if not isinstance(cfg,dict):raise PatchError('launchd configuration is not a dictionary')
    machine=cfg.get('LimitLoadToHardware',{}).get('machine')
    if not isinstance(machine,list):raise PatchError('unexpected CommCenter hardware whitelist')
    if model not in machine:machine.append(model)
    return plistlib.dumps(cfg,fmt=plistlib.FMT_BINARY,sort_keys=False)

def validate_baseband(path):
    """Require a personalized archive, never a generic donor firmware ZIP."""
    path=Path(path)
    if not path.is_file() or path.is_symlink():raise PatchError('missing personalized baseband firmware ZIP')
    try:
        with zipfile.ZipFile(path) as z:
            names=z.namelist()
            if 'bbticket.der' not in names or not z.read('bbticket.der') or not any(n.endswith('.mbn') for n in names):
                raise PatchError('expected signed baseband ZIP with bbticket.der and MBN components')
            if z.testzip() is not None:raise PatchError('corrupt personalized baseband ZIP')
    except zipfile.BadZipFile as error:
        raise PatchError('invalid personalized baseband ZIP') from error

def bluetooth_plist(data):
    """Keep the stock sandbox and exclude inherited jailbreak injection."""
    cfg=plistlib.loads(data)
    if not isinstance(cfg,dict) or cfg.get('Label') not in ['com.apple.BTServer','com.apple.BlueTool']:
        raise PatchError('unexpected Bluetooth launchd configuration')
    env=cfg.setdefault('EnvironmentVariables',{})
    env['DYLD_INSERT_LIBRARIES']=''
    env['_MSSafeMode']='1'
    return plistlib.dumps(cfg,fmt=plistlib.FMT_BINARY,sort_keys=False)

def rootfs_plan(bundle,rootfs,baseband_firmware=None,report=None,baseband_source=None):
    bundle=Path(bundle).resolve();rootfs=Path(rootfs).resolve()
    if rootfs==Path('/'):raise PatchError('host root directory is never an installation target')
    version=plistlib.loads(relative(rootfs,'System/Library/CoreServices/SystemVersion.plist').read_bytes())
    report=verify_bundle(bundle) if report is None else report;feature=report.get('matching')=='binary-features'
    if not feature and (version.get('ProductVersion')!='6.1.3' or version.get('ProductBuildVersion')!='10B329'):raise PatchError('rootfs must be iOS 6.1.3 / 10B329 for an exact historical build')
    if feature and any(report['target'].get(k) and report['target'][k]!=version.get(k) for k in ['ProductVersion','ProductBuildVersion']):raise PatchError('rootfs differs from the source metadata used for this build')
    m=registry();items={v['id']:v for v in m['recipes']};ops=[];ids={r['id'] for r in report['files']}
    def add(name,source=None,data=None,mode=0o644,original_hashes=None):
        dst=relative(rootfs,name)
        if dst.exists() and not dst.is_file():raise PatchError('non-file installation target')
        newhash=sha(source) if source else hashlib.sha256(data).hexdigest()
        oldhash=sha(dst) if dst.exists() else None
        if original_hashes is not None and oldhash is not None and oldhash not in original_hashes+[newhash]:raise PatchError('unknown existing file, refusing overwrite: '+name)
        if oldhash==newhash:return
        ops.append({'path':name,'source':str(source) if source else None,'data':data,'mode':mode,'before_sha256':oldhash,'after_sha256':newhash})
    for row in report['files']:
        if not row['path'].startswith('rootfs/'):continue
        source_ids=row.get('original_inputs',items[row['id']]['inputs']) if feature else items[row['id']]['inputs']
        originals=[report['input_receipts'][i]['sha256'] for i in source_ids if i in report['input_receipts']] if feature else [m['inputs'][i]['sha256'] for i in source_ids[:1] if not m['inputs'][i].get('produced_by')]
        add(row['path'][7:],source=relative(bundle,row['path']),mode=row['mode'],original_hashes=originals)
    if any(ident.startswith('kernel-') for ident in ids):
        sb=relative(rootfs,'System/Library/CoreServices/SpringBoard.app/SpringBoard')
        if feature:
            from features import check_springboard
            check_springboard(sb.read_bytes(),PORTABLE)
        elif not sb.is_file() or sha(sb)!='d8732d707f0853c74e6a7c0072bfc6254a20348e571bb27bee50768af235ef20':raise PatchError('unexpected SpringBoard binary for native6 platform configuration')
        configs=[relative(rootfs,'System/Library/CoreServices/SpringBoard.app/'+name) for name in ['N42AP.plist','N41AP.plist']]
        cfg=next((p for p in configs if p.is_file()),configs[0])
        obj=plistlib.loads(cfg.read_bytes())
        if not obj.get('capabilities') or not obj.get('iconState'):raise PatchError('unexpected original N42 SpringBoard configuration')
        add('System/Library/CoreServices/SpringBoard.app/'+report['target']['HardwareModel']+'.plist',source=cfg,original_hashes=[])
        fstab=relative(rootfs,'private/etc/fstab')
        original=b'/dev/disk0s1 / hfs ro 0 1\n/dev/disk0s2 /private/var hfs rw,nosuid,nodev 0 2\n'
        wanted=b'/dev/disk0s1s1 / hfs ro 0 1\n/dev/disk0s1s2 /private/var hfs rw,nosuid,nodev 0 2\n'
        if not fstab.is_file() or fstab.read_bytes() not in [original,wanted]:raise PatchError('unexpected fstab; this profile uses N49 system/data partitions 1/2')
        add('private/etc/fstab',data=wanted)
    configs=[]
    media=[]
    if 'camera-runtime' in ids:
        for needed in ['camera-isp','camera-setfile']:
            if needed not in ids:raise PatchError('camera injection requires ISP and setfile')
        media.append('/usr/local/lib/camera-ov9762.dylib')
    if 'microphone-runtime' in ids:media.append('/usr/local/lib/native6-microphone-fix.dylib')
    if media:configs.append(('System/Library/LaunchDaemons/com.apple.mediaserverd.plist',media,False))
    if 'autolock-runtime' in ids:configs.append(('System/Library/LaunchDaemons/com.apple.SpringBoard.plist',['/usr/local/lib/native6-autolock.dylib'],False))
    if 'bluetooth' in ids:
        for daemon in ['BTServer','BlueTool']:
            name='System/Library/LaunchDaemons/com.apple.'+daemon+'.plist'
            p=relative(rootfs,name)
            if not p.is_file():raise PatchError('missing original launchd plist: '+name)
            add(name,data=bluetooth_plist(p.read_bytes()),mode=stat.S_IMODE(p.stat().st_mode))
    if 'gps-runtime' in ids:
        if 'locationd-heading' not in ids:raise PatchError('GPS requires heading-patched locationd')
        configs.append(('System/Library/LaunchDaemons/com.apple.locationd.plist',['/usr/local/lib/project5c-locationd-gps.dylib'],False))
    if 'commcenter-runtime' in ids or 'commcenter-bridge' in ids:
        if not {'commcenter-runtime','commcenter-bridge'}.issubset(ids):raise PatchError('baseband runtime and bridge must be selected together')
        if not baseband_firmware and not baseband_source:raise PatchError('baseband requires the latest native restore source or a personalized firmware ZIP')
        if baseband_firmware:
            validate_baseband(baseband_firmware)
            add('usr/local/share/project5c/Mav7/Mav7personalized.zip',source=Path(baseband_firmware).resolve(),original_hashes=[])
        if baseband_source:
            from baseband import native_source
            native = native_source(baseband_source, report['target']['ProductType'])
            name = Path(native['identity']['Manifest']['BasebandFirmware']['Info']['Path']).name
            add('usr/local/share/project5c/Mav7/'+name,source=Path(baseband_source)/'Baseband.bbfw',original_hashes=[])
        configs.append(('System/Library/LaunchDaemons/com.apple.CommCenter.plist',['/usr/local/lib/project5c-commcenter-hsic.dylib'],True))
    else:
        name='System/Library/LaunchDaemons/com.apple.CommCenter.plist'
        p=relative(rootfs,name)
        if not p.is_file():raise PatchError('missing original launchd plist: '+name)
        add(name,data=commcenter_hardware_plist(p.read_bytes(),report['target']['ProductType']),mode=stat.S_IMODE(p.stat().st_mode))
    for name,libs,bb in configs:
        p=relative(rootfs,name)
        if not p.is_file():raise PatchError('missing original launchd plist: '+name)
        runtime=next((row['path'][7:] for row in report['files'] if row['id']=='commcenter-runtime'),None)
        add(name,data=inject_plist(p.read_bytes(),libs,bb,model=report['target']['ProductType'],runtime='/'+runtime if runtime else None),mode=stat.S_IMODE(p.stat().st_mode))
    return ops

def ramboot(bundle,irecovery,ecid,execute=False,tools_dir=None):
    bundle=Path(bundle).resolve();report=verify_bundle(bundle,boot_only=True);ids={r['id'] for r in report['files']}
    if not {'ibec','devicetree-img3'}.issubset(ids) or not any(x.startswith('kernel-img3-') for x in ids):raise PatchError('bundle lacks RAM boot components')
    from hosttools import tool_directory, tool_env, require_tools, prepare_pwned_ibss, dfu_stage
    from targets import bundle_target
    target=bundle_target(report) if 'target' in report else {'board_id':14,'HardwareModel':'N49AP'}
    board=target['board_id'];label=target['HardwareModel']
    automatic=bool(tools_dir)
    if automatic and irecovery:raise PatchError('--irecovery cannot be combined with --tools-dir')
    env=dict(os.environ)
    if automatic:
        binpath=tool_directory(tools_dir=tools_dir);irecovery=binpath/'irecovery';env=tool_env(binpath)
    if not irecovery:raise PatchError('--irecovery or --tools-dir is required')
    tool=str(Path(irecovery).resolve());commands=[[tool,'-f',str(bundle/'boot/iBEC.dfu')],[tool,'-f',str(bundle/'boot/DeviceTree.img3')],[tool,'-c','devicetree'],[tool,'-f',str(bundle/'boot/kernelcache.img3')],[tool,'-c','bootx']]
    if execute:
        if not ecid or int(ecid,0)==0:raise PatchError('your own nonzero --ecid is required')
        require_tools(Path(tool).parent,[Path(tool).name])
        if automatic:
            with stage('Prepare DFU and upload matching iBSS'):
                prepare_pwned_ibss(binpath,ecid,target,bundle/'boot/iBSS.dfu')
        q=subprocess.check_output([tool,'-q'],text=True,timeout=15,env=env)
        fields=dict(re.findall(r'^([A-Z]+):\s*(.+)$',q,re.M))
        if int(fields.get('ECID','0'),0)!=int(ecid,0) or int(fields.get('CPID','0'),0)!=0x8950 or int(fields.get('BDID','0'),0)!=board or dfu_stage(fields)!='pwned-ibss':raise PatchError('expected matching '+label+' with compatible RAM-loaded pwned iBSS (DFU, SRTG N/A)')
        import time
        with stage('Tethered boot [1/5]: upload iBEC'):
            subprocess.run(commands[0],env=env,check=True,timeout=45)
        time.sleep(2)
        q=subprocess.check_output([tool,'-q'],text=True,timeout=15,env=env);fields=dict(re.findall(r'^([A-Z]+):\s*(.+)$',q,re.M))
        if int(fields.get('ECID','0'),0)!=int(ecid,0) or not fields.get('MODE','').startswith('Recovery'):raise PatchError('matching iBEC recovery device not found')
        for index,command in enumerate(commands[1:],2):
            with stage(f'Tethered boot [{index}/{len(commands)}]: ' + ' '.join(command[1:])):
                subprocess.run(command,env=env,check=True,timeout=45)
            time.sleep(2)
    return {'preview':not execute,'commands':commands,'nand_kernel_written':False,'dfu_preparation':(['identify your '+label+' DFU','host exploit if needed','gaster reset','upload and verify bundled iBSS'] if automatic else []),'precondition':'Physical '+label+' DFU; --tools-dir prepares pwned iBSS, otherwise compatible RAM-loaded iBSS is required'}

def main():
    p=argparse.ArgumentParser(description='Build, check or boot the unified N48/N49 patch bundle.')
    sub=p.add_subparsers(dest='command',required=True)
    sub.add_parser('check')
    for name in ['build','doctor','list','inputs']:
        q=sub.add_parser(name)
        q.add_argument('--model',choices=['iPhone5,3','iPhone5,4'],default='iPhone5,4')
        q.add_argument('--profile',default='native6-validated')
        q.add_argument('--extras',default='');q.add_argument('--only',default='')
        if name in ['build','doctor']:
            q.add_argument('--inputs',type=Path,required=True)
            q.add_argument('--donor-inputs',type=Path);q.add_argument('--tools-dir',type=Path);q.add_argument('--keys',type=Path)
        if name=='build':q.add_argument('--out',type=Path,required=True)
    q=sub.add_parser('verify');q.add_argument('--bundle',type=Path,required=True)
    q=sub.add_parser('ramboot');q.add_argument('--bundle',type=Path,required=True)
    q.add_argument('--irecovery',type=Path);q.add_argument('--tools-dir',type=Path)
    q.add_argument('--ecid');q.add_argument('--execute',action='store_true')
    for command_parser in sub.choices.values():
        command_parser.add_argument('--json',action='store_true',help='Print the full result report to stdout')
    a=p.parse_args()
    if a.command=='check':result=verify_registry()
    elif a.command=='verify':
        with stage('Verify bundle artifacts: ' + str(a.bundle)):
            result=verify_bundle(a.bundle)
    elif a.command=='ramboot':
        if a.execute:
            import fcntl
            lockfile=Path.home()/'.cache/project5c-native6-device.lock';lockfile.parent.mkdir(parents=True,exist_ok=True)
            with lockfile.open('a') as stream:
                try:fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:raise PatchError('another device operation is running')
                result=ramboot(a.bundle,a.irecovery,a.ecid,a.execute,a.tools_dir)
        else:result=ramboot(a.bundle,a.irecovery,a.ecid,tools_dir=a.tools_dir)
    else:
        from features import feature_build, feature_input_ids, feature_catalog
        m=registry();active,order,required=choose(m,a.profile,a.extras,a.only)
        available=set(feature_catalog(PORTABLE,a.model)['recipes'])
        if not set(active)<=available:raise PatchError('Selected patches are unavailable for '+a.model)
        if a.command=='list':result={'model':a.model,'selected':active}
        elif a.command=='inputs':result=feature_input_ids(PORTABLE,active,a.model)
        elif a.command=='doctor':result=feature_build(sys.modules[__name__],a.inputs,None,a.profile,a.extras,a.only,doctor=True,
                                                       model=a.model,donor_inputs=a.donor_inputs,tools=a.tools_dir,keys_file=a.keys)
        else:result=build(a.inputs,a.out,a.profile,a.extras,a.only,model=a.model,
                          donor_inputs=a.donor_inputs,tools=a.tools_dir,keys_file=a.keys)
    if a.json or a.command in ('list','inputs'):
        print(json.dumps(result,indent=2,ensure_ascii=False))
    elif a.command=='build':
        log(f'Built {len(result["files"])} patches for {result["target"]["ProductType"]}; report: {a.out / "build.json"}', 'DONE')
    elif a.command=='verify':
        log(f'Bundle verified: {a.bundle}; {len(result["files"])} artifacts', 'DONE')
    elif a.command=='ramboot':
        if result['preview']:
            log('Tethered boot preview; no USB writes performed. ' + result['precondition'])
            for step in result['dfu_preparation']:log('DFU preparation: ' + step)
            preview_commands(result['commands'])
        else:log('Tethered boot commands sent; check the device for boot progress.', 'DONE')
    elif a.command=='doctor':
        log(f'Input checks passed: {result["recipes"]} patches, {result["external_inputs"]} inputs', 'DONE')
    else:log('Package checks passed: ' + ', '.join(result['models']), 'DONE')

if __name__=='__main__':
    try:main()
    except subprocess.TimeoutExpired as e:
        error_detail(e, include_output=False)
        if e.cmd and Path(e.cmd[0]).name=='a6meowing':
            print('ERROR: DFU exploit timed out before iBSS/iBEC/kernel upload; re-enter physical DFU. This is not evidence of a kernel panic.',file=sys.stderr)
        else:print('ERROR: operation timed out; inspect the last STEP/FAIL entry.',file=sys.stderr)
        raise SystemExit(2)
    except (PatchError,OSError,ValueError,KeyError,subprocess.CalledProcessError) as e:
        error_detail(e, include_output=False);raise SystemExit(2)
