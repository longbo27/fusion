"""Reproduce the pinned C source vendor. Run on Apple arm64 with Xcode selected.
Downloads/configures outside Git, copies only C/headers/license into Vendor.
Review an upstream update rather than silently changing this pin.
"""
import hashlib,pathlib,subprocess,tarfile,tempfile,urllib.request,shutil
version='4.7.2';expected='672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a'
root=pathlib.Path(__file__).resolve().parents[1]/'FocusStackCore'/'Vendor'/'libtiff'
with tempfile.TemporaryDirectory(prefix='FocusStack-libtiff-') as directory:
 p=pathlib.Path(directory);archive=p/'tiff.tar.gz';urllib.request.urlretrieve(f'https://download.osgeo.org/libtiff/tiff-{version}.tar.gz',archive)
 if hashlib.sha256(archive.read_bytes()).hexdigest()!=expected:raise ValueError('Upstream archive checksum mismatch')
 with tarfile.open(archive) as t:t.extractall(p,filter='data')
 source=p/f'tiff-{version}';subprocess.run(['./configure','--disable-shared','--disable-jpeg','--disable-old-jpeg','--disable-jbig','--disable-lzma','--disable-zstd','--disable-webp','--disable-lerc','--disable-libdeflate','--disable-tools','--disable-tests','--disable-contrib'],cwd=source,check=True)
 root.mkdir(parents=True,exist_ok=True);(root/'include').mkdir(exist_ok=True)
 for f in (source/'libtiff').iterdir():
  if f.suffix in ['.c','.h'] and f.name not in ['mkg3states.c','tif_win32.c','tif_vms.c']:shutil.copy2(f,root/f.name)
 for name in ['tiffio.h','tiff.h','tiffconf.h','tiffvers.h']:shutil.copy2(root/name,root/'include'/name)
 (root/'LICENSE.md').write_text('\n'.join(line.rstrip() for line in (source/'LICENSE.md').read_text().splitlines())+'\n')
print('Pinned C source regenerated; compare Git diff and build macOS/iOS before committing.')
