"""Materialize frozen candidates for codec tests and private visual inspection."""
from pathlib import Path
import argparse,json
import numpy as np
import torch
from PIL import Image,ImageDraw
from experiment import load,input_outputs,variants,learned_outputs,ResidualGain


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('fixtures',type=Path);p.add_argument('results',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    lock=json.loads((a.results/'frozen.json').read_text());names=['production/v11']+lock['shortlist'][:1]+['learned/residual-cnn']
    cnn=ResidualGain().eval();cnn.load_state_dict(torch.load(a.results/'residual.pt',map_location='cpu',weights_only=True));torch.set_num_threads(4)
    a.output.mkdir(parents=True,exist_ok=True)
    for metadata in sorted(a.fixtures.glob('*/prepared.json')):
        s=load(metadata.parent)
        # Only validation images use the all-development CNN. Development CNN
        # scores remain leave-one-out; don't export an in-sample learned example.
        selected=names if s['meta']['group']=='validation' else names[:-1]
        outputs=variants(s);outputs.update(input_outputs(s,dict(np.load(s['root']/'input-variants.npz'))))
        if s['meta']['group']=='validation':outputs.update(learned_outputs(s,np.array(lock['calibration']),cnn))
        shape=s['y'].shape
        for name in selected:
            folder=a.output/(s['meta']['id']+'--'+name.replace('/','_'));folder.mkdir(parents=True,exist_ok=True)
            for key,rgb in [('base',s['base']),('candidate',outputs[name])]:
                rgba=np.concatenate([rgb,np.ones((*shape,1))],-1).astype(np.float32);rgba.tofile(folder/(key+'.f32'))
            (folder/'dimensions.json').write_text(json.dumps({'width':shape[1],'height':shape[0]}))
        panels=[('Native HDR',s['reference']),('v1.1',outputs['production/v11'])]
        if lock['shortlist']:panels.append(('1024 candidate',outputs[lock['shortlist'][0]]))
        if s['meta']['group']=='validation':panels.append(('Small CNN',outputs['learned/residual-cnn']))
        # One common -2 EV scale, then sRGB encoding. SDR diagnostic only.
        cells=[]
        for title,rgb in panels:
            rgb=np.clip(rgb/4,0,1);rgb=np.where(rgb<=.0031308,12.92*rgb,1.055*rgb**(1/2.4)-.055)
            im=Image.fromarray(np.rint(rgb*255).astype(np.uint8)).resize((shape[1],shape[0]))
            cell=Image.new('RGB',(shape[1],shape[0]+32),'#181818');cell.paste(im,(0,32));ImageDraw.Draw(cell).text((10,10),title,fill='white');cells.append(cell)
        sheet=Image.new('RGB',(shape[1]*len(cells),shape[0]+32))
        for index,cell in enumerate(cells):sheet.paste(cell,(shape[1]*index,0))
        sheet.save(a.output/(s['meta']['id']+'-comparison.jpg'),quality=95)
    print('Private candidates and shared-scale comparisons written')


if __name__=='__main__':main()
