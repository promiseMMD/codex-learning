import hashlib,json,struct,sys,zipfile
from pathlib import Path
path=Path(sys.argv[1]);expected_sha=sys.argv[2];expected_version=int(sys.argv[3])
raw=path.read_bytes();digest=hashlib.sha256(raw).hexdigest()
assert digest==expected_sha,'APK hash mismatch'
with zipfile.ZipFile(path) as z:
    assert z.testzip() is None
    abis=sorted({n.split('/')[1] for n in z.namelist() if n.startswith('lib/')})
    assert abis==['arm64-v8a']
    assert b'/api/v3/topics' in z.read('assets/flutter_assets/assets/lan/lan.js')
    native=[n for n in z.namelist() if n.endswith('/assets/editor/index.html')]
    assert len(native)==1
    html=z.read(native[0]);assert b'bodyOnly' in html and b'snapshot' in html
    xml=z.read('AndroidManifest.xml')
def u16(data,offset):return struct.unpack_from('<H',data,offset)[0]
def u32(data,offset):return struct.unpack_from('<I',data,offset)[0]
def length8(data,offset):
    n=data[offset];offset+=1
    if n&128:n=((n&127)<<8)|data[offset];offset+=1
    return n,offset
def length16(data,offset):
    n=u16(data,offset);offset+=2
    if n&32768:n=((n&32767)<<16)|u16(data,offset);offset+=2
    return n,offset
strings=[];manifest={};sdk={};pos=8
while pos<len(xml):
    kind,header,size=struct.unpack_from('<HHI',xml,pos)
    assert size>=header and size>0
    if kind==1:
        count=u32(xml,pos+8);flags=u32(xml,pos+16);start=u32(xml,pos+20)
        for i in range(count):
            offset=pos+start+u32(xml,pos+header+i*4)
            if flags&256:
                _,offset=length8(xml,offset);n,offset=length8(xml,offset)
                strings.append(xml[offset:offset+n].decode('utf-8'))
            else:
                n,offset=length16(xml,offset)
                strings.append(xml[offset:offset+n*2].decode('utf-16le'))
    elif kind==0x102:
        element=strings[u32(xml,pos+20)]
        attr_start=u16(xml,pos+24);attr_size=u16(xml,pos+26);count=u16(xml,pos+28)
        attrs={}
        for i in range(count):
            p=pos+16+attr_start+i*attr_size
            name=strings[u32(xml,p+4)];raw_index=u32(xml,p+8)
            dtype=xml[p+15];value=u32(xml,p+16)
            attrs[name]=strings[raw_index] if raw_index!=0xffffffff else strings[value] if dtype==3 else value
        if element=='manifest':manifest=attrs
        elif element=='uses-sdk':sdk=attrs
    pos+=size
assert manifest['package']=='cn.yooss.moodiary.v3dev'
assert manifest['versionCode']==expected_version
assert manifest['versionName'].startswith('2.9.2')
eocd=raw.rfind(b'PK\x05\x06');assert eocd>0
cd=u32(raw,eocd+16);assert raw[cd-16:cd]==b'APK Sig Block 42'
block_size=struct.unpack_from('<Q',raw,cd-24)[0]
p=cd-block_size;ids=[];cert_hash=None
while p<cd-24:
    size=struct.unpack_from('<Q',raw,p)[0];p+=8
    ident=u32(raw,p);value=raw[p+4:p+size];p+=size;ids.append(hex(ident))
    if ident==0x7109871a:
        def lp(data,offset):
            n=u32(data,offset);return data[offset+4:offset+4+n],offset+4+n
        signers,_=lp(value,0);signer,_=lp(signers,0)
        signed,_=lp(signer,0);_,offset=lp(signed,0)
        certificates,_=lp(signed,offset);cert,_=lp(certificates,0)
        cert_hash=hashlib.sha256(cert).hexdigest()
assert '0x7109871a' in ids or '0xf05368c0' in ids
print(json.dumps({'path':str(path),'size':len(raw),'sha256':digest,
    'package':manifest['package'],'versionCode':manifest['versionCode'],
    'versionName':manifest['versionName'],'abis':abis,'sdk':sdk,
    'signingBlockIds':ids,'signerCertificateSha256':cert_hash},ensure_ascii=False))
