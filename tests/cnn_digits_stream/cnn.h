#ifndef DIGITS_HANDWRITTEN_H
#define DIGITS_HANDWRITTEN_H
#include "model_data.h"
#define CNN 0x10004000u
static uint32_t cnn_cycles,pp_cycles,prediction,scores[10];
static uint32_t cur_src_crc;
static uint32_t full_source_export;
static void cnn_check_model(void){
    // ★ 流式循环修正：第 1 帧跑完后 status 会带 done 位（8|2 = 0x0A），
    //   原来要求 `==8` 会让第 2 帧起必然失败（MODEL_ID_COUNT_CRC_VALID）。
    //   这里只要求 bit3「模型已装载」置位，ID/CRC/WORDS 仍逐项核对。
    if((R32(CNN+8)&8u)==0u || R32(CNN+12)!=MODEL_ID || R32(CNN+20)!=MODEL_CRC || R32(CNN+24)!=MODEL_WORDS)fail("MODEL_ID_COUNT_CRC_VALID");
}
static void cnn_load(void){
    if(R32(CNN)!=0x434e4e01u)fail("CNN_ABI_ID");
    // ★ 软重启（reboot_to_loader 跳 0x0）**不会复位 CNN 外设**：模型常常还装着，
    //   状态停在 0x0A（已装载|已完成），于是原 `if(status!=0) fail(CNN_NOT_FRESH)` 会挡住。
    //   若能确认模型身份一致，就发 clear_cmd(向 CNN+4 写 4) 清掉 done/error 后**直接复用**，
    //   省掉 6222 词上传（约 2 秒）。
    if((R32(CNN+8)&8u)!=0u && R32(CNN+12)==MODEL_ID &&
       R32(CNN+20)==MODEL_CRC && R32(CNN+24)==MODEL_WORDS){
        W32(CNN+4,4u);                 // clear_cmd：清 done/error，保留 model_valid
        cnn_check_model();
        text("MODEL ID=");hex(MODEL_ID);text(" WORDS=6222 CRC=");hex(MODEL_CRC);text(" STATUS=00000008 REUSED\n");
        return;
    }
    if(R32(CNN+8)!=0u)fail("CNN_NOT_FRESH");
    W32(CNN+4,8u);
    if(R32(CNN+8)!=16u || R32(CNN+24)!=0u || R32(CNN+12)!=0u)fail("MODEL_BEGIN");
    W32(CNN+12,MODEL_ID);
    uint64_t start=ticks();uint32_t crc=0xffffffffu;
    for(uint32_t i=0;i<MODEL_WORDS;i++){
        uint32_t v=model_words[i];W32(CNN+16,v);
        for(unsigned n=0;n<4;n++){crc=pp01_crc_step(crc,(uint8_t)v);v>>=8;}
        if((i&63u)==63u && ticks()-start>5ull*HZ)fail("MODEL_LOAD_TIMEOUT");
    }
    if(pp01_crc_finish(crc)!=MODEL_CRC || R32(CNN+24)!=MODEL_WORDS || R32(CNN+20)!=MODEL_CRC)fail("MODEL_UPLOAD_CRC_COUNT");
    W32(CNN+20,MODEL_CRC);cnn_check_model();
    text("MODEL ID=");hex(MODEL_ID);text(" WORDS=6222 CRC=");hex(MODEL_CRC);text(" STATUS=00000008\n");
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
    if(prediction>=10u || !cnn_cycles || cnn_cycles>=3u*HZ)fail("CNN_CLASS_CYCLES");
    for(unsigned i=0;i<10;i++)scores[i]=R32(CNN+64+4*i);
    uint32_t best=0;for(unsigned i=1;i<10;i++)if((int32_t)scores[i]>(int32_t)scores[best])best=i;
    if(best!=prediction)fail("CNN_ARGMAX");
}
static void identity_stable(void){
    cam_healthy();
    cam_write(CAM_SELECT,cur_buf);
    if(R32(CAM+CAM_FRAME_SEQ)!=cur_seq || R32(CAM+CAM_CRC)!=cur_src_crc)fail("SOURCE_IDENTITY_CHANGED");
    if(cam_state(cur_buf)!=3u || R32(PP+8)!=2u || R32(PP+20)!=cur_seq || R32(PP+60)!=cur_buf ||
       R32(PP+28)!=OUT_BYTES || R32(PP+32)!=cur_pp_crc || R32(CNN+8)!=10u ||
       R32(CNN+36)!=cur_seq || R32(CNN+40)!=cur_buf || R32(CNN+12)!=MODEL_ID || R32(CNN+20)!=MODEL_CRC)fail("JOB_IDENTITY_CHANGED");
    for(unsigned i=0;i<10;i++)if(R32(CNN+64+4*i)!=scores[i])fail("SCORE_CHANGED");
}
// 旧的"单帧启停流"路径：流式固件不再调用它，但保留作取证/对照用途。
static void __attribute__((unused)) capture_group(uint32_t target){
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
    for(unsigned i=0;i<10;i++){text(" ");if(scores[i]&0x80000000u){text("-");dec(0u-scores[i]);}else dec(scores[i]);}
    text("\n");
    text("SOURCE BUF=");dec(cur_buf);text(" SEQ=");dec(cur_seq);
    text(" WIDTH=1280 HEIGHT=720 BYTES=1843200 CRC=");hex(cur_src_crc);text("\n");
}
// ==================== 连续流式取帧（不启停相机）====================
// 原 capture_group() 每帧 STREAM_START → 等帧 → STREAM_STOP → 排空，
// 相机被反复启停：停机期间缓冲不更新，屏上就是"定格 0.8 秒再跳一帧"，
// 识别也卡在约 1.2 fps。
// 这里改成：开一次流，之后每帧只做「等就绪缓冲 → 预处理 → CNN → 释放」，
// 让相机连续自由运行（显示端因此流畅），识别率也随之上来。
//
// 注意几处**故意不做**的事：
//   * 不调 cam_idle_state() —— 流开着时它会 fail（STATUS&0x40）
//   * 不调 stop_and_drain()  —— 会把流停掉
//   * 不调 drain_unselected() —— 另一个缓冲正被相机写，去 claim 会打扰流水线
//   * 不调 output_reread()   —— 每帧用 CPU 重读 27KB 只为取证，流式下是纯浪费
static void stream_open(void){
    cam_healthy();cam_idle_state();
    cam_write(CAM_CTRL,CAM_CMD_STREAM_START);
    uint64_t start=ticks();
    for(;;){
        cam_healthy();
        if((R32(CAM+CAM_STATUS)&0x60u)==0x60u)break;   // 两路缓冲都就绪
        if(ticks()-start>=READY_LIMIT)fail("STREAM_START_TIMEOUT");
    }
}
static void stream_close(void){
    cam_write(CAM_CTRL,CAM_CMD_STREAM_STOP);
    uint64_t start=ticks();
    for(;;){
        if(!(R32(CAM+CAM_BUFSTATE)&0x40u) && !(R32(CAM+CAM_STATUS)&2u))break;
        if(ticks()-start>=READY_LIMIT)break;           // 收尾失败也不阻塞退出
    }
}
static void capture_group_stream(uint32_t target){
    cam_healthy();
    cur_seq=wait_target(target);cur_buf=target;        // wait_target 内已 cam_claim + ledger_add
    cam_write(CAM_SELECT,cur_buf);cur_src_crc=R32(CAM+CAM_CRC);
    pp_start(target,cur_seq);pp_wait_done();pp_check(target,cur_seq,&cur_pp_crc);pp_cycles=R32(PP+PP_CYCLES);
    cnn_run();identity_stable();
    cam_release(cur_buf,cur_seq);                      // ★ 先释放，让相机尽早拿到空闲缓冲
    text("CNN_JOB BUF=");dec(cur_buf);text(" SEQ=");dec(cur_seq);
    hfield(" MODEL=",MODEL_ID);hfield(" MODEL_CRC=",MODEL_CRC);hfield(" PP_CRC=",cur_pp_crc);
    text(" BYTES=27648 READS=864 GRAY=1024 STATUS=0000000a ERROR=00000000 CLASS=");dec(prediction);
    text(" CYCLES=");dec(cnn_cycles);text(" PP_CYCLES=");dec(pp_cycles);text("\nSCORES");
    for(unsigned i=0;i<10;i++){text(" ");if(scores[i]&0x80000000u){text("-");dec(0u-scores[i]);}else dec(scores[i]);}
    text("\n");
    text("SOURCE BUF=");dec(cur_buf);text(" SEQ=");dec(cur_seq);
    text(" WIDTH=1280 HEIGHT=720 BYTES=1843200 CRC=");hex(cur_src_crc);text("\n");
}
// 旧的"导出整帧+源图"路径：流式固件改用 export_dump()，这里保留作单帧拍照版取证用途。
static void __attribute__((unused)) export_group(void){    identity_stable();text("CNN_EXPORT_BEGIN\n");uint32_t crc=0xffffffffu;
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
// ★ 流式模式下 d/D 取图：export_group() 入口的 identity_stable() 要求
//   cam_state(cur_buf)==3（CPU 持有），而流式循环返回前已经 cam_release()，
//   所以流式下调用 export_group() 必然 fail("SOURCE_IDENTITY_CHANGED")。
//   这里改为只读 PP 的输出区（OUT_BASE，在 DDR 里，不随 release 失效），
//   完全不碰相机缓冲 → 不需要持有权，只核对 CPU 侧本帧的 CRC。
//   说明：'D' 的整幅源图导出同样需要持有缓冲，流式下不可用，本函数对
//   D/d 都给 96x96 RGB；整幅导出请用单帧拍照版固件。
static void export_dump(void){
    cam_healthy();
    text("CNN_EXPORT_BEGIN\n");uint32_t crc=0xffffffffu;
    for(uint32_t off=0;off<OUT_BYTES;off+=CHUNK){
        load_words(OUT_BASE,off,CHUNK/4);
        for(uint32_t i=0;i<CHUNK;i++)crc=pp01_crc_step(crc,payload[i]);
        send_packet(1u,cur_seq,off,CHUNK,OUT_BYTES,pp01_crc_bytes(payload,CHUNK));
    }
    crc=pp01_crc_finish(crc);
    if(crc!=cur_pp_crc)fail("DUMPED_RGB_CRC");   // DDR 被改过 / 本帧记录不符
    send_packet(2u,cur_seq,OUT_BYTES,0u,OUT_BYTES,crc);
    text("CNN_EXPORT_DONE\n");
}
#endif

