"""Binary-feature patching: preserve untouched bytes; reject missing/ambiguous anchors.

Absolute-address legacy patches additionally require the original segment layout.
Digests are receipts/integrity checks, never firmware compatibility predicates.
"""
from __future__ import annotations
import hashlib,json,struct,zlib
from collections import defaultdict,deque
from pathlib import Path
from firmware import parse_img3,decompress_complzss
from integrity import declaration, checked, load_json

class FeatureError(ValueError):pass

def commands(data):
    if len(data)<28 or data[:4]!=b'\xce\xfa\xed\xfe':raise FeatureError('expected 32-bit little-endian Mach-O')
    count,size=struct.unpack_from('<II',data,16);p=28
    if count>4096 or 28+size>len(data):raise FeatureError('invalid Mach-O commands')
    for _ in range(count):
        if p+8>28+size:raise FeatureError('truncated command')
        cmd,n=struct.unpack_from('<II',data,p)
        if n<8 or p+n>28+size:raise FeatureError('invalid command length')
        yield cmd,p,n;p+=n
    if p!=28+size:raise FeatureError('command size mismatch')

def layout(data):
    if data.startswith(b'dyld_v1'):
        p,n=struct.unpack_from('<II',data,16)
        if n>64 or p+32*n>len(data):raise FeatureError('invalid cache mappings')
        return {'kind':'dyld','architecture':data[:16].hex(),'mappings':[list(struct.unpack_from('<QQQII',data,p+32*i)) for i in range(n)]}
    if data[:4]==b'\xce\xfa\xed\xfe':
        segments=[]
        for cmd,p,n in commands(data):
            if cmd==1:
                if n<56:raise FeatureError('invalid segment')
                segments.append([data[p+8:p+24].hex(),*struct.unpack_from('<4I',data,p+24)])
        return {'kind':'macho','cpu':list(struct.unpack_from('<iiI',data,4)),'segments':segments}
    return {'kind':'raw'}

def locate(data,pattern):
    if not pattern:raise FeatureError('empty feature')
    pos=data.find(pattern)
    if pos<0:raise FeatureError('binary feature not found')
    if data.find(pattern,pos+1)>=0:raise FeatureError('ambiguous binary feature')
    return pos

def code_directory(data):
    sig=None
    if data.startswith(b'dyld_v1'):sig=struct.unpack_from('<Q',data,40)[0]
    elif data[:4]==b'\xce\xfa\xed\xfe':
        for cmd,p,_ in commands(data):
            if cmd==0x1d:sig=struct.unpack_from('<I',data,p+8)[0]
    if not sig:return None
    if sig+12>len(data):raise FeatureError('signature outside image')
    magic,total,count=struct.unpack_from('>III',data,sig)
    if magic!=0xfade0cc0 or count>64 or sig+total>len(data):raise FeatureError('unsupported code signature')
    for i in range(count):
        kind,off=struct.unpack_from('>II',data,sig+12+8*i)
        if kind:continue
        cd=sig+off
        magic,n,version,flags,hoff,ident,special,slots,limit=struct.unpack_from('>9I',data,cd)
        hs,ht,_,ps=struct.unpack_from('4B',data,cd+36)
        if magic!=0xfade0c02 or hs!=20 or ht!=1 or ps!=12 or limit!=sig or slots!=(limit+4095)//4096 or hoff+slots*hs>n or cd+n>len(data):raise FeatureError('unsupported CodeDirectory layout')
        return {'signature':sig,'hash_offset':cd+hoff,'slots':slots,'limit':limit,'size':total}
    raise FeatureError('missing CodeDirectory')

def resign(data):
    cd=code_directory(data)
    if cd is None:return data,0
    out=bytearray(data)
    for i in range(cd['slots']):
        p=cd['hash_offset']+i*20;out[p:p+20]=hashlib.sha1(out[i*4096:min((i+1)*4096,cd['limit'])]).digest()
    return bytes(out),cd['slots']

