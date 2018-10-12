#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>

#include <THC/THC.h>
#include <THC/THCAtomics.cuh>
#include <THC/THCDeviceUtils.cuh>

#include "cuda_helpers.h"
#include <iostream>


template <typename T>
__global__ void RoIPoolForward(const int nthreads, const T* input,
    const T spatial_scale, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const T* rois, T* output, int* argmax_data) {
  CUDA_1D_KERNEL_LOOP(index, nthreads) {
    // (n, c, ph, pw) is an element in the pooled output
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;

    const T* offset_rois = rois + n * 5;
    int roi_batch_ind = offset_rois[0];
    int roi_start_w = round(offset_rois[1] * spatial_scale);
    int roi_start_h = round(offset_rois[2] * spatial_scale);
    int roi_end_w = round(offset_rois[3] * spatial_scale);
    int roi_end_h = round(offset_rois[4] * spatial_scale);

    // Force malformed ROIs to be 1x1
    int roi_width = max(roi_end_w - roi_start_w + 1, 1);
    int roi_height = max(roi_end_h - roi_start_h + 1, 1);
    T bin_size_h = static_cast<T>(roi_height)
                       / static_cast<T>(pooled_height);
    T bin_size_w = static_cast<T>(roi_width)
                       / static_cast<T>(pooled_width);

    int hstart = static_cast<int>(floor(static_cast<T>(ph)
                                        * bin_size_h));
    int wstart = static_cast<int>(floor(static_cast<T>(pw)
                                        * bin_size_w));
    int hend = static_cast<int>(ceil(static_cast<T>(ph + 1)
                                     * bin_size_h));
    int wend = static_cast<int>(ceil(static_cast<T>(pw + 1)
                                     * bin_size_w));

    // Add roi offsets and clip to input boundaries
    hstart = min(max(hstart + roi_start_h, 0), height);
    hend = min(max(hend + roi_start_h, 0), height);
    wstart = min(max(wstart + roi_start_w, 0), width);
    wend = min(max(wend + roi_start_w, 0), width);
    bool is_empty = (hend <= hstart) || (wend <= wstart);

    // Define an empty pooling region to be zero
    T maxval = is_empty ? 0 : -FLT_MAX;
    // If nothing is pooled, argmax = -1 causes nothing to be backprop'd
    int maxidx = -1;
    const T* offset_input =
        input + (roi_batch_ind * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        int input_index = h * width + w;
        if (offset_input[input_index] > maxval) {
          maxval = offset_input[input_index];
          maxidx = input_index;
        }
      }
    }
    output[index] = maxval;
    argmax_data[index] = maxidx;
  }
}

template <typename T>
__global__ void RoIPoolBackward(const int nthreads, const T* grad_output,
    const int* argmax_data, const int num_rois, const T spatial_scale,
    const int channels, const int height, const int width,
    const int pooled_height, const int pooled_width,
    T* grad_input, const T* rois,
    const int n_stride, const int c_stride,
    const int h_stride, const int w_stride) {

    CUDA_1D_KERNEL_LOOP(index, nthreads) {
        // (n, c, ph, pw) is an element in the pooled output
        int pw = index % pooled_width;
        int ph = (index / pooled_width) % pooled_height;
        int c = (index / pooled_width / pooled_height) % channels;
        int n = index / pooled_width / pooled_height / channels;

        const T* offset_rois = rois + n * 5;
        int roi_batch_ind = offset_rois[0];
        T* grad_input_offset = grad_input + ((roi_batch_ind * channels + c) * height * width);

        int output_offset = n*n_stride + c*c_stride;
        const int* argmax_data_offset = argmax_data + n*channels*pooled_height*pooled_width;
        int argmax = argmax_data_offset[c*pooled_height*pooled_width + ph*pooled_width + pw];

        if (argmax != -1) {
            atomicAdd(grad_input_offset + argmax,
                      static_cast<T>(grad_output[output_offset + ph*h_stride + pw*w_stride]));
        }
    }
}

std::tuple<at::Tensor, at::Tensor> ROIPool_forward_cuda(const at::Tensor& input,
                                const at::Tensor& rois,
                                const float spatial_scale,
                                const int pooled_height,
                                const int pooled_width) {
  AT_ASSERTM(input.type().is_cuda(), "input must be a CUDA tensor");
  AT_ASSERTM(rois.type().is_cuda(), "rois must be a CUDA tensor");

  auto num_rois = rois.size(0);
  auto channels = input.size(1);
  auto height = input.size(2);
  auto width = input.size(3);

  at::Tensor output = at::empty({num_rois, channels, pooled_height, pooled_width}, input.options());
  at::Tensor argmax = at::zeros_like(output) //.dtype(at::dataTypeToScalarType(at::scalarTypeToDataType(at::kInt)))
  // at::Tensor argmax = input.type().toScalarType(at::kInt).tensor({num_rois, channels, pooled_height, pooled_width}).zero_();

  auto output_size = num_rois * pooled_height * pooled_width * channels;
  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  dim3 grid(std::min(THCCeilDiv(output_size, 512L), 4096L));
  dim3 block(512);

  if (output.numel() == 0) {
    THCudaCheck(cudaGetLastError());
    return std::make_tuple(output, argmax);
  }

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(input.type(), "ROIPool_forward", [&] {
    RoIPoolForward<scalar_t><<<grid, block, 0, stream>>>(
         output_size,
         input.data<scalar_t>(),
         spatial_scale,
         channels,
         height,
         width,
         pooled_height,
         pooled_width,
         rois.data<scalar_t>(),
         output.data<scalar_t>(),
         argmax.data<int>());
  });
  THCudaCheck(cudaGetLastError());
  return std::make_tuple(output, argmax);
}

at::Tensor ROIPool_backward_cuda(const at::Tensor& grad,
                                 const at::Tensor& rois,
                                 const at::Tensor& argmax,
                                 const float spatial_scale,
                                 const int pooled_height,
                                 const int pooled_width,
                                 const int batch_size,
                                 const int channels,
                                 const int height,
                                 const int width) {
  // Check if input tensors are CUDA tensors
  AT_ASSERTM(grad.type().is_cuda(), "grad must be a CUDA tensor");
  AT_ASSERTM(rois.type().is_cuda(), "rois must be a CUDA tensor");
  AT_ASSERTM(argmax.type().is_cuda(), "argmax must be a CUDA tensor");

  auto num_rois = rois.size(0);

  at::Tensor grad_input = at::zeros({batch_size, channels, height, width}, grad.type());

  cudaStream_t stream = at::cuda::getCurrentCUDAStream();

  dim3 grid(std::min(THCCeilDiv(grad.numel(), 512L), 4096L));
  dim3 block(512);

  // handle possibly empty gradients
  if (grad.numel() == 0) {
    THCudaCheck(cudaGetLastError());
    return grad_input;
  }

  int n_stride = grad.stride(0);
  int c_stride = grad.stride(1);
  int h_stride = grad.stride(2);
  int w_stride = grad.stride(3);

  AT_DISPATCH_FLOATING_TYPES_AND_HALF(grad.type(), "ROIPool_backward", [&] {
    RoIPoolBackward<scalar_t><<<grid, block, 0, stream>>>(
         grad.numel(),
         grad.data<scalar_t>(),
         argmax.data<int>(),
         num_rois,
         spatial_scale,
         channels,
         height,
         width,
         pooled_height,
         pooled_width,
         grad_input.data<scalar_t>(),
         rois.data<scalar_t>(),
         n_stride,
         c_stride,
         h_stride,
         w_stride);
  });
  THCudaCheck(cudaGetLastError());
  return grad_input;
}
