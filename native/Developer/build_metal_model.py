"""Build a Metal ML package using installed official Apple tooling.
Keeps the Xcode 27 separate-Metal-toolchain lookup workaround in a temporary tree;
never edits Xcode, xcode-select, installed tools, or system security settings.
"""
import argparse,pathlib,subprocess,tempfile,shutil
p=argparse.ArgumentParser();p.add_argument('model');p.add_argument('output');p.add_argument('--target',default='macos26.0',choices=['macos26.0','ios26.0']);args=p.parse_args()
tool=pathlib.Path(subprocess.check_output(['xcrun','-f','metal-package-builder'],text=True).strip())
command=['-ml','--mtargetos',args.target,str(pathlib.Path(args.model).resolve()),'-o',str(pathlib.Path(args.output).resolve())]
result=subprocess.run([str(tool)]+command,capture_output=True,text=True)
if result.returncode==0:print(result.stdout);raise SystemExit(0)
if 'could not find coremlcompiler' not in result.stderr:print(result.stderr);raise SystemExit(result.returncode)
compiler=pathlib.Path(subprocess.check_output(['xcrun','-f','coremlcompiler'],text=True).strip());metal=tool.parents[2];xcode=compiler.parents[2]
with tempfile.TemporaryDirectory(prefix='FocusStack-MetalToolchain-') as temp:
 base=pathlib.Path(temp)/'Toolchains';local=base/'Metal.xctoolchain';(local/'usr'/'bin').mkdir(parents=True)
 shutil.copy2(tool,local/'usr'/'bin'/tool.name);(base/'XcodeDefault.xctoolchain').symlink_to(xcode,target_is_directory=True)
 (local/'usr'/'lib').symlink_to(metal/'usr'/'lib',target_is_directory=True);(local/'System'/'Library').mkdir(parents=True)
 (local/'System'/'Library'/'PrivateFrameworks').symlink_to(metal/'System'/'Library'/'PrivateFrameworks',target_is_directory=True)
 subprocess.run([str(local/'usr'/'bin'/tool.name)]+command,check=True)