def verify_signature(data):
    cd=code_directory(data)
    if not cd:return 0
    for i in range(cd['slots']):
        p=cd['hash_offset']+i*20
        if data[p:p+20]!=hashlib.sha1(data[i*4096:min((i+1)*4096,cd['limit'])]).digest():raise FeatureError('invalid code page signature')
    return cd['slots']

def apply_edits(data,spec):
    if layout(data)!=spec['layout']:raise FeatureError('segment/mapping layout differs; address-bearing patch needs relocation')
    if len(data)!=spec['input_size']:raise FeatureError('image extent differs; relink required')
    positions={};planned=[]
    for edit in spec['edits']:
        anchor=bytes.fromhex(edit['anchor'])
        if anchor not in positions:positions[anchor]=locate(data,anchor)
        pos=positions[anchor]+edit['relative_offset'];before=bytes.fromhex(edit['before']);after=bytes.fromhex(edit['after'])
        if pos<0 or pos+len(before)>len(data) or data[pos:pos+len(before)]!=before:raise FeatureError('patch preimage feature differs: '+hex(max(0,pos)))
        planned.append((pos,before,after))
    planned.sort();last=0
    for pos,before,after in planned:
        if pos<last:raise FeatureError('overlapping features')
        last=pos+len(before)
    out=bytearray(data)
    # Edits are equal-length; only a declared suffix can change the extent.
    for pos,before,after in planned:
        if len(before)!=len(after):raise FeatureError('invalid fixed-layout edit')
        out[pos:pos+len(before)]=after
    keep=spec['keep_size']
    if keep<0 or keep>len(out):raise FeatureError('invalid retained extent')
    result=bytes(out[:keep])+bytes.fromhex(spec['tail'])
    if spec.get('resign'):result,slots=resign(result)
    else:slots=0
    return result,{'features':len(planned),'unique_anchors':len(positions),'code_slots_verified':slots,'untouched_input_bytes_preserved':True}

# DeviceTree matching uses node/property names and old values, never a file digest.
def parse_tree(data):
    def node(p,depth):
        if depth>64 or p+8>len(data):raise FeatureError('invalid device tree')
        np,nc=struct.unpack_from('<II',data,p);p+=8
        if np>8192 or nc>8192:raise FeatureError('invalid device tree counts')
        props=[]
        for _ in range(np):
            if p+36>len(data):raise FeatureError('truncated property')
            name=data[p:p+32].split(b'\0',1)[0].decode('ascii');raw=struct.unpack_from('<I',data,p+32)[0];n=raw&0x7fffffff;p+=36
            if p+n>len(data):raise FeatureError('property outside tree')
            props.append({'name':name,'flags':raw&0x80000000,'value':data[p:p+n].hex()});p+=(n+3)&~3
        if len({x['name'] for x in props})!=len(props):raise FeatureError('duplicate tree property')
        children=[]
        for _ in range(nc):child,p=node(p,depth+1);children.append(child)
        return {'properties':props,'children':children},p
    root,end=node(0,0)
    if data[end:].strip(b'\0'):raise FeatureError('trailing device tree data')
    return root

def serialize_tree(node):
    out=bytearray(struct.pack('<II',len(node['properties']),len(node['children'])))
    for p in node['properties']:
        name=p['name'].encode();value=bytes.fromhex(p['value'])
        if len(name)>31:raise FeatureError('property name too long')
        out+=name.ljust(32,b'\0')+struct.pack('<I',p['flags']|len(value))+value+b'\0'*((-len(value))%4)
    for child in node['children']:out+=serialize_tree(child)
    return bytes(out)

