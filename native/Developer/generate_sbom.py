"""Developer-only bounded dependency inventory. Output belongs outside Git."""
import argparse, hashlib, importlib.metadata, json, pathlib, subprocess, os, re
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);args=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2]
if args.output.resolve().is_relative_to(root):raise SystemExit('Write generated SBOM outside the repository')
components=[]
for d in sorted(importlib.metadata.distributions(),key=lambda d:d.metadata['Name'].lower()):
    label=d.metadata.get('License-Expression') or d.metadata.get('License') or 'UNRECORDED'
    components.append({'type':'library','name':d.metadata['Name'],'version':d.version,'properties':[{'name':'license.metadata','value':label},{'name':'boundary','value':'developer/Python environment; not native runtime'}]})
vendor=root/'native/FocusStackCore/Vendor/libtiff';provenance=json.loads((vendor/'PROVENANCE.json').read_text());h=hashlib.sha256()
for f in sorted(vendor.rglob('*')):
    if f.is_file():h.update(str(f.relative_to(vendor)).encode());h.update(f.read_bytes())
components.append({'type':'library','name':'libtiff','version':provenance['version'],'hashes':[{'alg':'SHA-256','content':h.hexdigest()}],'properties':[{'name':'upstream.archive.sha256','value':provenance['sha256']},{'name':'license.notice','value':'Vendor/libtiff/LICENSE.md; Leffler-SGI and Berkeley-derived LZW'}]})
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
def info(cmd):
    try:return subprocess.check_output(cmd,env=env,text=True,stderr=subprocess.DEVNULL).strip()
    except (OSError,subprocess.CalledProcessError):return 'unavailable'
sdk=info(['xcrun','--show-sdk-path']);header=pathlib.Path(sdk)/'usr/include/zlib.h'
version=re.search(r'#define ZLIB_VERSION "([^"]+)"',header.read_text()).group(1) if header.exists() else 'unavailable'
components.append({'type':'library','name':'Apple system zlib','version':version,'properties':[{'name':'license','value':'zlib; system-linked through Apple SDK'},{'name':'sdk','value':info(['xcrun','--sdk','macosx','--show-sdk-version'])}]})
result={'bomFormat' :'CycloneDX','specVersion':'1.6','version':1,'components':components,'metadata':{'properties':[{'name':'scope','value':'Installed metadata inventory; not complete transitive compliance or legal clearance'},{'name':'compiler.swift','value':info(['swift','--version'])},{'name':'toolchain.xcode','value':info(['xcodebuild','-version'])}]}}
args.output.write_text(json.dumps(result,indent=2)+'\n');print(f'{len(components)} components recorded')
