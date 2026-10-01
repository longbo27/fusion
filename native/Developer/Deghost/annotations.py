"""External, reviewable real-crop annotation format; never writes inside Git.
JSON polygons label STATIC=0, MOTION=1, IGNORE=255 and preferred source 0..3.
Unannotated pixels remain IGNORE; missing annotations are never treated as static.
"""
import argparse,json,pathlib,sys
import numpy as np,cv2
ROOT=pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT))
from focusstack.io import Source,inspect_image
from focusstack.sharpness import photographic_score,luminance
from dataset import features
import tempfile

def main():
 p=argparse.ArgumentParser();p.add_argument('--directory',required=True);p.add_argument('--inputs',nargs='+',required=True);p.add_argument('--transforms',required=True);p.add_argument('--region',nargs=4,type=int,metavar=('X','Y','WIDTH','HEIGHT'),required=True);p.add_argument('--annotations');p.add_argument('--split',choices=['train','validation'],required=True);p.add_argument('--group',required=True);args=p.parse_args()
 out=pathlib.Path(args.directory).resolve()
 if out.is_relative_to(ROOT):raise ValueError('Private crops/labels must be external')
 x,y,w,h=args.region
 if min(w,h)<16 or max(w,h)>512 or len(args.inputs)>4:raise ValueError('Bounded crop/at most four candidate sources required')
 transforms=np.asarray(json.loads(pathlib.Path(args.transforms).read_text()),np.float64);assert transforms.shape==(len(args.inputs),2,3)
 out.mkdir(parents=True,exist_ok=True);frames=[]
 with tempfile.TemporaryDirectory(prefix='FocusStack-annotation-') as scratch:
  for index,(path,matrix) in enumerate(zip(args.inputs,transforms)):
   source=Source(inspect_image(pathlib.Path(path)),scratch,index);rgb,valid=source.warp_tile(matrix,(y,y+h,x,x+w));frames.append(luminance(rgb)/65535);preview=(np.rint(rgb).clip(0,65535).astype(np.uint16)>>8).astype(np.uint8);cv2.imwrite(str(out/f'source-{index}.png'),preview[...,::-1])
 while len(frames)<4:frames.append(frames[-1])
 inputs,rank=features(frames);labels=np.full((h,w),255,np.uint8);owner=np.full((h,w),255,np.uint8)
 annotation=json.loads(pathlib.Path(args.annotations).read_text()) if args.annotations else {'regions':[]}
 for region in annotation['regions']:
  value={'static':0,'motion':1,'ignore':255}[region['label']];mask=np.zeros((h,w),np.uint8);cv2.fillPoly(mask,[np.array(region['polygon'],np.int32)],1);labels[mask!=0]=value
  preferred=region.get('preferredSource',255)
  if preferred!=255 and preferred not in range(len(args.inputs)):raise ValueError('Preferred source not captured')
  # Translate global source to candidate slot; dynamic reference ownership is 0.
  slot=np.where(preferred==0,0,np.where((rank==preferred).any(axis=0),np.argmax(rank==preferred,axis=0)+1,255)).astype(np.uint8);owner[mask!=0]=slot[mask!=0] if preferred!=255 else 255
 np.savez_compressed(out/'example.npz',features=inputs,motion=labels,ownership=owner)
 cv2.imwrite(str(out/'motion-labels.png'),labels);cv2.imwrite(str(out/'preferred-owner.png'),owner)
 (out/'annotation-template.json').write_text(json.dumps(annotation,indent=2));(out/'manifest.json').write_text(json.dumps(dict(split=args.split,group=args.group,reviewed=bool(annotation.get('reviewed',False)),shape=[h,w],region=args.region,inputs=args.inputs,note='Previews explicitly RGB16>>8; training/debug only, never production RGB.'),indent=2))
 print(out)
if __name__=='__main__':main()