def tree_nodes(root):
    out={}
    def walk(node,parent,suffix=''):
        prop=next((p for p in node['properties'] if p['name']=='name'),None)
        if prop is None:raise FeatureError('unnamed tree node')
        name=bytes.fromhex(prop['value']).split(b'\0',1)[0].decode();path=parent+'/'+name+suffix
        if path in out:raise FeatureError('ambiguous tree node')
        out[path]=node
        names=[bytes.fromhex(next(p['value'] for p in c['properties'] if p['name']=='name')).split(b'\0',1)[0] for c in node['children']]
        seen={}
        for child,name in zip(node['children'],names):
            ordinal=seen.get(name,0);seen[name]=ordinal+1
            walk(child,path,'['+str(ordinal)+']' if names.count(name)>1 else '')
    walk(root,'');return out

def apply_tree(data,spec):
    root=parse_tree(data);nodes=tree_nodes(root)
    for addition in spec.get('node_additions',[]):
        if addition['path'] in nodes or addition['parent'] not in nodes:raise FeatureError('tree insertion feature differs')
        nodes[addition['parent']]['children'].insert(addition['index'],addition['node'])
        nodes=tree_nodes(root)
    for op in spec['properties']:
        if op['node'] not in nodes:raise FeatureError('tree feature not found: '+op['node'])
        node=nodes[op['node']];props=node['properties'];found=next((p for p in props if p['name']==op['name']),None)
        if found not in op['accepted']:raise FeatureError('tree property preimage differs: '+op['name'])
        if found is not None:props.remove(found)
        if op['after'] is not None:props.insert(min(op['index'],len(props)),op['after'])
    for path,names in spec.get('property_order',{}).items():
        props=nodes[path]['properties'];byname={p['name']:p for p in props}
        nodes[path]['properties']=[byname[name] for name in names if name in byname]+[p for p in props if p['name'] not in names]
    return serialize_tree(root),{'features':len(spec['properties']),'untouched_properties_preserved':True}

def wrap_img3(template,payload,*,plaintext=False):
    image=parse_img3(template);parts=[];delta=0
    for tag in image.tags:
        # A plaintext DATA image must not ask iBoot to decrypt it using donor keys.
        if plaintext and tag.name=='KBAG':
            if image.shsh_offset and tag.offset<20+image.shsh_offset:delta-=tag.full_size
            continue
        raw=template[tag.offset:tag.offset+tag.full_size]
        if tag.name=='DATA':
            padded=payload+b'\0'*((-len(payload))%16)
            raw=struct.pack('<III',int.from_bytes(b'DATA','big'),12+len(padded),len(payload))+padded
            delta+=len(raw)-tag.full_size
        parts.append(raw)
    body=b''.join(parts);header=list(struct.unpack_from('<5I',template));header[1]=20+len(body);header[2]=len(body)
    if header[3]:header[3]+=delta
    out=struct.pack('<5I',*header)+body;parse_img3(out);return out

def compress_complzss(data,header):
    """Deterministic 4 KiB-window LZSS, compatible with the stock decoder."""
    if len(header)<0x180 or header[:8]!=b'complzss':raise FeatureError('invalid compression template')
    history=defaultdict(deque);packed=bytearray();p=0;n=len(data)
    while p<n:
        flagpos=len(packed);packed.append(0);flags=0
        for bit in range(8):
            if p>=n:break
            best=0;distance=0;key=data[p:p+3];queue=history.get(key,())
            # Only candidate starts inside the actual ring are considered.
            for q in reversed(queue):
                if p-q>4096:break
                k=3;limit=min(18,n-p)
                while k<limit and data[q+k]==data[p+k]:k+=1
                if k>best:best=k;distance=p-q
                if k==limit:break
            take=best if best>=3 else 1
            if take==1:flags|=1<<bit;packed.append(data[p])
            else:
                ring=(4096-18+p-distance)&4095
                packed.extend([ring&255,((ring>>4)&0xf0)|(take-3)])
            for i in range(p,p+take):
                if i+3>n:continue
                old=i-4096
                if old>=0:
                    oldkey=data[old:old+3];oldqueue=history.get(oldkey)
                    if oldqueue:
                        while oldqueue and oldqueue[0]<=old:oldqueue.popleft()
                        if not oldqueue:del history[oldkey]
                q=history[data[i:i+3]]
                while q and i-q[0]>4096:q.popleft()
                q.append(i)
                if len(q)>24:q.popleft()
            p+=take
        packed[flagpos]=flags
    hdr=bytearray(header[:0x180]);struct.pack_into('>III',hdr,8,zlib.adler32(data)&0xffffffff,len(data),len(packed))
    result=bytes(hdr)+packed
    if decompress_complzss(result)[0]!=data:raise FeatureError('compression round-trip failed')
    return result

