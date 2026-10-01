from dataclasses import replace
import cv2
import numpy as np
import pytest
import tifffile
from focusstack import Config, FocusStackError, stack
from focusstack.depth import Candidates, regularize
from focusstack.downsample import AreaReducer
from focusstack.pyramid import laplacian_pyramid, reconstruct
from focusstack.memory import parse_budget, rss_to_bytes, decoder_requirement
from focusstack.sharpness import photographic_score


def cfg(tmp_path, **kwargs):
    settings = dict(quality="max", alignment="none", tile_size=96, temp_dir=tmp_path/"scratch")
    settings.update(kwargs)
    return Config(**settings)


def test_top_k_order_and_ties():
    top= Candidates((2, 3), 300)
    for index, score in [(0, 5), (256, 9), (8, 7), (9, 7), (4, 1)]:
        top.update(np.full((2, 3), score, np.float32), index)
    assert top.indices.dtype == np.uint16
    assert np.all(top.indices[:,0,0] == [256,8,9])
    assert np.all(top.scores[:,0,0] == [9,7,7])


def test_laplacian_reconstruction_and_negative_levels(scene):
    image=scene.astype(np.float32)
    lap=laplacian_pyramid(image,4)
    assert lap[0].min() < 0
    assert np.max(np.abs(reconstruct(lap)-image)) < 0.02


@pytest.mark.parametrize('quality',['high','max'])
def test_multiband_seams_determinism_focus(scene, planes, write_frames, tmp_path, quality):
    files=write_frames(planes,compression='zlib',rowsperstrip=16)
    c=cfg(tmp_path,quality=quality)
    a=stack(files,tmp_path/'tiles.tif',c)
    b=stack(files,tmp_path/'single.tif',replace(c,tile_size=512))
    x,y=tifffile.imread(a.output),tifffile.imread(b.output)
    delta=np.abs(x.astype(np.int32)-y.astype(np.int32))
    assert delta.max() <= 2, (delta.max(),np.quantile(delta,.99))
    repeated=stack(files,tmp_path/'repeat.tif',c)
    assert np.array_equal(x,tifffile.imread(repeated.output))
    mid=scene.shape[1]//2
    assert np.mean((x[20:-20,:mid-25].astype(np.float32)-scene[20:-20,:mid-25])**2) < 5e5


def test_twenty_sources(scene, write_frames, tmp_path):
    files=write_frames([scene]*20)
    result=stack(files,tmp_path/'twenty.tif',cfg(tmp_path,tile_size=512))
    assert result.frames == 20
    assert np.max(np.abs(tifffile.imread(result.output).astype(np.int32)-scene.astype(np.int32))) <= 1


def test_fast_downsampler_exact_bins(scene):
    reducer=AreaReducer(scene.shape,71)
    for y in range(0,scene.shape[0],23):
        for x in range(0,scene.shape[1],37):
            reducer.add(scene[y:y+23,x:x+37],y,x)
    expected=np.zeros((reducer.rh,reducer.rw),np.float32)
    counts=np.zeros_like(expected)
    gray=cv2.cvtColor((scene>>8).astype(np.uint8),cv2.COLOR_RGB2GRAY)
    yy=np.arange(gray.shape[0])*reducer.rh//gray.shape[0]
    xx=np.arange(gray.shape[1])*reducer.rw//gray.shape[1]
    bins=(yy[:,None]*reducer.rw+xx[None,:]).ravel()
    np.add.at(expected.ravel(),bins,gray.ravel())
    np.add.at(counts.ravel(),bins,1)
    assert np.array_equal(reducer.finish(),np.rint(expected/counts).astype(np.uint8))


def test_budget_auto_manual(scene, write_frames, tmp_path):
    assert parse_budget('8G') == 8*1024**3
    assert parse_budget('512MiB') == 512*1024**2
    with pytest.raises(FocusStackError): parse_budget('wrong')
    with pytest.raises(FocusStackError): parse_budget('1M')
    paths=write_frames([scene])
    result=stack(paths,tmp_path/'auto.tif',cfg(tmp_path,tile_size='auto',memory_budget='512M'))
    assert result.tile_size in [512,1024,1536,2048]
    assert result.budget_bytes <= 512*1024**2
    with pytest.raises(FocusStackError, match='working RAM'):
        stack(paths,tmp_path/'bad.tif',cfg(tmp_path,tile_size=2048,memory_budget='512M'))


