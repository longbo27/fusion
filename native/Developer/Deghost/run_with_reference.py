"""Use the already installed golden cv2 extension in a separate training venv.
No installation or change to reference modules. Both environments must use the
same Python ABI. NumPy/SciPy/torch remain those of the training environment.
"""
import argparse,pathlib,runpy,sys
import numpy,scipy,torch
p=argparse.ArgumentParser();p.add_argument('--reference-site',required=True);p.add_argument('script',choices=['train','quality','annotations']);args,remaining=p.parse_known_args()
site=pathlib.Path(args.reference_site).resolve()
if not (site/'cv2').is_dir():raise ValueError('Existing reference cv2 extension required')
sys.path.append(str(site));sys.argv=[args.script+'.py']+remaining
runpy.run_path(str(pathlib.Path(__file__).with_name(args.script+'.py')),run_name='__main__')