def feature_catalog(directory,model='iPhone5,4'):
    from targets import target_for
    target=target_for(model);model=target['ProductType'];board=target['HardwareModel'][:-2].lower()
    directory=Path(directory)
    common=declaration(directory/'catalog.py','COMMON')
    overrides=declaration(directory/'catalog.py','MODELS')[model]
    recipes={};checks={}
    for ident in dict.fromkeys(common+overrides):
        path=(board if ident in overrides else 'common')+'/'+ident+'/patch.py'
        spec=declaration(directory/path,'PATCH')
        row={'path':path}
        (checks if spec['kind']=='prelink-feature' else recipes)[ident]=row
    return {'recipes':recipes,'checks':checks}


def read_definition(directory,name):
    path=Path(name)
    if path.is_absolute() or '..' in path.parts:raise FeatureError('unsafe patch definition path')
    spec=declaration(Path(directory)/path,'PATCH')
    spec['id']=path.parent.name
    if spec.get('data'):
        spec={**load_json(Path(directory)/spec['data']),**spec}
    for replacement in spec.get('edit_replacements',[]):
        before=bytes.fromhex(replacement['before']);after=bytes.fromhex(replacement['after']);count=0
        if not before or len(before)!=len(after):raise FeatureError('variant edit must preserve byte length')
        spec['edits']=[dict(row) for row in spec['edits']]
        for row in spec['edits']:
            value=bytes.fromhex(row['after']);count+=value.count(before)
            row['after']=value.replace(before,after).hex()
        if count!=replacement['count']:raise FeatureError('variant edit count differs')
    for key in ['template','compression_header']:
        if spec.get(key+'_file'):
            spec[key]=checked(Path(directory)/spec[key+'_file']).hex()
    if spec.get('template_recipe'):
        template=read_definition(directory,spec['template_recipe'])
        spec={**template,**spec}
    return spec


def load_spec(directory,ident,model='iPhone5,4',catalog=None):
    catalog=feature_catalog(directory,model) if catalog is None else catalog
    row=catalog['recipes'].get(ident) or catalog['checks'].get(ident)
    if row is None:raise FeatureError('patch is unavailable for '+model+': '+ident)
    spec=read_definition(directory,row['path'])
    if spec.get('models'):
        from targets import target_for
        spec.update(spec.pop('models')[target_for(model)['ProductType']])
    return resolve_tree_spec(directory,spec)


def kernel_dependency(spec,active):
    candidates=spec['kernel_dependency']
    if isinstance(candidates,str):return candidates
    selected=[ident for ident in candidates if ident in active]
    if len(selected)>1:raise FeatureError('ambiguous touch kernel dependency')
    return selected[0] if selected else candidates[0]


def resolve_tree_spec(directory,spec):
    if not spec.get('base'):return spec
    base=read_definition(directory,spec['base'])
    if base.get('base') or base['kind']!='tree' or spec['kind']!='tree':raise FeatureError('invalid shared tree definition')
    result={**base,**spec}
    result['properties']=base['properties']+spec['properties']
    result['node_additions']=base.get('node_additions',[])+spec.get('node_additions',[])
    return result

