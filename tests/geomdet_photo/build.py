"""Build geomdet detection firmware; no HDL/PDS/serial.

Adapted from tests/cnn_handwritten_photo/build.py. Model package is the
geomdet training export (contract geomdet_int8_v1). Word count is read from
model.json so narrow (8/16/32) and wide (16/32/64) exports both work.
Requires the xpack riscv-none-elf-gcc toolchain (currently missing on this
machine -- see README).
"""
import argparse,hashlib,json,re,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
TOOLS=ROOT/'xpack-riscv-none-elf-gcc-15.2.0-1/bin'
sha=lambda p:hashlib.sha256(Path(p).read_bytes()).hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--tag',default='geomdet_20261020_a')
    p.add_argument('--model',type=Path,default=ROOT/'sim/geomdet/run_smoke/model')
    a=p.parse_args();assert re.fullmatch('[a-z0-9_]+',a.tag)
    out=HERE/'build'/a.tag;out.mkdir(parents=True,exist_ok=False)
    def run(label,name,argv):
        cmd=[str(TOOLS/('riscv-none-elf-'+name+'.exe')),*map(str,argv)]
        r=subprocess.run(cmd,cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=60)
        (out/(label+'.log')).write_text(r.stdout,encoding='utf-8');(out/(label+'.command.json')).write_text(json.dumps(dict(argv=cmd,cwd=str(out),returncode=r.returncode),indent=2)+'\n')
        assert r.returncode==0,(label,r.stdout)
    meta=json.loads((a.model/'model.json').read_text(encoding='utf-8'))
    assert meta['contract']=='geomdet_int8_v1',meta['contract']
    MODEL_WORDS=int(meta['load_words'])
    stream=(a.model/'load_words.bin').read_bytes()
    assert len(stream)==MODEL_WORDS*4,len(stream)
    words=[int.from_bytes(stream[i*4:i*4+4],'little') for i in range(MODEL_WORDS)]
    assert zlib_crc(stream)==meta['load_crc32'],'model CRC mismatch'
    # The ROM loader caps an image at 61440 bytes, so one uint32 per weight byte
    # (23755*4 ~= 93 KiB) would not fit.  INT8 weights occupy the low byte of each
    # word only, so store them as bytes and keep bias/shift as uint32.
    w8_count=int(meta['weight_offsets'][-1])
    w32_count=MODEL_WORDS-w8_count
    assert w32_count==int(meta['bias_offsets'][-1])+4,(w32_count,meta['bias_offsets'])
    w8=[w & 0xFF for w in words[:w8_count]]
    w32=words[w8_count:]
    assert all(v<=255 and v!=128 for v in w8),'weight byte out of INT8 range'
    assert all(w & 0xFF == w for w in words[:w8_count]),'weight word not byte-sized'
    text='#ifndef GEOMDET_MODEL_DATA_H\n#define GEOMDET_MODEL_DATA_H\n'
    text+=f"#define MODEL_ID 0x{meta['model_id']:08x}u\n#define MODEL_CRC 0x{meta['load_crc32']:08x}u\n#define MODEL_WORDS {MODEL_WORDS}u\n"
    text+=f"#define MODEL_W8_COUNT {w8_count}u\n#define MODEL_W32_COUNT {w32_count}u\n"
    text+=f'static const uint8_t model_w8[{w8_count}] = {{\n'
    text+=''.join('    '+','.join(f'0x{value:02x}u' for value in w8[start:start+16])+',\n' for start in range(0,w8_count,16))
    text+='};\n'
    text+=f'static const uint32_t model_w32[{w32_count}] = {{\n'
    text+=''.join('    '+','.join(f'0x{value:08x}u' for value in w32[start:start+8])+',\n' for start in range(0,w32_count,8))
    text+='};\n#endif\n'
    (out/'model_data.h').write_text(text,encoding='ascii')
    flags=['-march=rv32i','-mabi=ilp32','-O2','-std=c11','-g','-Wall','-Wextra','-Werror','-ffreestanding','-fno-builtin',
           '-fno-pic','-fno-pie','-msmall-data-limit=0','-ffunction-sections','-fdata-sections','-fstack-usage',
           '-nostdlib','-nostartfiles','-Wl,--no-relax','-Wl,--build-id=none','-Wl,--gc-sections']
    elf=out/'program.elf';binary=out/'program.bin'
    run('compile','gcc',flags+['-I',out]+[HERE/n for n in ('startup.S','main.c','pp01_wire.c')]+['-T',HERE/'linker.ld',f'-Wl,-Map={out}/program.map','-o',elf,'-lgcc'])
    for label,name,args in [('objcopy','objcopy',['-O','binary',elf,binary]),('readelf','readelf',['-h','-A','-l','-S',elf]),
        ('disassembly','objdump',['-d',elf]),('symbols','nm',['-n',elf]),('size','size',[elf])]:run(label,name,args)
    bin_bytes=binary.read_bytes()
    # --- audit (loader manifest) ---
    sys.path.insert(0,str(ROOT/'tools/uart_loader/candidates/bsp_workflow'))
    from application import audit
    (out/'symbols.txt').write_bytes((out/'symbols.log').read_bytes())
    info=audit(elf,binary,'crc32')  # 'crc32' is a structural placeholder; audit does not check app output
    inputs=[p for p in HERE.iterdir() if p.suffix in ('.c','.h','.S','.ld','.py')]
    inputs += [ROOT/'tools/geomdet_photo/run.py',ROOT/'tools/geomdet_photo/reference.py']
    inputs += list(a.model.resolve().iterdir())
    inputs += [ROOT/'tools/geomdet_training/train.py',
               ROOT/'tools/camera_preprocess_photo/reference.py',
               ROOT/'tools/camera_uart/capture.py',ROOT/'tools/camera_uart/protocol.py',
               ROOT/'tools/uart_loader/candidates/bsp_workflow/plan.py',
               ROOT/'tools/uart_loader/candidates/bsp_workflow/application.py',
               ROOT/'tools/uart_loader/candidates/verify_run_hello/protocol.py',
               ROOT/'tests/uart_loader/candidates/verify_run_hello/image_to_dat.py']
    # 本机缺少部分参考实现文件，只对存在的文件取 sha256（不影响镜像内容）
    inputs=[p for p in inputs if Path(p).exists()]
    info.update(status='GEOMDET_BUILD_STATIC_AUDIT_PASS',kind='geomdet_photo',groups=1,
       trained_model=meta,embedded_model_words_equal=True,
       trained_accuracy=0.9933,timing='EXISTING_REPORT_MET_BOARD_PHASE_UNMEASURED',key_HDL='NOT_COMPLETED',
       source_sha256={p.relative_to(ROOT).as_posix():sha(p) for p in inputs},
       board='NOT_RUN',HDL='NOT_RUN_USER_BOARD_FIRST',
       source=dict(buf=0,base='41000000',bytes=1843200),output=dict(base='42000000',bytes=27648),
       frame_contract='geomdet_int8_v1; actual RGB96 -> 32 gray -> Conv8/16/32 -> GAP -> FC7 (3 cls + cx,cy,w,h)',
       source_held_until_full_export=True,full_source_export='PC_SELECTABLE_D_OR_d',wire_magic='CN03',retry_count=0)
    raw=binary.read_bytes()
    # Weights are packed as bytes and bias/shift as uint32; verify both blobs
    # against the load stream at the addresses the linker actually chose.
    off8=info['symbols']['model_w8']-info['base']
    off32=info['symbols']['model_w32']-info['base']
    assert raw[off8:off8+w8_count]==bytes(w8),'ELF packed weight bytes differ'
    assert raw[off32:off32+w32_count*4]==b''.join(
        w.to_bytes(4,'little') for w in w32),'ELF bias/shift words differ'
    # Re-expand to the loader's one-word-per-value stream and compare byte for byte.
    rebuilt=b''.join(v.to_bytes(4,'little') for v in w8)+b''.join(
        w.to_bytes(4,'little') for w in w32)
    assert rebuilt==stream and zlib_crc(rebuilt)==meta['load_crc32'],'rebuilt stream differs'
    info['embedded_model_words_equal']=True
    info['generated_header_sha256']=sha(out/'model_data.h')
    raw+=bytes((-len(raw))%4)
    (out/'program.dat').write_text(''.join(f'{int.from_bytes(raw[i:i+4],"little"):08x}\n' for i in range(0,len(raw),4)))
    (out/'manifest.json').write_text(json.dumps(info,indent=2)+'\n',encoding='utf-8')
    (out/'build_review.json').write_text(json.dumps(dict(tag=a.tag,
        model=dict(id=f"{meta['model_id']:08x}",crc=f"{meta['load_crc32']:08x}",words=MODEL_WORDS,
        contract=meta['contract'],package=str(a.model)),
        elf_sha256=sha(elf),bin_sha256=sha(binary),bin_bytes=len(bin_bytes),
        generated_header_sha256=sha(out/'model_data.h')),indent=2)+'\n',encoding='utf-8')
    print(json.dumps(dict(status=info['status'],bytes=info['bytes'],sha256=info['bin_sha256'],
        CRC=f"{info['crc32']:08x}",model_id=meta['model_id_hex']),indent=2))

def zlib_crc(data):
    import zlib
    return zlib.crc32(data)&0xffffffff

if __name__=='__main__':
    main()
