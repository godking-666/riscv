#ifndef GEOMDET_CNN_H
#define GEOMDET_CNN_H
#include "model_data.h"
/* geomdet_int8_v1: FC emits GEOMDET_SCORES outputs.
   [0 : GEOMDET_CLASSES-1] class logits, then GEOMDET_SCORES-GEOMDET_CLASSES
   signed regression values cx,cy,w,h at fraction 7
   (value/128 -> normalized [0,1], x96 -> pixels).
   类别名不在此处硬编码，须对照所用模型 model.json 的 classes 数组：
     run_smoke(旧)   -> 0=ball 1=cube 2=cylinder
     run_cifar3_big  -> 0=cup  1=bottle 2=keyboard
   若启用更多类别，需同步改 GEOMDET_CLASSES/GEOMDET_SCORES 和下方 scores[3u+i]
   的回归起始索引，并放宽 cnn_mmio.v 中 legal 的地址上限。 */
#define GEOMDET_SCORES 7u
#define GEOMDET_CLASSES 3u
#define CNN 0x10004000u
static uint32_t cnn_cycles,pp_cycles,prediction,scores[GEOMDET_SCORES];
static int32_t det_box[4]; /* cx,cy,w,h in pixels (96x96 gray domain) */
static uint32_t cur_src_crc;
static uint32_t full_source_export;
static void cnn_check_model(void){
    if(R32(CNN+8)!=8u || R32(CNN+12)!=MODEL_ID || R32(CNN+20)!=MODEL_CRC || R32(CNN+24)!=MODEL_WORDS)fail("MODEL_ID_COUNT_CRC_VALID");
}
static void cnn_load(void){
    if(R32(CNN)!=0x434e4e01u)fail("CNN_ABI_ID");
    /* 可重入补丁（v2）：
       软重启不复位外设，引擎可能残留状态。但 status.bit3 = model_valid，
       已装载过模型时 status=8 是【正常】的，不能当成脏状态去 abort
       （abort 会触发 cancel_job，导致后续任务被取消、error_code=2）。

       正确做法：
         ① 只有 busy（bit0）或 loading/load_error（bit4/5）才需要清理；
         ② 清理完（或本来就干净）就发 begin_cmd 覆盖旧模型 ——
            begin_cmd 不要求 model_valid，直接进入全新加载。 */
    uint32_t st=R32(CNN+8);
    if(st & 0x3du){                                 /* busy | error | loading | load_error */
        W32(CNN+4,2u);                              /* abort_cmd，不受 busy 限制 */
        uint64_t t0=ticks();
        while((R32(CNN+8)&0x31u) && ticks()-t0<HZ){ }   /* 等 busy/loading 落回干净 */
    }
    /* clear_cmd 专清 done/error/error_code —— 上一次崩溃留下的 error 位
       不会被 begin_cmd 清掉，必须显式清，否则 status 会多出 bit2 导致 MODEL_BEGIN 失败。 */
    W32(CNN+4,4u);
    W32(CNN+4,8u);                                  /* begin_cmd：全新加载（覆盖旧模型） */
    if(R32(CNN+8)!=16u || R32(CNN+24)!=0u || R32(CNN+12)!=0u)fail("MODEL_BEGIN");
    W32(CNN+12,MODEL_ID);
    /* Weights are stored as bytes (INT8) to keep the image under the ROM
       loader's 61440-byte cap; bias and shift words stay uint32. */
    uint64_t start=ticks();uint32_t crc=0xffffffffu;
    for(uint32_t i=0;i<MODEL_W8_COUNT;i++){
        uint32_t v=model_w8[i];W32(CNN+16,v);
        for(unsigned n=0;n<4;n++){crc=pp01_crc_step(crc,(uint8_t)v);v>>=8;}
        if((i&63u)==63u && ticks()-start>5ull*HZ)fail("MODEL_LOAD_TIMEOUT");
    }
    for(uint32_t i=0;i<MODEL_W32_COUNT;i++){
        uint32_t v=model_w32[i];W32(CNN+16,v);
        for(unsigned n=0;n<4;n++){crc=pp01_crc_step(crc,(uint8_t)v);v>>=8;}
        if(((MODEL_W8_COUNT+i)&63u)==63u && ticks()-start>5ull*HZ)fail("MODEL_LOAD_TIMEOUT");
    }
    if(pp01_crc_finish(crc)!=MODEL_CRC || R32(CNN+24)!=MODEL_WORDS || R32(CNN+20)!=MODEL_CRC)fail("MODEL_UPLOAD_CRC_COUNT");
    W32(CNN+20,MODEL_CRC);cnn_check_model();
    text("MODEL ID=");hex(MODEL_ID);text(" WORDS=");dec(MODEL_WORDS);text(" CRC=");hex(MODEL_CRC);text(" STATUS=00000008\n");
}
/* Regression score -> pixel coordinate: v/128*96 = v*3/4, clamped to [0,96]. */
static int32_t reg_to_pixel(uint32_t v){
    int32_t s=(int32_t)v;
    int32_t px=(int32_t)(((int64_t)s*96)/128);
    if(px<0)px=0;
    if(px>96)px=96;
    return px;
}
static void cnn_run(void){
    cnn_check_model();W32(CNN+28,cur_seq);W32(CNN+32,cur_buf);
    if(R32(CNN+28)!=cur_seq || R32(CNN+32)!=cur_buf)fail("CNN_EXPECTED_IDENTITY");
    W32(CNN+4,1u);uint64_t start=ticks();
    for(;;){
        uint32_t s=R32(CNN+8);
        if(s&0x34u)fail("CNN_ERROR");
        if(s&2u)break;
        if(ticks()-start>4ull*HZ)fail("CNN_SOFTWARE_TIMEOUT");
    }
    if(R32(CNN+8)!=10u || R32(CNN+36)!=cur_seq || R32(CNN+40)!=cur_buf ||
       R32(CNN+48)!=864u || R32(CNN+52)!=1024u || R32(CNN+60)!=0u)fail("CNN_RESULT_METADATA");
    if(R32(CNN+12)!=MODEL_ID || R32(CNN+20)!=MODEL_CRC || R32(CNN+24)!=MODEL_WORDS)fail("CNN_MODEL_CHANGED");
    prediction=R32(CNN+56);cnn_cycles=R32(CNN+44);
    if(prediction>=GEOMDET_CLASSES || !cnn_cycles || cnn_cycles>=3u*HZ)fail("CNN_CLASS_CYCLES");
    for(unsigned i=0;i<GEOMDET_SCORES;i++)scores[i]=R32(CNN+64+4*i);
    /* Argmax over class logits only; regression outputs never compete. */
    uint32_t best=0;for(uint32_t i=1;i<GEOMDET_CLASSES;i++)if((int32_t)scores[i]>(int32_t)scores[best])best=i;
    if(best!=prediction)fail("CNN_ARGMAX");
    for(unsigned i=0;i<4;i++)det_box[i]=reg_to_pixel(scores[3u+i]);
}
static void identity_stable(void){
    cam_healthy();
    cam_write(CAM_SELECT,cur_buf);
    if(R32(CAM+CAM_FRAME_SEQ)!=cur_seq || R32(CAM+CAM_CRC)!=cur_src_crc)fail("SOURCE_IDENTITY_CHANGED");
    if(cam_state(cur_buf)!=3u || R32(PP+8)!=2u || R32(PP+20)!=cur_seq || R32(PP+60)!=cur_buf ||
       R32(PP+28)!=OUT_BYTES || R32(PP+32)!=cur_pp_crc || R32(CNN+8)!=10u ||
       R32(CNN+36)!=cur_seq || R32(CNN+40)!=cur_buf || R32(CNN+12)!=MODEL_ID || R32(CNN+20)!=MODEL_CRC)fail("JOB_IDENTITY_CHANGED");
    for(unsigned i=0;i<GEOMDET_SCORES;i++)if(R32(CNN+64+4*i)!=scores[i])fail("SCORE_CHANGED");
}
static void capture_group(uint32_t target){
    cam_healthy();cam_idle_state();cam_write(CAM_CTRL,CAM_CMD_STREAM_START);
    if((R32(CAM+CAM_STATUS)&0x60u)!=0x60u)fail("STREAM_START");
    cur_seq=wait_target(target);cur_buf=target;stop_and_drain();
    cam_write(CAM_SELECT,cur_buf);cur_src_crc=R32(CAM+CAM_CRC);
    pp_start(target,cur_seq);pp_wait_done();pp_check(target,cur_seq,&cur_pp_crc);pp_cycles=R32(PP+PP_CYCLES);
    cnn_run();identity_stable();
    if(output_reread()!=cur_pp_crc)fail("RGB_CPU_CRC");
    text("CNN_JOB BUF=");dec(cur_buf);text(" SEQ=");dec(cur_seq);
    hfield(" MODEL=",MODEL_ID);hfield(" MODEL_CRC=",MODEL_CRC);hfield(" PP_CRC=",cur_pp_crc);
    text(" BYTES=27648 READS=864 GRAY=1024 STATUS=0000000a ERROR=00000000 CLASS=");dec(prediction);
    text(" CYCLES=");dec(cnn_cycles);text(" PP_CYCLES=");dec(pp_cycles);text("\nSCORES");
    for(unsigned i=0;i<GEOMDET_SCORES;i++){text(" ");if(scores[i]&0x80000000u){text("-");dec(0u-scores[i]);}else dec(scores[i]);}
    /* Detection result: class + center/size box in the 96x96 gray domain. */
    text("\nDET CLASS=");dec(prediction);
    text(" CX=");dec((uint32_t)det_box[0]);text(" CY=");dec((uint32_t)det_box[1]);
    text(" W=");dec((uint32_t)det_box[2]);text(" H=");dec((uint32_t)det_box[3]);
    text("\n");
    text("SOURCE BUF=");dec(cur_buf);text(" SEQ=");dec(cur_seq);
    text(" WIDTH=1280 HEIGHT=720 BYTES=1843200 CRC=");hex(cur_src_crc);text("\n");
}
static void export_group(void){
    identity_stable();text("CNN_EXPORT_BEGIN\n");uint32_t crc=0xffffffffu;
    for(uint32_t off=0;off<OUT_BYTES;off+=CHUNK){
        load_words(OUT_BASE,off,CHUNK/4);
        for(uint32_t i=0;i<CHUNK;i++)crc=pp01_crc_step(crc,payload[i]);
        send_packet(1u,cur_seq,off,CHUNK,OUT_BYTES,pp01_crc_bytes(payload,CHUNK));
    }
    if(pp01_crc_finish(crc)!=cur_pp_crc)fail("EXPORTED_RGB_CRC");
    identity_stable();send_packet(2u,cur_seq,OUT_BYTES,0u,OUT_BYTES,cur_pp_crc);
    if(full_source_export){

    identity_stable();crc=0xffffffffu;
    for(uint32_t off=0;off<SRC_BYTES;off+=CHUNK){
        load_words(cur_buf?SRC_B:SRC_A,off,CHUNK/4);
        for(uint32_t i=0;i<CHUNK;i++)crc=pp01_crc_step(crc,payload[i]);
        send_packet(3u,cur_seq,off,CHUNK,SRC_BYTES,pp01_crc_bytes(payload,CHUNK));
    }
    if(pp01_crc_finish(crc)!=cur_src_crc)fail("EXPORTED_SOURCE_CRC");
    identity_stable();send_packet(4u,cur_seq,SRC_BYTES,0u,SRC_BYTES,cur_src_crc);
    }
    text("CNN_EXPORT_DONE\n");cam_release(cur_buf,cur_seq);drain_unselected(cur_buf);cam_idle_state();
    if(ledger_n!=R32(CAM+CAM_GLOBAL_SEQ) || target_claims!=1u || target_claims+discard_claims!=ledger_n)fail("FINAL_OWNERSHIP_LEDGER");
    text("CNN_RELEASED CLAIMS=");dec(ledger_n);text(" DISCARDS=");dec(discard_claims);
    text(" GLOBAL_SEQ=");dec(R32(CAM+CAM_GLOBAL_SEQ));hfield(" CAM_STATE=",R32(CAM+CAM_BUFSTATE));
    hfield(" PP_STATUS=",R32(PP+8));hfield(" CNN_STATUS=",R32(CNN+8));text("\n");
}
#endif