def check_prelink(data,spec):
    from firmware import extract_macho32_section,parse_prelink_xml
    metadata=parse_prelink_xml(extract_macho32_section(data,'__PRELINK_INFO','__info'))
    matches=[row for row in metadata['_PrelinkInfoDictionary'] if row.get('CFBundleIdentifier')==spec['bundle_id']]
    if len(matches)!=1:raise FeatureError('touch kernel bundle is missing or ambiguous')
    personalities=matches[0].get('IOKitPersonalities',{})
    if not any(all(p.get(k)==v for k,v in spec['matching'].items()) for p in personalities.values()):
        raise FeatureError('touch kernel personality is missing')
    return {'passed':True,'bundle_id':spec['bundle_id'],'matching':spec['matching']}

def feature_input_path(ctl,inputs,ident,donor_inputs=None):
    # Source iOS 6 components always come from the source input directory.
    if donor_inputs is not None and not ident.startswith(('n41-', 'n42-')):
        donor=ctl.relative(donor_inputs,ident)
        if donor.is_file():return donor
    return ctl.relative(inputs,ident)

def feature_build(ctl,inputs,dest,profile,extras='',only='',doctor=False,
                  model='iPhone5,4',donor_inputs=None,tools=None,keys_file=None):
    import os,tempfile,plistlib
    from progress import log, stage as progress_stage
    from targets import target_for
    from sourcepatches import source_identity, source_spec
    inputs=Path(inputs).resolve();dest=Path(dest).absolute() if dest else None
    source_firmware=source_identity(inputs)
    target=target_for(model);model=target['ProductType']
    target={key:target[key] for key in ['ProductType','HardwareModel']}
    if dest and (dest.exists() or dest.is_symlink()):raise FeatureError('build destination already exists')
    m=ctl.registry();active,_,_=ctl.choose(m,profile,extras,only);items={x['id']:x for x in m['recipes']}
    catalog=feature_catalog(ctl.PORTABLE,model);cache={};evidence={};originals={};consumed={};keys=None
    unavailable=set(active)-set(catalog['recipes'])
    if unavailable:raise FeatureError('patches unavailable for '+model+': '+','.join(sorted(unavailable)))
    def read_input(name,ident):
        source=feature_input_path(ctl,inputs,name,donor_inputs)
        if not source.is_file() or not source.stat().st_size:raise FeatureError('missing or empty input: '+name)
        data=source.read_bytes();originals[name]={'sha256':hashlib.sha256(data).hexdigest(),'size':len(data)}
        consumed[ident].add(name)
        return source,data
    def get(ident):
        nonlocal keys
        if ident in cache:return cache[ident]
        spec=source_spec(ctl.PORTABLE,load_spec(ctl.PORTABLE,ident,model,catalog),model,source_firmware);consumed[ident]=set()
        action = {'edits': 'match binary features and apply edits',
                  'tree': 'patch DeviceTree properties',
                  'container': 'compress kernel and package IMG3' if spec.get('core', '').startswith('kernel-') else 'package IMG3',
                  'copy': 'validate and copy donor resource',
                  'fixed-n49-boot': 'check and load boot payload',
                  'boot-feature': 'decrypt, patch and encrypt boot component',
                  'feature-runtime': 'check and install runtime payload',
                  'payload': 'check and install payload'}.get(spec['kind'], spec['kind'])
        with progress_stage(f"Patch {ident}: {action} -> {spec['destination']}"):
            kind=spec['kind'];inp=spec.get('input');data=None
            if inp:source,data=read_input(inp,ident)
            if kind=='edits':out,ev=apply_edits(data,spec)
            elif kind=='tree':
                if spec.get('donor_input'):
                    _,donor=read_input(spec['donor_input'],ident)
                    props={p['name']:bytes.fromhex(p['value']) for p in parse_tree(donor)['properties']}
                    if props.get('model')!=(model+'\0').encode() or (target['HardwareModel']+'\0').encode() not in props.get('compatible',b''):
                        raise FeatureError('DeviceTree donor model differs from '+model)
                spec={**spec,'properties':spec['properties']+spec.get('profile_properties',{}).get(profile,[])}
                out,ev=apply_tree(data,spec)
            elif kind in ['copy','fixed-n49-boot']:
                for pattern in spec.get('features',[]):locate(data,bytes.fromhex(pattern))
                if kind=='copy':
                    if len(data)!=spec.get('input_size',spec.get('size')):raise FeatureError('donor extent differs')
                    if spec.get('sha256') and hashlib.sha256(data).hexdigest()!=spec['sha256']:raise FeatureError('donor resource differs: '+inp)
                    if spec.get('match',{}).get('plist') and not isinstance(plistlib.loads(data),dict):raise FeatureError('expected touch property plist')
                    out=data
                else:
                    out=checked(ctl.relative(ctl.PORTABLE,spec['payload']))
                ev={'features':len(spec.get('features',[])),'fixed_n49_boot':kind=='fixed-n49-boot'}
                if spec.get('kernel_dependency'):
                    core=kernel_dependency(spec,active)
                    ev['kernel_check']=check_prelink(get(core),load_spec(ctl.PORTABLE,spec['kernel_check'],model,catalog))
                    consumed[ident].update(consumed[core])
            elif kind=='boot-feature':
                from n48 import patch_boot
                from firmwarekeys import fetch
                from hosttools import require_tools
                if tools is None:raise FeatureError('boot generation requires --tools-dir')
                bins=Path(tools).resolve();require_tools(bins,['iBoot32Patcher','xpwntool'])
                if keys is None:
                    keys=ctl.json_read(keys_file) if keys_file else fetch(model,spec['donor_version'],spec['donor_build'],['iBSS','iBEC'])
                    keys=keys.get('donor',keys)
                with tempfile.TemporaryDirectory(prefix='native6-boot-') as temp:
                    out,ev=patch_boot(source,keys,bins,'iBSS' if ident=='ibss' else 'iBEC',Path(temp),spec)
            elif kind=='container':
                out=get(spec['core'])
                consumed[ident].update(consumed[spec['core']])
                if spec['core'].startswith('kernel-'):
                    if doctor:
                        ev={'derived_from':spec['core'],'compression_round_trip':'performed by build'};out=b''
                    else:
                        out=compress_complzss(out,bytes.fromhex(spec['compression_header']));ev={'derived_from':spec['core'],'compression_round_trip':True}
                else:ev={'derived_from':spec['core']}
                if not doctor:out=wrap_img3(bytes.fromhex(spec['template']),out)
            elif kind in ['feature-runtime','payload']:
                out=checked(ctl.relative(ctl.PORTABLE,spec['payload']))
                for name in spec.get('sources',[]):checked(ctl.relative(ctl.ROOT,name))
                ev=({'runtime_matching':'instruction features; no UUID gate','physical_validation':False}
                    if kind=='feature-runtime' else {'fixed_project_payload':True})
            else:raise FeatureError('unsupported feature operation')
            if kind in ['edits'] and spec.get('resign'):ev['code_slots_verified']=verify_signature(out)
            cache[ident]=out;evidence[ident]=ev;return out
    log(f'Building {len(active)} patches for {model}; profile={profile}; extras={extras or "none"}')
    # Preflight every active feature before publishing any output.
    for ident in active:get(ident)
    wifi_compatibility=None
    if 'kernel-wifi-candidate' in active and 'devicetree' in active:
        from wifi import check as check_wifi
        wifi_compatibility=check_wifi(get('kernel-wifi-candidate'),get('devicetree'),model)
    version={};vpath=ctl.relative(inputs,'SystemVersion.plist')
    if vpath.is_file():
        v=plistlib.loads(vpath.read_bytes());version={k:v.get(k) for k in ['ProductVersion','ProductBuildVersion']}
    target.update(version)
    summary={'schema':1,'matching':'binary-features','profile':profile,'extras':list(filter(None,extras.split(','))),
             'selected':active,'target':target,'registry_sha256':ctl.sha(ctl.PORTABLE/'catalog.py'),
             'files':[],
             'input_receipts':originals,'feature_evidence':evidence,'device_operations':False,
             'physical_validation':False,'reproduction':'Feature-based candidate; untouched source bytes preserved; not a validated firmware release.'}
    if source_firmware is not None:summary['source_firmware']=source_firmware
    if wifi_compatibility is not None:summary['wifi_compatibility']=wifi_compatibility
    if doctor:return summary|{'passed':True,'recipes':len(active),'external_inputs':len(originals)}
    with progress_stage('Publish patch bundle: ' + str(dest)):
        dest.parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='.native6-features-',dir=dest.parent) as temp:
            stage=Path(temp)
            for ident in active:
                spec=load_spec(ctl.PORTABLE,ident,model,catalog)
                mode=spec['mode'];destination=spec['destination']
                path=ctl.relative(stage,destination);path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(cache[ident]);path.chmod(mode)
                summary['files'].append({'id':ident,'path':destination,'sha256':ctl.sha(path),'size':path.stat().st_size,'mode':mode,'original_inputs':sorted(consumed[ident])})
            ctl.json_write(stage/'build.json',summary)
            if dest.exists():raise FeatureError('destination appeared during build')
            os.rename(stage,dest)
    return summary

