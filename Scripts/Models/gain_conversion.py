"""Equivalent GMNet operators for accelerator conversion; no weight changes."""
import torch
import torch.nn.functional as F
from gmnet.GMNet import GMNet


class StaticKernelGMNet(GMNet):
    def forward(self, inputs):
        y = self.res_y(self.down2(self.down1(inputs[1])))
        kernel, cse, qmax = self.sq_ker(y), self.sq_chn(y), self.sq_qmax(y)
        x = self.res1(self.down_x(inputs[0]))
        h, w = x.shape[-2:]
        padded = F.pad(x, (1, 1, 1, 1))
        # Cross-correlation, exactly matching conv2d(..., groups=channels).
        # Static slices avoid a convolution whose weights depend on the image.
        mask = sum(padded[:, :, row:row+h, col:col+w] * kernel[:, :, row:row+1, col:col+1]
                   for row in range(3) for col in range(3))
        x = self.res2(x * self.mask_est(mask)) * self.att_est(cse)
        x = self.res3(x)
        out = self.conv_last(self.act(self.HRconv(self.act(self.upsampler(self.upconv(x))))))
        return out, qmax * out
