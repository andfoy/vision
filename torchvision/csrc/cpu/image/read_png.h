#pragma once

#include <torch/torch.h>

torch::Tensor decodePNG(const torch::Tensor& data);