def test_dynamic_large_segment():
    from focusstack.memory import plan_resources
    from types import SimpleNamespace
    info=SimpleNamespace(shape=(8300,12000,3),raw_bytes=597600000,mappable=False,
        max_segment_bytes=597600000,decoded_segment_bytes=597600000,encoded_segment_bytes=200000000)
    assert decoder_requirement(info) < 2*1024**3


def test_lazy_reference_fallback(scene,tmp_path):
    from focusstack.fusion import fuse_tile
    class Source:
        def __init__(self): self.calls=0
        def warp_tile(self,matrix,bounds):
            self.calls+=1
            return scene.copy(),np.ones(scene.shape[:2],bool)
    source=Source()
    fuse_tile([source],[np.eye(2,3)],(0,257,0,321),cfg(tmp_path),0)
    assert source.calls==2  # focus and fusion; no unconditional third read


def test_portable_rss():
    assert rss_to_bytes(100,'darwin')==100
    assert rss_to_bytes(100,'linux')==102400


def test_cache_analysis_no_full_rescan(scene,write_frames,tmp_path):
    from focusstack.io import Source,inspect_image
    files=write_frames([scene],compression='zlib',rowsperstrip=16)
    source=Source(inspect_image(files[0]),tmp_path,0,analysis_bound=128)
    try:
        assert source.analysis_path.exists()
        source.array=None  # Any full-resolution reread would now fail.
        assert max(source.reduced_gray(128).shape)==128
    finally:
        source.close()


def test_noise_focus_penalty(scene):
    rng=np.random.default_rng(22)
    clean=cv2.GaussianBlur(scene,(5,5),1)
    noisy=np.clip(clean.astype(np.float32)+rng.normal(0,7500,clean.shape),0,65535).astype(np.uint16)
    a,_=photographic_score(scene,3,'max')
    b,_=photographic_score(noisy,3,'max')
    assert np.mean(a[20:-20,20:-20]) > np.mean(b[20:-20,20:-20])*1.5


@pytest.mark.parametrize('bright',[False,True])
def test_occlusion_halo_and_thin_structure_improve(tmp_path, bright):
    from benchmarks.quality import occlusion_scene
    truth,frames,boundary,thin=occlusion_scene(bright)
    files=[]
    for index,frame in enumerate(frames):
        p=tmp_path/f'frame-{index}.tif'
        tifffile.imwrite(p,frame,photometric='rgb',metadata=None)
        files.append(p)
    errors={}
    for quality in ('standard','max'):
        result=stack(files,tmp_path/f'{quality}.tif',cfg(tmp_path,quality=quality,tile_size=128))
        image=tifffile.imread(result.output)
        error=(image.astype(np.float32)-truth)**2
        errors[quality]=error
    assert errors['max'][boundary].mean() < errors['standard'][boundary].mean()*.9
    assert errors['max'].mean() < errors['standard'].mean()*.9
    assert errors['max'][thin].max() <= 1


def test_crossing_focus_regions(scene, write_frames, tmp_path):
    y,x=np.indices(scene.shape[:2])
    mask=(x-160)*(y-128)>0
    blurred=cv2.GaussianBlur(scene,(17,17),3)
    a=np.where(mask[...,None],scene,blurred)
    b=np.where(mask[...,None],blurred,scene)
    result=stack(write_frames([a,b]),tmp_path/'crossing.tif',cfg(tmp_path,tile_size=96))
    image=tifffile.imread(result.output)
    away=(np.abs(x-160)>25)&(np.abs(y-128)>25)
    error=np.mean((image[away].astype(np.float32)-scene[away])**2)
    blurred_error=np.mean((blurred[away].astype(np.float32)-scene[away])**2)
    assert error < blurred_error*.01


def test_ambiguous_regions_coherent(write_frames, tmp_path):
    a=np.full((91,103,3),24000,np.uint16)
    b=np.full_like(a,30000)
    result=stack(write_frames([a,b]),tmp_path/'ambiguous.tif',cfg(tmp_path,tile_size=32))
    assert np.array_equal(tifffile.imread(result.output),a)


