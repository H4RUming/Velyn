import unittest
import numpy as np
import torch
from model import SignedGainNet,MIN_EV,MAX_EV
from pairs import make_pairs,linearize,encode
from prepare_data import groups,project


class TrainingContracts(unittest.TestCase):
    def test_transfer_roundtrip_including_HDR(self):
        x=torch.linspace(0,5,1000)
        self.assertLess(float((linearize(encode(x))-x).abs().max()),3e-6)

    def test_deterministic_pairs_have_both_signs_and_no_nonfinite_black(self):
        hdr=torch.logspace(-3,1,256)[None,None,None,:].expand(32,3,256,256).clone()
        a=make_pairs(hdr,42); b=make_pairs(hdr,42)
        for x,y in zip(a,b): self.assertTrue(torch.equal(x,y))
        _,_,target,valid,_=a
        self.assertTrue(bool(((target<-.05)&valid).any()))
        self.assertTrue(bool(((target>.05)&valid).any()))
        self.assertTrue(bool(torch.isfinite(target).all()))
        black=make_pairs(torch.zeros(4,3,32,32),8)
        self.assertTrue(bool(torch.isfinite(black[2]).all()))
        self.assertFalse(bool(black[3].any()))

    def test_identity_initialization_and_signed_output(self):
        model=SignedGainNet().eval(); rgb=torch.rand(1,3,64,96); thumb=torch.rand(1,3,128,128)
        with torch.no_grad():
            self.assertEqual(float(model(rgb,thumb).abs().max()),0)
            model.head.bias.fill_(-2)
            value=model(rgb,thumb)
            self.assertEqual(tuple(value.shape),(1,1,64,96))
            self.assertLess(float(value.max()),-.5)
            model.head.bias.fill_(4)
            value=model(rgb,thumb)
            self.assertGreater(float(value.min()),1)
            self.assertLessEqual(float(value.max()),MAX_EV+1e-6)
            self.assertGreaterEqual(float(value.min()),MIN_EV)

    def test_location_and_capture_family_stay_together(self):
        catalog={'courtyard_dawn':{'coords':[10,20]},'courtyard_night':{'coords':[40,50]},
                 'doorway':{'coords':[10.001,20.001]},'unrelated':{'coords':[-40,50]}}
        result=list(groups(catalog).values())
        self.assertIn(['courtyard_dawn','courtyard_night','doorway'],result)
        self.assertIn(['unrelated'],result)

    def test_perspective_projection_is_finite_at_wrap(self):
        source=np.ones((64,128,3),np.float32)*np.array([.2,.4,2],np.float32)
        for yaw in [0,179,180,359]:
            out=project(source,yaw,15,size=32)
            self.assertEqual(out.shape,(32,32,3))
            self.assertTrue(np.isfinite(out).all())
            self.assertLess(float(np.abs(out-source[0,0]).max()),1e-6)


if __name__=='__main__':
    torch.set_num_threads(2)
    unittest.main()