def check_springboard(data,directory):
    if layout(data)['kind']!='macho':raise FeatureError('SpringBoard is not a supported Mach-O')
    spec=declaration(Path(directory)/'springboard.py','CHECK')
    for row in spec['features']:
        value=bytes.fromhex(row['feature'])
        if locate(data,value)!=row['offset']:raise FeatureError('SpringBoard hook needs relocation')
    return True

def verify_catalog(ctl):
    result={}
    allowed={'edits','tree','container','copy','fixed-n49-boot','boot-feature','payload','feature-runtime'}
    for model in ['iPhone5,3','iPhone5,4']:
        catalog=feature_catalog(ctl.PORTABLE,model)
        for ident in catalog['recipes']:
            spec=load_spec(ctl.PORTABLE,ident,model,catalog)
            if spec['id']!=ident or spec['kind'] not in allowed:raise FeatureError('invalid patch definition: '+ident)
            ctl.relative(ctl.PORTABLE,spec['destination'])
            if spec['mode'] not in [0o644,0o755]:raise FeatureError('invalid patch mode: '+ident)
            if spec['kind']=='container' and spec['core'] not in catalog['recipes']:raise FeatureError('missing container core')
            if spec.get('payload'):checked(ctl.relative(ctl.PORTABLE,spec['payload']))
            for name in spec.get('sources',[]):checked(ctl.relative(ctl.ROOT,name))
        for ident in catalog['checks']:load_spec(ctl.PORTABLE,ident,model,catalog)
        if model=='iPhone5,3':
            from n48 import N48_CORE
            optional={'kernel-wifi-candidate','kernel-img3-wifi-candidate','commcenter-runtime','commcenter-bridge'}
            if set(catalog['recipes'])!=N48_CORE|optional:raise FeatureError('N48 patch set differs')
        result[model]={'passed':True,'patches':len(catalog['recipes'])}
    return result

def feature_input_ids(directory,active,model='iPhone5,4'):
    needed=set();seen=set()
    catalog=feature_catalog(directory,model)
    def visit(ident):
        if ident in seen:return
        seen.add(ident);spec=load_spec(directory,ident,model,catalog)
        if spec.get('input'):needed.add(spec['input'])
        if spec.get('donor_input'):needed.add(spec['donor_input'])
        if spec['kind']=='container':visit(spec['core'])
        if spec.get('kernel_dependency'):visit(kernel_dependency(spec,active))
    for ident in active:visit(ident)
    return needed