def test_noisy_source_actual_fusion(scene, write_frames, tmp_path):
    rng=np.random.default_rng(22)
    blurry=cv2.GaussianBlur(scene,(5,5),1)
    noisy=np.clip(blurry.astype(np.float32)+rng.normal(0,7500,scene.shape),0,65535).astype(np.uint16)
    paths=write_frames([scene,noisy])
    errors={}
    for quality in ('standard','max'):
        result=stack(paths,tmp_path/f'{quality}.tif',cfg(tmp_path,quality=quality))
        image=tifffile.imread(result.output)
        errors[quality]=np.mean((image.astype(np.float32)-scene)**2)
    assert errors['max'] < errors['standard']*.3


def test_similarity_refinement_diagnostics(scene):
    from focusstack.alignment import estimate_detailed
    gray=cv2.cvtColor((scene>>8).astype(np.uint8),cv2.COLOR_RGB2GRAY)
    forward=cv2.getRotationMatrix2D((160,128),3,1.04)
    source=cv2.warpAffine(gray,forward,gray.shape[::-1],borderMode=cv2.BORDER_REFLECT_101)
    matrix,score,method,diag=estimate_detailed(gray,source,'affine')
    assert 'similarity-ECC' in method
    assert diag['source_features']>10 and diag['inliers']>6 and diag['inlier_ratio']>.5
    assert np.allclose(matrix[0,0],matrix[1,1],atol=1e-7)
    assert np.allclose(matrix[0,1],-matrix[1,0],atol=1e-7)
    assert diag['verified_shape']==list(gray.shape)


def test_dynamic_segment_accept_reject(scene, write_frames, tmp_path):
    from focusstack.io import Source,inspect_image
    paths=write_frames([scene],compression='zlib',rowsperstrip=scene.shape[0],bigtiff=True)
    info=inspect_image(paths[0])
    source=Source(info,tmp_path,0,decoder_budget=512*1024**2)
    source.close()
    with pytest.raises(FocusStackError,match='dynamic decoder budget'):
        Source(info,tmp_path,1,decoder_budget=1)


def test_eviction_unsupported(monkeypatch):
    import focusstack.memory as memory
    class Map:
        def madvise(self,*args): raise OSError('unsupported')
    memory.advise(Map())
    monkeypatch.delattr(memory.mmap,'MADV_DONTNEED',raising=False)
    memory.advise(Map())


def test_interrupted_max_output_cleanup(scene,write_frames,tmp_path,monkeypatch):
    import focusstack.engine as engine
    output=tmp_path/'output.tif'
    output.write_bytes(b'previous')
    def interrupt(*args): raise KeyboardInterrupt()
    monkeypatch.setattr(engine,'fuse_tile',interrupt)
    with pytest.raises(KeyboardInterrupt):
        stack(write_frames([scene],compression='zlib',rowsperstrip=16),output,cfg(tmp_path))
    assert output.read_bytes()==b'previous'
    assert not list((tmp_path/'scratch').iterdir())


def test_max_cli_report(scene,write_frames,tmp_path):
    import subprocess,sys,json
    files=write_frames([scene])
    report=tmp_path/'report.json'
    call=subprocess.run([sys.executable,'-m','focusstack',str(files[0]),'-o',str(tmp_path/'max.tif'),
        '--quality','max','--tile-size','auto','--memory-budget','512M','--report-json',str(report),
        '--benchmark-stages'],capture_output=True,text=True)
    assert call.returncode==0,call.stderr
    data=json.loads(report.read_text())
    assert data['timings']['fusion']>0 and data['timings']['output_validation']>0
    assert data['budget_bytes']<=512*1024**2


def test_max_affine_tile_seams(scene,write_frames,tmp_path):
    matrix=cv2.getRotationMatrix2D((160,128),2.2,1.035)
    matrix[:,2]+=[3,-2]
    shifted=cv2.warpAffine(scene,matrix,scene.shape[1::-1])
    files=write_frames([shifted,scene])
    c=cfg(tmp_path,alignment='affine',reference=1,tile_size=96)
    a=stack(files,tmp_path/'a.tif',c)
    b=stack(files,tmp_path/'b.tif',replace(c,tile_size=512))
    error=np.abs(tifffile.imread(a.output).astype(np.int32)-tifffile.imread(b.output).astype(np.int32))
    assert np.quantile(error,.999) <= 2


