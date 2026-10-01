#include "CTIFFBridge.h"
#include <tiffio.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <fcntl.h>
#include <limits.h>

struct FSTiff { TIFF *tif; FSTiffInfo info; char error[1024]; };
static int fs_error_handler(TIFF *tif, void *ctx, const char *module, const char *fmt, va_list args) {
 (void)tif;(void)module; FSTiff *f=ctx; vsnprintf(f->error,sizeof(f->error),fmt,args); return 1;
}
static int fs_warning_handler(TIFF *tif, void *ctx, const char *module, const char *fmt, va_list args) {
 (void)tif;(void)ctx;(void)module;(void)fmt;(void)args; return 1;
}
static int fail(FSTiff *f,const char *s) { snprintf(f->error,sizeof(f->error),"%s",s);return 0; }
static TIFF *open_checked(FSTiff *f,const char *path,const char *mode,uint64_t limit) {
 TIFFOpenOptions *o=TIFFOpenOptionsAlloc();if(!o)return NULL;
 tmsize_t max=limit>INT64_MAX?INT64_MAX:(tmsize_t)limit;
 TIFFOpenOptionsSetMaxSingleMemAlloc(o,max);TIFFOpenOptionsSetMaxCumulatedMemAlloc(o,max);
 TIFFOpenOptionsSetErrorHandlerExtR(o,fs_error_handler,f);TIFFOpenOptionsSetWarningHandlerExtR(o,fs_warning_handler,f);
 TIFF *t=TIFFOpenExt(path,mode,o);TIFFOpenOptionsFree(o);return t;
}
FSTiff *fs_tiff_open(const char *path,uint64_t limit,char *error,size_t error_size) {
 FSTiff *f=calloc(1,sizeof(*f));if(!f)return NULL;
 // c: retain actual strip table, m: never mmap the entire source. Uncompressed
 // giant strips are read through bounded pread row spans below, not codec APIs.
 f->tif=open_checked(f,path,"rcm",limit);
 if(!f->tif){snprintf(error,error_size,"%s",f->error);free(f);return NULL;}
 FSTiffInfo *i=&f->info;uint16_t photo=0,planar=0,format=0;
 TIFFGetField(f->tif,TIFFTAG_IMAGEWIDTH,&i->raw_width);TIFFGetField(f->tif,TIFFTAG_IMAGELENGTH,&i->raw_height);
 TIFFGetFieldDefaulted(f->tif,TIFFTAG_BITSPERSAMPLE,&i->bits);TIFFGetFieldDefaulted(f->tif,TIFFTAG_SAMPLESPERPIXEL,&i->channels);
 TIFFGetFieldDefaulted(f->tif,TIFFTAG_ORIENTATION,&i->orientation);TIFFGetFieldDefaulted(f->tif,TIFFTAG_COMPRESSION,&i->compression);
 TIFFGetFieldDefaulted(f->tif,TIFFTAG_PHOTOMETRIC,&photo);TIFFGetFieldDefaulted(f->tif,TIFFTAG_PLANARCONFIG,&planar);
 TIFFGetFieldDefaulted(f->tif,TIFFTAG_SAMPLEFORMAT,&format);TIFFGetFieldDefaulted(f->tif,TIFFTAG_RESOLUTIONUNIT,&i->resolution_unit);
 float rx=0,ry=0;TIFFGetField(f->tif,TIFFTAG_XRESOLUTION,&rx);TIFFGetField(f->tif,TIFFTAG_YRESOLUTION,&ry);i->dpi_x=rx;i->dpi_y=ry;
 i->tiled=TIFFIsTiled(f->tif);i->big=TIFFIsBigTIFF(f->tif);
 if(i->tiled){TIFFGetField(f->tif,TIFFTAG_TILEWIDTH,&i->tile_width);TIFFGetField(f->tif,TIFFTAG_TILELENGTH,&i->tile_height);i->segments=TIFFNumberOfTiles(f->tif);}
 else {TIFFGetFieldDefaulted(f->tif,TIFFTAG_ROWSPERSTRIP,&i->rows_per_strip);i->segments=TIFFNumberOfStrips(f->tif);}
 if(!i->raw_width||!i->raw_height||i->channels!=3||(i->bits!=8&&i->bits!=16)||photo!=PHOTOMETRIC_RGB||planar!=PLANARCONFIG_CONTIG||format!=SAMPLEFORMAT_UINT||i->orientation<1||i->orientation>8||!TIFFIsCODECConfigured(i->compression)||
   (i->compression!=COMPRESSION_NONE&&i->compression!=COMPRESSION_LZW&&i->compression!=COMPRESSION_ADOBE_DEFLATE&&i->compression!=COMPRESSION_DEFLATE)) {
  snprintf(error,error_size,"Unsupported TIFF layout/codec; require contiguous unsigned RGB8/RGB16, orientation 1–8, None/Deflate/LZW");fs_tiff_close(f);return NULL;
 }
 i->width=i->orientation>=5?i->raw_height:i->raw_width;i->height=i->orientation>=5?i->raw_width:i->raw_height;
 return f;
}
void fs_tiff_close(FSTiff *f){if(f){if(f->tif)TIFFClose(f->tif);free(f);}}
const char *fs_tiff_error(FSTiff *f){return f?f->error:"TIFF allocation failed";}
int fs_tiff_info(FSTiff *f,FSTiffInfo *i){if(!f||!i)return 0;*i=f->info;return 1;}
const void *fs_tiff_icc(FSTiff *f,uint32_t *length){void *p=NULL;*length=0;TIFFGetField(f->tif,TIFFTAG_ICCPROFILE,length,&p);return p;}
const char *fs_tiff_text(FSTiff *f,uint32_t tag){char *p=NULL;if(tag!=TIFFTAG_ARTIST&&tag!=TIFFTAG_COPYRIGHT&&tag!=TIFFTAG_IMAGEDESCRIPTION)return NULL;TIFFGetField(f->tif,tag,&p);return p;}
static void to_raw(FSTiff *f,uint32_t x,uint32_t y,uint32_t *sx,uint32_t *sy) {
 uint32_t w=f->info.raw_width,h=f->info.raw_height;
 switch(f->info.orientation){case 1:*sx=x;*sy=y;break;case 2:*sx=w-1-x;*sy=y;break;case 3:*sx=w-1-x;*sy=h-1-y;break;case 4:*sx=x;*sy=h-1-y;break;case 5:*sx=y;*sy=x;break;case 6:*sx=y;*sy=h-1-x;break;case 7:*sx=w-1-y;*sy=h-1-x;break;default:*sx=w-1-y;*sy=x;}
}
static void from_raw(FSTiff *f,uint32_t sx,uint32_t sy,uint32_t *x,uint32_t *y) {
 uint32_t w=f->info.raw_width,h=f->info.raw_height;
 switch(f->info.orientation){case 1:*x=sx;*y=sy;break;case 2:*x=w-1-sx;*y=sy;break;case 3:*x=w-1-sx;*y=h-1-sy;break;case 4:*x=sx;*y=h-1-sy;break;case 5:*x=sy;*y=sx;break;case 6:*x=h-1-sy;*y=sx;break;case 7:*x=h-1-sy;*y=w-1-sx;break;default:*x=sy;*y=w-1-sx;}
}
static int rectangle(FSTiff *f,uint32_t x,uint32_t y,uint32_t w,uint32_t h,uint32_t *bx,uint32_t *by,uint32_t *bw,uint32_t *bh) {
 if(!w||!h||w>f->info.width||h>f->info.height||x>f->info.width-w||y>f->info.height-h)return fail(f,"ROI outside oriented source");
 uint32_t sx0,sy0,sx1,sy1;to_raw(f,x,y,&sx0,&sy0);to_raw(f,x+w-1,y+h-1,&sx1,&sy1);
 *bx=sx0<sx1?sx0:sx1;*by=sy0<sy1?sy0:sy1;*bw=(sx0>sx1?sx0-sx1:sx1-sx0)+1;*bh=(sy0>sy1?sy0-sy1:sy1-sy0)+1;return 1;
}
int fs_tiff_plan(FSTiff *f,uint32_t x,uint32_t y,uint32_t w,uint32_t h,FSDecodePlan *p) {
 uint32_t bx,by,bw,bh;if(!rectangle(f,x,y,w,h,&bx,&by,&bw,&bh))return 0;memset(p,0,sizeof(*p));
 uint64_t bytes=(uint64_t)f->info.bits/8*3;
 p->direct_rows=!f->info.tiled&&f->info.compression==COMPRESSION_NONE;
 if(p->direct_rows){p->decoded_bytes=(uint64_t)bw*bytes;p->segments=(by+bh-1)/f->info.rows_per_strip-by/f->info.rows_per_strip+1;}
 else if(f->info.tiled){
  p->decoded_bytes=TIFFTileSize64(f->tif);
  for(uint32_t ty=by/f->info.tile_height;ty<=(by+bh-1)/f->info.tile_height;ty++)for(uint32_t tx=bx/f->info.tile_width;tx<=(bx+bw-1)/f->info.tile_width;tx++){
   uint32_t s=TIFFComputeTile(f->tif,tx*f->info.tile_width,ty*f->info.tile_height,0,0);uint64_t encoded=TIFFGetStrileByteCount(f->tif,s);if(encoded>p->encoded_bytes)p->encoded_bytes=encoded;p->segments++;
  }
 }else {
  for(uint32_t s=by/f->info.rows_per_strip;s<=(by+bh-1)/f->info.rows_per_strip;s++){
   uint32_t rows=f->info.rows_per_strip;uint64_t remain=(uint64_t)f->info.raw_height-(uint64_t)s*rows;if(remain<rows)rows=(uint32_t)remain;
   uint64_t decoded=TIFFVStripSize64(f->tif,rows),encoded=TIFFGetStrileByteCount(f->tif,s);
   if(decoded>p->decoded_bytes)p->decoded_bytes=decoded;if(encoded>p->encoded_bytes)p->encoded_bytes=encoded;p->segments++;
  }
 }
 uint64_t output, decoded, encoded, sum;
 if(p->decoded_bytes>INT64_MAX||p->encoded_bytes>INT64_MAX||
    __builtin_mul_overflow((uint64_t)w,(uint64_t)h,&output)||__builtin_mul_overflow(output,(uint64_t)8,&output)||
    __builtin_mul_overflow(p->decoded_bytes,(uint64_t)3,&decoded)||__builtin_mul_overflow(p->encoded_bytes,(uint64_t)2,&encoded)||
    __builtin_add_overflow(output,decoded,&sum)||__builtin_add_overflow(sum,encoded,&sum)||
    __builtin_add_overflow(sum,(uint64_t)32*1024*1024,&p->planned_bytes))return fail(f,"Codec segment size overflow");
 return 1;
}
static int pread_all(int fd,void *dst,size_t count,uint64_t offset){uint8_t *p=dst;while(count){ssize_t n=pread(fd,p,count,(off_t)offset);if(n<=0)return 0;p+=n;count-=(size_t)n;offset+=(size_t)n;}return 1;}
static void put_pixel(FSTiff *f,const uint8_t *p,int swapped,uint32_t sx,uint32_t sy,uint32_t x,uint32_t y,uint32_t width,uint16_t *out){
 uint32_t ox,oy;from_raw(f,sx,sy,&ox,&oy);uint16_t *dst=out+((uint64_t)(oy-y)*width+ox-x)*4;
 if(f->info.bits==8){for(int c=0;c<3;c++)dst[c]=(uint16_t)p[c]*257;}
 else {for(int c=0;c<3;c++){uint16_t v;memcpy(&v,p+2*c,2);dst[c]=swapped?(uint16_t)((v>>8)|(v<<8)):v;}}
 dst[3]=65535;
}
int fs_tiff_read(FSTiff *f,uint32_t x,uint32_t y,uint32_t w,uint32_t h,uint16_t *out,uint64_t budget){
 FSDecodePlan plan;if(!fs_tiff_plan(f,x,y,w,h,&plan))return 0;if(plan.planned_bytes>budget)return fail(f,"Codec admission rejected: decoded/encoded buffers + margin exceed available budget");
 uint32_t bx,by,bw,bh;rectangle(f,x,y,w,h,&bx,&by,&bw,&bh);uint64_t bpp=(uint64_t)f->info.bits/8*3;
 uint8_t *buffer=malloc((size_t)plan.decoded_bytes);if(!buffer)return fail(f,"Segment allocation failed");int success=1;
 if(plan.direct_rows){
  for(uint32_t sy=by;sy<by+bh;sy++){
   uint32_t strip=sy/f->info.rows_per_strip;uint64_t row=(uint64_t)(sy%f->info.rows_per_strip)*f->info.raw_width*bpp;
   uint64_t offset=TIFFGetStrileOffset(f->tif,strip),bytes=TIFFGetStrileByteCount(f->tif,strip),needed=row+(uint64_t)(bx+bw)*bpp;
   if(needed>bytes||!pread_all(TIFFFileno(f->tif),buffer,(size_t)(bw*bpp),offset+row+(uint64_t)bx*bpp)){success=fail(f,"Uncompressed row read is truncated");break;}
   for(uint32_t sx=bx;sx<bx+bw;sx++)put_pixel(f,buffer+(sx-bx)*bpp,TIFFIsByteSwapped(f->tif),sx,sy,x,y,w,out);
  }
 }else if(f->info.tiled){
  for(uint32_t ty=by/f->info.tile_height;success&&ty<=(by+bh-1)/f->info.tile_height;ty++)for(uint32_t tx=bx/f->info.tile_width;tx<=(bx+bw-1)/f->info.tile_width;tx++){
   uint32_t xx=tx*f->info.tile_width,yy=ty*f->info.tile_height,s=TIFFComputeTile(f->tif,xx,yy,0,0);
   if(TIFFReadEncodedTile(f->tif,s,buffer,(tmsize_t)plan.decoded_bytes)!=(tmsize_t)plan.decoded_bytes){success=fail(f,"Tile decode failed/short");break;}
   uint32_t x0=bx>xx?bx:xx,y0=by>yy?by:yy,x1=bx+bw<xx+f->info.tile_width?bx+bw:xx+f->info.tile_width,y1=by+bh<yy+f->info.tile_height?by+bh:yy+f->info.tile_height;
   for(uint32_t sy=y0;sy<y1;sy++)for(uint32_t sx=x0;sx<x1;sx++)put_pixel(f,buffer+((uint64_t)(sy-yy)*f->info.tile_width+sx-xx)*bpp,0,sx,sy,x,y,w,out);
  }
 }else {
  for(uint32_t s=by/f->info.rows_per_strip;success&&s<=(by+bh-1)/f->info.rows_per_strip;s++){
   uint32_t yy=s*f->info.rows_per_strip,rows=f->info.rows_per_strip;if(rows>f->info.raw_height-yy)rows=f->info.raw_height-yy;
   uint64_t decoded=TIFFVStripSize64(f->tif,rows);
   if(TIFFReadEncodedStrip(f->tif,s,buffer,(tmsize_t)decoded)!=(tmsize_t)decoded){success=fail(f,"Strip decode failed/short");break;}
   uint32_t y0=by>yy?by:yy,y1=by+bh<yy+rows?by+bh:yy+rows;
   for(uint32_t sy=y0;sy<y1;sy++)for(uint32_t sx=bx;sx<bx+bw;sx++)put_pixel(f,buffer+((uint64_t)(sy-yy)*f->info.raw_width+sx)*bpp,0,sx,sy,x,y,w,out);
  }
 }
 free(buffer);return success;
}
static int fill_raw(int fd,uint8_t *buffer,uint32_t width,uint32_t height,uint32_t x,uint32_t y,uint32_t block_width,uint32_t block_height){
 memset(buffer,0,(size_t)block_width*block_height*6);
 uint32_t rows=block_height<height-y?block_height:height-y,cols=block_width<width-x?block_width:width-x;
 for(uint32_t row=0;row<rows;row++)if(!pread_all(fd,buffer+(uint64_t)row*block_width*6,(size_t)cols*6,((uint64_t)(y+row)*width+x)*6))return 0;return 1;
}
int fs_write_tiff_from_raw(const char *raw,const char *temporary,uint32_t width,uint32_t height,uint16_t compression,uint32_t edge,uint32_t rps,int big,const void *icc,uint32_t icc_size,double dx,double dy,uint16_t unit,const char *artist,const char *copyright,const char *description,uint64_t budget,char *error,size_t error_size){
 FSTiff f={0};int fd=open(raw,O_RDONLY);if(fd<0){snprintf(error,error_size,"Cannot open raw staging");return 0;}
 uint64_t pixels=(uint64_t)width*height;if(pixels>(UINT64_MAX-1048576)/12){close(fd);return 0;}
 f.tif=open_checked(&f,temporary,(big||pixels*12+1048576>UINT32_MAX)?"w8":"w",budget);
 if(!f.tif){snprintf(error,error_size,"%s",f.error);close(fd);return 0;}
 int ok=TIFFSetField(f.tif,TIFFTAG_IMAGEWIDTH,width)&&TIFFSetField(f.tif,TIFFTAG_IMAGELENGTH,height)&&TIFFSetField(f.tif,TIFFTAG_SAMPLESPERPIXEL,3)&&TIFFSetField(f.tif,TIFFTAG_BITSPERSAMPLE,16)&&TIFFSetField(f.tif,TIFFTAG_SAMPLEFORMAT,SAMPLEFORMAT_UINT)&&TIFFSetField(f.tif,TIFFTAG_PHOTOMETRIC,PHOTOMETRIC_RGB)&&TIFFSetField(f.tif,TIFFTAG_PLANARCONFIG,PLANARCONFIG_CONTIG)&&TIFFSetField(f.tif,TIFFTAG_ORIENTATION,1)&&TIFFSetField(f.tif,TIFFTAG_COMPRESSION,compression);
 if(edge)ok=ok&&TIFFSetField(f.tif,TIFFTAG_TILEWIDTH,edge)&&TIFFSetField(f.tif,TIFFTAG_TILELENGTH,edge);else ok=ok&&TIFFSetField(f.tif,TIFFTAG_ROWSPERSTRIP,rps);
 if(compression!=COMPRESSION_NONE)ok=ok&&TIFFSetField(f.tif,TIFFTAG_PREDICTOR,PREDICTOR_HORIZONTAL);
 if(icc_size)ok=ok&&TIFFSetField(f.tif,TIFFTAG_ICCPROFILE,icc_size,icc);
 if(dx>0&&dy>0)ok=ok&&TIFFSetField(f.tif,TIFFTAG_XRESOLUTION,dx)&&TIFFSetField(f.tif,TIFFTAG_YRESOLUTION,dy)&&TIFFSetField(f.tif,TIFFTAG_RESOLUTIONUNIT,unit);
 if(artist&&*artist)ok=ok&&TIFFSetField(f.tif,TIFFTAG_ARTIST,artist);if(copyright&&*copyright)ok=ok&&TIFFSetField(f.tif,TIFFTAG_COPYRIGHT,copyright);if(description&&*description)ok=ok&&TIFFSetField(f.tif,TIFFTAG_IMAGEDESCRIPTION,description);
 uint32_t bw=edge?edge:width,bh=edge?edge:rps;uint64_t bytes=(uint64_t)bw*bh*6;
 if(bytes>budget/6||bytes>SIZE_MAX||bytes>INT64_MAX)ok=fail(&f,"Output segment exceeds codec memory envelope");
 uint8_t *buffer=ok?malloc((size_t)bytes):NULL;if(!buffer)ok=0;
 for(uint32_t y=0;ok&&y<height;y+=bh)for(uint32_t x=0;ok&&x<width;x+=bw){
  if(!fill_raw(fd,buffer,width,height,x,y,bw,bh)){ok=fail(&f,"Raw staging read failed");break;}
  if(edge){if(TIFFWriteEncodedTile(f.tif,TIFFComputeTile(f.tif,x,y,0,0),buffer,(tmsize_t)bytes)<0)ok=0;}
  else {uint32_t rows=height-y<bh?height-y:bh;if(TIFFWriteEncodedStrip(f.tif,y/rps,buffer,(tmsize_t)((uint64_t)width*rows*6))<0)ok=0;}
 }
 free(buffer);if(ok&&!TIFFWriteDirectory(f.tif))ok=0;TIFFClose(f.tif);close(fd);if(!ok)snprintf(error,error_size,"%s",f.error[0]?f.error:"TIFF output encode failed");return ok;
}
int fs_validate_tiff_against_raw(const char *raw,const char *path,uint32_t width,uint32_t height,const void *icc,uint32_t icc_size,uint64_t budget,char *error,size_t error_size){
 FSTiff *f=fs_tiff_open(path,budget,error,error_size);if(!f)return 0;
 int fd=open(raw,O_RDONLY),ok=fd>=0&&f->info.width==width&&f->info.height==height&&f->info.bits==16&&f->info.orientation==1;
 uint32_t count=0;const void *profile=fs_tiff_icc(f,&count);if(count!=icc_size||(count&&memcmp(profile,icc,count)))ok=fail(f,"ICC mismatch after encode");
 uint32_t bw=f->info.tiled?f->info.tile_width:width,bh=f->info.tiled?f->info.tile_height:f->info.rows_per_strip;
 uint64_t bytes=(uint64_t)bw*bh*6;if(bytes>budget/6)ok=fail(f,"Validation segment exceeds envelope");
 uint8_t *expected=ok?malloc((size_t)bytes):NULL,*decoded=ok?malloc((size_t)bytes):NULL;if(!expected||!decoded)ok=0;
 for(uint32_t y=0;ok&&y<height;y+=bh)for(uint32_t x=0;ok&&x<width;x+=bw){
  if(!fill_raw(fd,expected,width,height,x,y,bw,bh)){ok=0;break;}
  tmsize_t length=(tmsize_t)(f->info.tiled?bytes:(uint64_t)width*(height-y<bh?height-y:bh)*6);
  tmsize_t got=f->info.tiled?TIFFReadEncodedTile(f->tif,TIFFComputeTile(f->tif,x,y,0,0),decoded,length):TIFFReadEncodedStrip(f->tif,y/bh,decoded,length);
  if(got!=length||memcmp(expected,decoded,(size_t)length))ok=fail(f,"TIFF validation failed: decoded pixels differ from staging");
 }
 free(expected);free(decoded);if(fd>=0)close(fd);if(!ok)snprintf(error,error_size,"%s",f->error[0]?f->error:"TIFF complete validation failed");fs_tiff_close(f);return ok;
}
