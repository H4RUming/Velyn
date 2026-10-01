"""Local HDR metrics. PU21 port: gfxdisp/pu21, BSD-3-Clause, see PU21-LICENSE.txt.

Reference white is an explicit viewing assumption, never measured device nits.
Do not rescale candidate and reference independently to improve their scores.
"""
import numpy as np
from scipy.ndimage import sobel
from skimage.metrics import structural_similarity

LUMA = np.array([0.2126, 0.7152, 0.0722])


def pu21(luminance):
    p = [0.353487901, 0.3734658629, 8.277049286e-5, 0.9062562627,
         0.09150303166, 0.9099517204, 596.3148142]
    y = np.clip(luminance, 0.005, 10000)
    return np.maximum(p[6] * (((p[0] + p[1] * y**p[3]) /
                               (1 + p[2] * y**p[3]))**p[4] - p[5]), 0)


def chromaticity(rgb):
    xyz = rgb @ np.array([[.4124564,.3575761,.1804375],
                          [.2126729,.7151522,.0721750],
                          [.0193339,.1191920,.9503041]]).T
    x, y, z = np.moveaxis(xyz, -1, 0)
    denominator = np.maximum(x + 15*y + 3*z, 1e-8)
    return np.stack([4*x/denominator, 9*y/denominator], -1)


def measure(candidate, reference, base, white=203):
    if not np.isfinite(candidate).all():
        raise ValueError("Non-finite candidate")
    y = np.maximum(candidate @ LUMA, 1e-8)
    r = np.maximum(reference @ LUMA, 1e-8)
    s = np.maximum(base @ LUMA, 1e-8)
    valid = (s > .01) & (r > .01)
    error = np.abs(np.log2(y/r))
    g, target = np.log2(y/s)[valid], np.log2(r/s)[valid]
    corr = None if min(np.std(g), np.std(target)) < 1e-8 else float(np.corrcoef(g,target)[0,1])
    p, q = pu21(y*white), pu21(r*white)
    data_range = float(pu21(10000)-pu21(.005))
    mse = np.mean((p-q)**2)
    grad = np.hypot(sobel(np.log2(s),axis=0),sobel(np.log2(s),axis=1))
    regions = {"dark":valid & (s < .05), "mid":valid & (s >= .05) & (s < .5),
               "bright":valid & (s >= .5), "hdr":valid & (r > 1),
               "edges":valid & (grad > np.percentile(grad,90))}
    result = {"maeEV":float(np.mean(error[valid])),"p95EV":float(np.percentile(error[valid],95)),
              "meanRatio":float(y.sum()/r.sum()),"gainCorrelation":corr,
              "puPSNR":float(10*np.log10(data_range**2/max(mse,1e-20))),
              "puSSIM":float(structural_similarity(q,p,data_range=data_range,gaussian_weights=True,sigma=1.5,use_sample_covariance=False)),
              "uvError":float(np.linalg.norm(chromaticity(candidate)-chromaticity(reference),axis=-1)[valid].mean()),
              "baseColorShift":float(np.linalg.norm(chromaticity(candidate)-chromaticity(base),axis=-1)[valid].mean()),
              "aboveSDR":float(np.mean(y > 1))}
    result["regions"] = {name:{"pixels":int(mask.sum()),"maeEV":float(error[mask].mean()) if mask.any() else None}
                         for name,mask in regions.items()}
    return result


def self_test():
    values = pu21(np.geomspace(.005,10000,100))
    assert np.isfinite(values).all() and np.all(np.diff(values)>0)
    assert 200 < pu21(100) < 300
    x = np.linspace(.02,2,4096).reshape(64,64)
    rgb = np.repeat(x[...,None],3,-1)
    exact = measure(rgb,rgb,rgb)
    changed = measure(rgb*1.25,rgb,rgb)
    assert exact['maeEV']==0 and abs(exact['puSSIM']-1)<1e-12
    assert changed['maeEV']>.3 and changed['puPSNR']<exact['puPSNR']
    assert changed['baseColorShift']<1e-12
    red = measure(rgb*np.array([1.3,1,1]),rgb,rgb)
    assert red['uvError']>.01 and red['baseColorShift']>.01


if __name__ == '__main__':
    self_test()
    print('HDR metric invariants passed')