def test_realistic_large_segment_budget_planner(tmp_path,monkeypatch):
    import focusstack.memory as memory
    from types import SimpleNamespace
    monkeypatch.setattr(memory,'available_memory',lambda:(16*1024**3,12*1024**3))
    monkeypatch.setattr(memory.shutil,'disk_usage',lambda p:SimpleNamespace(free=100*1024**3))
    info=SimpleNamespace(shape=(8300,12000,3),raw_bytes=597600000,mappable=False,
        max_segment_bytes=597600000,decoded_segment_bytes=597600000,encoded_segment_bytes=580000000)
    plan=memory.plan_resources([info],cfg(tmp_path,tile_size='auto'),tmp_path,tmp_path)
    assert plan.budget_bytes==4*1024**3 and plan.decoder_bytes>1024**3
    with pytest.raises(FocusStackError,match='dynamic decoder budget'):
        memory.plan_resources([info],cfg(tmp_path,tile_size=512,memory_budget='1G'),tmp_path,tmp_path)


def test_max_source_index_above_255(scene,tmp_path):
    from focusstack.fusion import fuse_tile
    sharp=scene[:32,:32]
    blurred=cv2.GaussianBlur(sharp,(17,17),3)
    class Source:
        def __init__(self,rgb):self.rgb=rgb
        def warp_tile(self,m,b):return self.rgb.copy(),np.ones((32,32),bool)
    sources=[Source(blurred)]*256+[Source(sharp)]
    image=fuse_tile(sources,[np.eye(2,3)]*257,(0,32,0,32),cfg(tmp_path),256)
    assert np.array_equal(image[10:-10,10:-10],sharp[10:-10,10:-10])


def test_alignment_consumes_generated_resolution(scene,write_frames,tmp_path,monkeypatch):
    from focusstack.io import Source
    original=Source.reduced_gray
    bounds=[]
    def record(self,bound):
        bounds.append(bound)
        return original(self,bound)
    monkeypatch.setattr(Source,'reduced_gray',record)
    stack(write_frames([scene,scene]),tmp_path/'aligned.tif',cfg(tmp_path,alignment='affine',alignment_max_dim=4096))
    assert bounds == [2048,2048]


def test_report_cannot_overwrite_input_directory_file(scene,write_frames,tmp_path):
    import subprocess,sys
    files=write_frames([scene])
    original=files[0].read_bytes()
    call=subprocess.run([sys.executable,'-m','focusstack',str(tmp_path),'-o',str(tmp_path/'out.tif'),
                         '--report-json',str(files[0])],capture_output=True,text=True)
    assert call.returncode==2 and files[0].read_bytes()==original
    assert not (tmp_path/'out.tif').exists()


def test_single_source_skips_alignment_rescan(scene,write_frames,tmp_path,monkeypatch):
    from focusstack.io import Source
    def fail(*args):raise AssertionError('single frame needs no alignment analysis')
    monkeypatch.setattr(Source,'reduced_gray',fail)
    result=stack(write_frames([scene]),tmp_path/'one.tif',cfg(tmp_path,alignment='affine'))
    assert result.timings['alignment_images']==0 and result.timings['feature_alignment']==0


def test_macos_style_file_limit(monkeypatch):
    import focusstack.memory as memory
    changed=[]
    monkeypatch.setattr(memory.resource,'getrlimit',lambda _: (256,4096))
    monkeypatch.setattr(memory.resource,'setrlimit',lambda key,value: changed.append(value))
    memory.ensure_fd_capacity(300)
    assert changed==[(364,4096)]
    monkeypatch.setattr(memory.resource,'getrlimit',lambda _: (256,256))
    with pytest.raises(FocusStackError,match='File descriptor limit'):
        memory.ensure_fd_capacity(300)


def test_auto_budget_reserves_actual_available_memory(monkeypatch):
    import focusstack.memory as memory
    monkeypatch.setattr(memory,'available_memory',lambda:(2*1024**3,1024**3))
    assert memory.effective_budget('auto')==int(.6*1024**3)
    assert memory.effective_budget('8G')==int(.6*1024**3)


