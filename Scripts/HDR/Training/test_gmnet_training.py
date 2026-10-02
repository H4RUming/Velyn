"""Synthetic checks for the GMNet fine-tuning forward; no camera data."""
from pathlib import Path
import sys
import unittest
import torch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Models/gmnet'))
from GMNet import GMNet
from train_gmnet_camera import training_gain,MAX_EV


class GMNetTrainingContracts(unittest.TestCase):
    def test_full_precision_forward_matches_original_for_each_batch_item(self):
        torch.manual_seed(23);net=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).eval()
        # Ensure a nonzero result even without downloading weights.
        with torch.no_grad():net.sq_qmax.conv[-1].bias.fill_(.8);net.conv_last.bias.fill_(.3)
        image=torch.rand(2,3,64,64);thumb=torch.rand(2,3,256,256)
        with torch.no_grad():
            _,original=net((image,thumb));actual=training_gain(net,image,thumb,mixed=False)
        self.assertLess(float((actual-original.clamp(0,1)*MAX_EV).abs().max()),1e-6)
        self.assertGreater(float(actual.mean()),.1)
        self.assertGreaterEqual(float(actual.min()),0);self.assertLessEqual(float(actual.max()),MAX_EV)

    def test_gradients_reach_local_and_global_branches(self):
        torch.manual_seed(23);net=GMNet(in_nc=3,out_nc=1,nf=64,nb=16)
        with torch.no_grad():net.sq_qmax.conv[-1].bias.fill_(.8);net.conv_last.bias.fill_(.3)
        output=training_gain(net,torch.rand(1,3,64,64),torch.rand(1,3,256,256),mixed=False)
        (output-.2).square().mean().backward()
        for layer in [net.conv_last,net.down_x.conv[0],net.sq_qmax.conv[-1],net.down1.conv[0]]:
            self.assertIsNotNone(layer.weight.grad)
            self.assertTrue(bool(torch.isfinite(layer.weight.grad).all()))
            self.assertGreater(float(layer.weight.grad.abs().sum()),0)


if __name__=='__main__':
    torch.set_num_threads(2);unittest.main()