def test_cgroup_clean_active_cache_is_available(monkeypatch):
    import focusstack.memory as memory
    from types import SimpleNamespace
    gib=1024**3
    monkeypatch.setattr(memory.psutil,'virtual_memory',lambda:SimpleNamespace(total=16*gib,available=12*gib))
    monkeypatch.setattr(memory.sys,'platform','linux')
    values={'memory.max':str(8*gib),'memory.current':str(6*gib),
        'memory.stat':f'inactive_file {gib}\nactive_file {4*gib}\nfile_dirty {gib}\nfile_writeback 0\n'}
    monkeypatch.setattr(memory.Path,'read_text',lambda self:values[self.name])
    assert memory.available_memory()==(8*gib,6*gib)


def test_pyramidal_layout_rejected(scene,tmp_path):
    from focusstack.io import inspect_image
    p=tmp_path/'pyramid.tif'
    with tifffile.TiffWriter(p) as writer:
        writer.write(scene,photometric='rgb',subifds=1,metadata=None)
        writer.write(scene[::2,::2],photometric='rgb',subfiletype=1,metadata=None)
    with pytest.raises(FocusStackError,match='pyramidal'):
        inspect_image(p)


def test_extremely_wide_output_row_is_budgeted(tmp_path,monkeypatch):
    import focusstack.memory as memory
    from types import SimpleNamespace
    monkeypatch.setattr(memory,'available_memory',lambda:(16*1024**3,12*1024**3))
    info=SimpleNamespace(shape=(1,100000000,3),raw_bytes=600000000,mappable=True)
    with pytest.raises(FocusStackError,match='Output strip row'):
        memory.plan_resources([info],cfg(tmp_path,tile_size=512,memory_budget='512M'),tmp_path,tmp_path)


def test_cleanup_never_chooses_invalid_warp_candidate():
    top=Candidates((5,5),2)
    top.scores[0]=100
    top.indices[0]=0
    top.scores[0,2,2]=0
    top.indices[0,2,2]=1
    # Neighbors favor 0 but source 0 does not cover the center; its slots are -1.
    labels,_=regularize(top,np.zeros((5,5),np.float32),np.zeros((5,5),np.float32))
    assert labels[2,2]==1


def test_interrupted_cache_closes_unappended_mapping(scene,write_frames,tmp_path,monkeypatch):
    import focusstack.io as io
    files=write_frames([scene],compression='zlib',rowsperstrip=16)
    created=[]
    original=np.memmap
    def capture(*args,**kwargs):
        array=original(*args,**kwargs)
        created.append(array)
        return array
    def interrupt(*args,**kwargs):raise KeyboardInterrupt()
    monkeypatch.setattr(io.np,'memmap',capture)
    monkeypatch.setattr(tifffile.TiffPage,'segments',interrupt)
    with pytest.raises(KeyboardInterrupt):
        stack(files,tmp_path/'output.tif',cfg(tmp_path))
    assert created and created[0]._mmap.closed
    assert not list((tmp_path/'scratch').iterdir())


@pytest.mark.parametrize('dtype',[np.uint16,np.uint8])
def test_warp_keeps_subpixel_precision_until_fusion(tmp_path,dtype):
    from focusstack.io import Source,inspect_image
    y,x=np.indices((16,16))
    gray=(x*3+y*2+1).astype(dtype)
    frame=np.repeat(gray[...,None],3,axis=2)
    path=tmp_path/'precision.tif'
    tifffile.imwrite(path,frame,photometric='rgb',metadata=None)
    source=Source(inspect_image(path),tmp_path,0)
    try:
        matrix=np.array([[1,0,.25],[0,1,0]],np.float64)
        rgb,valid=source.warp_tile(matrix,(4,12,4,12))
        assert rgb.dtype==np.float32
        expected=(8*3+8*2+1-.25*3)*(257 if dtype==np.uint8 else 1)
        assert rgb[4,4,0]==pytest.approx(expected,abs=.001)
        assert source.array.dtype==np.dtype(dtype)
    finally:
        source.close()
